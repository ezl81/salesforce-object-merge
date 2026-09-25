/**
 * @description Unit tests for RecordMergeService.
 * Uses Account as the merged object, with Contacts, an Opportunity, a Task
 * (polymorphic WhatId), a File (ContentDocumentLink) and a child Account
 * (ParentId self-lookup) on the abandoned record.
 */
@IsTest
private class RecordMergeServiceTest {

    private static final String SURVIVOR_NAME = 'Merge Survivor Holdings';
    private static final String ABANDONED_NAME = 'Merge Abandoned Ventures';

    @TestSetup
    static void setupTestData() {
        Account survivor = new Account(Name = SURVIVOR_NAME, Phone = '111-111-1111');
        Account abandoned = new Account(Name = ABANDONED_NAME, Phone = '222-222-2222', Website = 'https://abandoned.example.com');
        insert new List<Account>{ survivor, abandoned };

        insert new List<Contact>{
            new Contact(FirstName = 'Survivor', LastName = 'Contact One', AccountId = survivor.Id),
            new Contact(FirstName = 'Abandoned', LastName = 'Contact One', AccountId = abandoned.Id),
            new Contact(FirstName = 'Abandoned', LastName = 'Contact Two', AccountId = abandoned.Id)
        };
        insert new Opportunity(Name = 'Abandoned Opportunity', StageName = 'Prospecting', CloseDate = Date.today().addDays(30), AccountId = abandoned.Id);
        insert new Task(Subject = 'Abandoned Task', WhatId = abandoned.Id);
        insert new Account(Name = 'Merge Child Branch', ParentId = abandoned.Id);
        insert new ContentVersion(
            Title = 'Abandoned File',
            PathOnClient = 'abandoned.txt',
            VersionData = Blob.valueOf('file body'),
            FirstPublishLocationId = abandoned.Id
        );
    }

    private static Account getAccount(String name) {
        return [SELECT Id, Name, Phone, Website, ParentId FROM Account WHERE Name = :name LIMIT 1];
    }

    private static RecordMergeService.MergeRequest buildRequest(Id survivorId, Id abandonedId, Map<String, String> selections) {
        RecordMergeService.MergeRequest request = new RecordMergeService.MergeRequest();
        request.survivorId = survivorId;
        request.abandonedId = abandonedId;
        request.selections = selections;
        return request;
    }

    @IsTest
    static void getComparison_ReturnsFieldDifferencesAndChildCounts() {
        Account survivor = getAccount(SURVIVOR_NAME);
        Account abandoned = getAccount(ABANDONED_NAME);

        Test.startTest();
        RecordMergeService.ComparisonResult result = RecordMergeService.getComparison(survivor.Id, abandoned.Id);
        Test.stopTest();

        Assert.areEqual('Account', result.objectApiName);
        Assert.areEqual(SURVIVOR_NAME, result.nameA);
        Assert.areEqual(ABANDONED_NAME, result.nameB);

        Map<String, RecordMergeService.FieldComparison> fieldsByName = new Map<String, RecordMergeService.FieldComparison>();
        for (RecordMergeService.FieldComparison field : result.fields) {
            fieldsByName.put(field.apiName, field);
        }
        Assert.isTrue(fieldsByName.get('Phone').isDifferent, 'Phone differs between the records');
        Assert.areEqual('222-222-2222', fieldsByName.get('Phone').displayB);
        Assert.isTrue(fieldsByName.get('Website').isDifferent, 'Website is only set on the abandoned record');
        Assert.isFalse(fieldsByName.containsKey('CreatedDate'), 'Read-only fields are not compared');

        Map<String, RecordMergeService.ReparentSummary> summaryByKey = new Map<String, RecordMergeService.ReparentSummary>();
        for (RecordMergeService.ReparentSummary summary : result.reparentSummary) {
            summaryByKey.put(summary.childObjectApiName + '.' + summary.fieldApiName, summary);
        }
        Assert.areEqual(1, summaryByKey.get('Contact.AccountId').countA);
        Assert.areEqual(2, summaryByKey.get('Contact.AccountId').countB);
        Assert.areEqual(1, summaryByKey.get('Opportunity.AccountId').countB);
        Assert.areEqual(1, summaryByKey.get('ContentDocumentLink.LinkedEntityId').countB);
    }

    @IsTest
    static void mergeRecords_CopiesValuesReparentsChildrenLogsAndDeletes() {
        Account survivor = getAccount(SURVIVOR_NAME);
        Account abandoned = getAccount(ABANDONED_NAME);
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Title = 'Abandoned File' LIMIT 1].ContentDocumentId;

        RecordMergeService.MergeRequest request = buildRequest(survivor.Id, abandoned.Id, new Map<String, String>{
            'Phone' => abandoned.Id,
            'Website' => abandoned.Id,
            'Name' => survivor.Id
        });

        Test.startTest();
        RecordMergeService.MergeResult result = RecordMergeService.mergeRecords(request);
        Test.stopTest();

        Account mergedSurvivor = getAccount(SURVIVOR_NAME);
        Assert.areEqual('222-222-2222', mergedSurvivor.Phone, 'Phone comes from the abandoned record');
        Assert.areEqual('https://abandoned.example.com', mergedSurvivor.Website, 'Website comes from the abandoned record');
        Assert.areEqual(SURVIVOR_NAME, mergedSurvivor.Name, 'Name is kept from the survivor');

        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Id = :abandoned.Id], 'Abandoned record is deleted');
        Assert.areEqual(3, [SELECT COUNT() FROM Contact WHERE AccountId = :survivor.Id]);
        Assert.areEqual(1, [SELECT COUNT() FROM Opportunity WHERE AccountId = :survivor.Id]);
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE WhatId = :survivor.Id]);
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE ParentId = :survivor.Id]);
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :survivor.Id AND ContentDocumentId = :documentId]);
        Assert.isTrue(result.reparentedCount >= 6, 'Contacts, opportunity, task, child account and file were moved');

        Record_Merge_Log__c log = [
            SELECT Object_Api_Name__c, Surviving_Record_Id__c, Abandoned_Record_Id__c, Abandoned_Record_Name__c,
                Abandoned_Record_JSON__c, Field_Selections_JSON__c, Reparented_Records_JSON__c
            FROM Record_Merge_Log__c WHERE Id = :result.logId
        ];
        Assert.areEqual('Account', log.Object_Api_Name__c);
        Assert.areEqual(String.valueOf(survivor.Id), log.Surviving_Record_Id__c);
        Assert.areEqual(String.valueOf(abandoned.Id), log.Abandoned_Record_Id__c);
        Assert.areEqual(ABANDONED_NAME, log.Abandoned_Record_Name__c);

        Map<String, Object> snapshot = (Map<String, Object>) JSON.deserializeUntyped(log.Abandoned_Record_JSON__c);
        Assert.areEqual(ABANDONED_NAME, snapshot.get('Name'));
        Assert.areEqual('222-222-2222', snapshot.get('Phone'));

        Map<String, Object> fieldChanges = (Map<String, Object>) JSON.deserializeUntyped(log.Field_Selections_JSON__c);
        Assert.isTrue(fieldChanges.containsKey('Phone'));
        Assert.isFalse(fieldChanges.containsKey('Name'), 'Fields kept from the survivor are not logged as changes');

        Map<String, Object> reparented = (Map<String, Object>) JSON.deserializeUntyped(log.Reparented_Records_JSON__c);
        Assert.areEqual(2, ((List<Object>) reparented.get('Contact.AccountId')).size());
        Assert.isTrue(reparented.containsKey('ContentDocumentLink.LinkedEntityId'));
    }

    @IsTest
    static void mergeRecords_FailureRollsBackEverything() {
        Account survivor = getAccount(SURVIVOR_NAME);
        Account abandoned = getAccount(ABANDONED_NAME);
        RecordMergeService.simulateFailureBeforeDelete = true;

        Test.startTest();
        try {
            RecordMergeService.mergeRecords(buildRequest(survivor.Id, abandoned.Id, new Map<String, String>{ 'Phone' => abandoned.Id }));
            Assert.fail('Expected the simulated failure');
        } catch (RecordMergeService.RecordMergeException e) {
            Assert.isTrue(e.getMessage().contains('Simulated failure'));
        }
        Test.stopTest();

        Assert.areEqual('111-111-1111', getAccount(SURVIVOR_NAME).Phone, 'Survivor update rolled back');
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Id = :abandoned.Id], 'Abandoned record not deleted');
        Assert.areEqual(2, [SELECT COUNT() FROM Contact WHERE AccountId = :abandoned.Id], 'Children not moved');
        Assert.areEqual(0, [SELECT COUNT() FROM Record_Merge_Log__c], 'No log written');
    }

    @IsTest
    static void mergeRecords_SkipsLookupThatWouldPointSurvivorAtItself() {
        Account survivor = getAccount(SURVIVOR_NAME);
        Account abandoned = getAccount(ABANDONED_NAME);
        abandoned.ParentId = survivor.Id;
        update abandoned;

        Test.startTest();
        RecordMergeService.mergeRecords(buildRequest(survivor.Id, abandoned.Id, new Map<String, String>{ 'ParentId' => abandoned.Id }));
        Test.stopTest();

        Assert.isNull(getAccount(SURVIVOR_NAME).ParentId, 'Survivor must not become its own parent');
    }

    @IsTest
    static void mergeRecords_RejectsInvalidRequests() {
        Account survivor = getAccount(SURVIVOR_NAME);
        Account abandoned = getAccount(ABANDONED_NAME);
        Contact contact = [SELECT Id FROM Contact LIMIT 1];

        assertMergeFails(null, 'A merge request is required');
        assertMergeFails(buildRequest(survivor.Id, survivor.Id, null), 'two different records');
        assertMergeFails(buildRequest(survivor.Id, contact.Id, null), 'same type');
        assertMergeFails(buildRequest(survivor.Id, abandoned.Id, new Map<String, String>{ 'CreatedDate' => abandoned.Id }), 'cannot be merged');
        assertMergeFails(buildRequest(survivor.Id, abandoned.Id, new Map<String, String>{ 'Phone' => contact.Id }), 'must come from one of the two records');
        assertMergeFails(buildRequest(survivor.Id, abandoned.Id, new Map<String, String>{ 'Phone' => 'not-an-id' }), 'Invalid record Id');

        Assert.areEqual(2, [SELECT COUNT() FROM Account WHERE Id IN (:survivor.Id, :abandoned.Id)], 'Nothing was deleted');
    }

    private static void assertMergeFails(RecordMergeService.MergeRequest request, String expectedMessage) {
        try {
            RecordMergeService.mergeRecords(request);
            Assert.fail('Expected merge to fail with: ' + expectedMessage);
        } catch (RecordMergeService.RecordMergeException e) {
            Assert.isTrue(e.getMessage().contains(expectedMessage), 'Unexpected message: ' + e.getMessage());
        }
    }

    @IsTest
    static void toLogJson_TruncatesLongValues() {
        String longValue = 'x'.repeat(RecordMergeService.LONG_TEXT_MAX_LENGTH + 100);

        String result = RecordMergeService.toLogJson(new Map<String, Object>{ 'value' => longValue });

        Assert.isTrue(result.length() <= RecordMergeService.LONG_TEXT_MAX_LENGTH);
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(result);
        Assert.areEqual(true, parsed.get('_truncated'));
    }

    @IsTest
    static void valuesEqual_IsCaseSensitive() {
        Assert.isTrue(RecordMergeService.valuesEqual(null, null));
        Assert.isFalse(RecordMergeService.valuesEqual('Acme', null));
        Assert.isFalse(RecordMergeService.valuesEqual('Acme', 'ACME'));
        Assert.isTrue(RecordMergeService.valuesEqual(5, 5));
    }
}