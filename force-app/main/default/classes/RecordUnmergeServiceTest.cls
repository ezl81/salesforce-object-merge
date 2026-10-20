/**
 * @description Unit tests for RecordUnmergeService.
 * Each test merges an abandoned Account (two Contacts and a File) into a survivor
 * and then reverses the merge, from the recycle bin or by recreating the record.
 */
@IsTest
private class RecordUnmergeServiceTest {

    private static final String SURVIVOR_NAME = 'Unmerge Survivor Holdings';
    private static final String ABANDONED_NAME = 'Unmerge Abandoned Ventures';
    private static final String CONTACT_KEY = 'Contact.AccountId';
    private static final String FILE_KEY = 'ContentDocumentLink.LinkedEntityId';

    @TestSetup
    static void setupTestData() {
        Account survivor = new Account(Name = SURVIVOR_NAME, Phone = '111-111-1111');
        Account abandoned = new Account(Name = ABANDONED_NAME, Phone = '222-222-2222', Website = 'https://abandoned.example.com');
        insert new List<Account>{ survivor, abandoned };

        insert new List<Contact>{
            new Contact(FirstName = 'Survivor', LastName = 'Contact', AccountId = survivor.Id),
            new Contact(FirstName = 'Abandoned', LastName = 'Contact One', AccountId = abandoned.Id),
            new Contact(FirstName = 'Abandoned', LastName = 'Contact Two', AccountId = abandoned.Id)
        };
        insert new ContentVersion(
            Title = 'Abandoned File',
            PathOnClient = 'abandoned.txt',
            VersionData = Blob.valueOf('file body'),
            FirstPublishLocationId = abandoned.Id
        );
    }

    private static Account getAccount(Id accountId) {
        return [SELECT Id, Name, Phone, Fax, Website FROM Account WHERE Id = :accountId];
    }

    private static Id getAccountId(String name) {
        return [SELECT Id FROM Account WHERE Name = :name LIMIT 1].Id;
    }

    private static Id getFileId() {
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Title = 'Abandoned File' LIMIT 1].ContentDocumentId;
    }

    //Merge the abandoned account into the survivor, taking its Phone and Website
    private static RecordMergeService.MergeResult mergeAccounts() {
        Id survivorId = getAccountId(SURVIVOR_NAME);
        Id abandonedId = getAccountId(ABANDONED_NAME);
        RecordMergeService.MergeRequest request = new RecordMergeService.MergeRequest();
        request.survivorId = survivorId;
        request.abandonedId = abandonedId;
        request.selections = new Map<String, String>{ 'Phone' => abandonedId, 'Website' => abandonedId };
        return RecordMergeService.mergeRecords(request);
    }

    private static RecordUnmergeService.UnmergeRequest buildRequest(Id logId, List<String> fromSurvivor,
            List<String> toRevert, List<Id> relatedIds) {
        RecordUnmergeService.UnmergeRequest request = new RecordUnmergeService.UnmergeRequest();
        request.logId = logId;
        request.restoredFromSurvivor = fromSurvivor;
        request.survivorFieldsToRevert = toRevert;
        request.relatedRecordIds = relatedIds;
        return request;
    }

    private static Map<String, RecordMergeService.FieldComparison> byApiName(List<RecordMergeService.FieldComparison> fields) {
        Map<String, RecordMergeService.FieldComparison> fieldsByName = new Map<String, RecordMergeService.FieldComparison>();
        for (RecordMergeService.FieldComparison field : fields) {
            fieldsByName.put(field.apiName, field);
        }
        return fieldsByName;
    }

    private static Map<String, RecordUnmergeService.RelatedGroup> groupsByKey(List<RecordUnmergeService.RelatedGroup> groups) {
        Map<String, RecordUnmergeService.RelatedGroup> result = new Map<String, RecordUnmergeService.RelatedGroup>();
        for (RecordUnmergeService.RelatedGroup relatedGroup : groups) {
            result.put(relatedGroup.key, relatedGroup);
        }
        return result;
    }

    @IsTest
    static void merge_SavesUnmergeFileOnTheLog() {
        Id abandonedId = getAccountId(ABANDONED_NAME);

        Test.startTest();
        RecordMergeService.MergeResult result = mergeAccounts();
        Test.stopTest();

        Assert.isNotNull(result.unmergeFileId);
        ContentDocumentLink link = [
            SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension
            FROM ContentDocumentLink WHERE LinkedEntityId = :result.logId
        ];
        Assert.areEqual(result.unmergeFileId, link.ContentDocumentId);
        Assert.areEqual(RecordUnmergeService.unmergeFileTitle(abandonedId), link.ContentDocument.Title);
        Assert.areEqual('json', link.ContentDocument.FileExtension);

        String body = [SELECT VersionData FROM ContentVersion WHERE ContentDocumentId = :result.unmergeFileId AND IsLatest = true].VersionData.toString();
        RecordUnmergeService.UnmergeData data = RecordUnmergeService.parseUnmergeData(body);
        Assert.areEqual(RecordUnmergeService.FORMAT_VERSION, data.formatVersion);
        Assert.areEqual(abandonedId, data.abandonedId);
        Assert.areEqual(result.logId, data.logId);
        Assert.areEqual('222-222-2222', data.abandonedValues.get('Phone'));
        Assert.areEqual('111-111-1111', ((RecordUnmergeService.SurvivorChange) data.survivorChanges.get('Phone')).previousValue);
        Assert.areEqual(2, data.reparentedRecords.get(CONTACT_KEY).size());
        Assert.areEqual(new List<Id>{ getFileId() }, data.reparentedRecords.get(FILE_KEY));
    }

    @IsTest
    static void getUnmergeOptionsAndPreview_DescribeTheMerge() {
        RecordMergeService.MergeResult mergeResult = mergeAccounts();
        Id survivorId = mergeResult.survivorId;

        Test.startTest();
        List<RecordUnmergeService.UnmergeOption> options = RecordUnmergeService.getUnmergeOptions(survivorId);
        RecordUnmergeService.UnmergePreview preview = RecordUnmergeService.getUnmergePreview(mergeResult.logId);
        Test.stopTest();

        Assert.areEqual(1, options.size());
        Assert.areEqual(mergeResult.logId, options[0].logId);
        Assert.areEqual(ABANDONED_NAME, options[0].abandonedName);
        Assert.isTrue(RecordUnmergeService.getUnmergeOptions(mergeResult.abandonedId).isEmpty(), 'Only the survivor lists the merge');

        Assert.areEqual(RecordUnmergeService.MODE_UNDELETE, preview.restoreMode);
        Assert.areEqual(SURVIVOR_NAME, preview.survivorName);
        Assert.areEqual(ABANDONED_NAME, preview.abandonedName);

        Map<String, RecordMergeService.FieldComparison> restoredFields = byApiName(preview.restoredFields);
        Assert.areEqual(ABANDONED_NAME, restoredFields.get('Name').displayA);
        Assert.areEqual(SURVIVOR_NAME, restoredFields.get('Name').displayB);
        Assert.isTrue(restoredFields.get('Name').isDifferent);
        Assert.isFalse(restoredFields.get('Phone').isDifferent, 'The merge copied Phone to the survivor');
        Assert.isTrue(restoredFields.containsKey('OwnerId'), 'Lookups can be restored');

        Map<String, RecordMergeService.FieldComparison> survivorFields = byApiName(preview.survivorFields);
        Assert.areEqual('222-222-2222', survivorFields.get('Phone').displayA);
        Assert.areEqual('111-111-1111', survivorFields.get('Phone').displayB);
        Assert.areEqual('', survivorFields.get('Website').displayB, 'Website was blank before the merge');
        Assert.isTrue(preview.survivorFieldsChangedSinceMerge.isEmpty());

        Map<String, RecordUnmergeService.RelatedGroup> groups = groupsByKey(preview.relatedGroups);
        Assert.areEqual(2, groups.get(CONTACT_KEY).records.size());
        Assert.areEqual(1, groups.get(FILE_KEY).records.size());
        Assert.areEqual('Abandoned File', groups.get(FILE_KEY).records[0].name);
    }

    @IsTest
    static void unmergeRecords_UndeletesRevertsAndMovesChosenRecordsBack() {
        RecordMergeService.MergeResult mergeResult = mergeAccounts();
        Id survivorId = mergeResult.survivorId;
        Id abandonedId = mergeResult.abandonedId;
        Id fileId = getFileId();
        Contact contactToMove = [SELECT Id FROM Contact WHERE LastName = 'Contact One'];
        Contact contactToKeep = [SELECT Id FROM Contact WHERE LastName = 'Contact Two'];

        Test.startTest();
        RecordUnmergeService.UnmergeResult result = RecordUnmergeService.unmergeRecords(buildRequest(
            mergeResult.logId, null, new List<String>{ 'Phone' }, new List<Id>{ contactToMove.Id, fileId }));
        Test.stopTest();

        Assert.areEqual(RecordUnmergeService.MODE_UNDELETE, result.restoreMode);
        Assert.areEqual(abandonedId, result.restoredId, 'An undeleted record keeps its Id');
        Assert.areEqual(new List<String>{ 'Phone' }, result.revertedFields);
        Assert.areEqual(2, result.movedCount);

        Account survivor = getAccount(survivorId);
        Assert.areEqual('111-111-1111', survivor.Phone, 'Phone was reverted');
        Assert.areEqual('https://abandoned.example.com', survivor.Website, 'Website was not reverted');

        Account restored = getAccount(abandonedId);
        Assert.areEqual(ABANDONED_NAME, restored.Name);
        Assert.areEqual('222-222-2222', restored.Phone);
        Assert.areEqual('https://abandoned.example.com', restored.Website);

        Assert.areEqual(abandonedId, [SELECT AccountId FROM Contact WHERE Id = :contactToMove.Id].AccountId);
        Assert.areEqual(survivorId, [SELECT AccountId FROM Contact WHERE Id = :contactToKeep.Id].AccountId, 'Unselected contact stays');
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :abandonedId AND ContentDocumentId = :fileId]);
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :survivorId AND ContentDocumentId = :fileId]);

        Record_Merge_Log__c log = [SELECT Unmerged_On__c, Restored_Record_Id__c FROM Record_Merge_Log__c WHERE Id = :mergeResult.logId];
        Assert.isNotNull(log.Unmerged_On__c);
        Assert.areEqual(String.valueOf(abandonedId), log.Restored_Record_Id__c);
        Assert.isTrue(RecordUnmergeService.getUnmergeOptions(survivorId).isEmpty(), 'A merge can only be unmerged once');
        assertUnmergeFails(buildRequest(mergeResult.logId, null, null, null), 'already unmerged');
    }

    @IsTest
    static void unmergeRecords_RecreatesPurgedRecord() {
        RecordMergeService.MergeResult mergeResult = mergeAccounts();
        RecordUnmergeService.simulatePurgedRecord = true;
        List<Id> contactIds = new List<Id>(new Map<Id, Contact>([SELECT Id FROM Contact WHERE FirstName = 'Abandoned']).keySet());

        Test.startTest();
        Assert.areEqual(RecordUnmergeService.MODE_RECREATE, RecordUnmergeService.getUnmergePreview(mergeResult.logId).restoreMode);
        RecordUnmergeService.UnmergeResult result = RecordUnmergeService.unmergeRecords(buildRequest(
            mergeResult.logId, null, new List<String>{ 'Phone', 'Website' }, contactIds));
        Test.stopTest();

        Assert.areEqual(RecordUnmergeService.MODE_RECREATE, result.restoreMode);
        Assert.areNotEqual(mergeResult.abandonedId, result.restoredId, 'A recreated record gets a new Id');
        Account restored = getAccount(result.restoredId);
        Assert.areEqual(ABANDONED_NAME, restored.Name);
        Assert.areEqual('222-222-2222', restored.Phone);
        Assert.areEqual(2, [SELECT COUNT() FROM Contact WHERE AccountId = :result.restoredId]);
        Assert.areEqual('111-111-1111', getAccount(mergeResult.survivorId).Phone);
        Assert.areEqual(String.valueOf(result.restoredId),
            [SELECT Restored_Record_Id__c FROM Record_Merge_Log__c WHERE Id = :mergeResult.logId].Restored_Record_Id__c);
    }

    @IsTest
    static void unmergeRecords_CanTakeValuesFromTheSurvivor() {
        RecordMergeService.MergeResult mergeResult = mergeAccounts();
        update new Account(Id = mergeResult.survivorId, Fax = '999-999-9999', Phone = '333-333-3333');

        Test.startTest();
        RecordUnmergeService.UnmergePreview preview = RecordUnmergeService.getUnmergePreview(mergeResult.logId);
        RecordUnmergeService.unmergeRecords(buildRequest(mergeResult.logId, new List<String>{ 'Fax' }, null, null));
        Test.stopTest();

        Assert.areEqual(new List<String>{ 'Phone' }, preview.survivorFieldsChangedSinceMerge, 'Phone was edited after the merge');
        Account restored = getAccount(mergeResult.abandonedId);
        Assert.areEqual('999-999-9999', restored.Fax, 'Fax taken from the survivor');
        Assert.areEqual('222-222-2222', restored.Phone, 'Phone kept from the merge');
        Assert.areEqual('333-333-3333', getAccount(mergeResult.survivorId).Phone, 'Survivor not reverted');
    }

    @IsTest
    static void unmergeRecords_FailureRollsBackEverything() {
        RecordMergeService.MergeResult mergeResult = mergeAccounts();
        RecordUnmergeService.simulateFailureAfterRestore = true;

        Test.startTest();
        assertUnmergeFails(buildRequest(mergeResult.logId, null, new List<String>{ 'Phone' }, null), 'Simulated failure');
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Id = :mergeResult.abandonedId], 'Record is still deleted');
        Assert.areEqual('222-222-2222', getAccount(mergeResult.survivorId).Phone, 'Survivor revert rolled back');
        Assert.isNull([SELECT Unmerged_On__c FROM Record_Merge_Log__c WHERE Id = :mergeResult.logId].Unmerged_On__c);
    }

    @IsTest
    static void unmergeRecords_RejectsInvalidRequests() {
        RecordMergeService.MergeResult mergeResult = mergeAccounts();

        assertUnmergeFails(null, 'An unmerge request is required');
        assertUnmergeFails(buildRequest(mergeResult.survivorId, null, null, null), 'Record Merge Log Id is required');
        assertUnmergeFails(buildRequest(mergeResult.logId, new List<String>{ 'CreatedDate' }, null, null), 'cannot be restored');
        assertUnmergeFails(buildRequest(mergeResult.logId, null, new List<String>{ 'Fax' }, null), 'was not changed by the merge');

        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Id = :mergeResult.abandonedId], 'Nothing was restored');
    }

    @IsTest
    static void deletedUnmergeFile_PreventsUnmerge() {
        RecordMergeService.MergeResult mergeResult = mergeAccounts();
        delete new ContentDocument(Id = mergeResult.unmergeFileId);

        Test.startTest();
        List<RecordUnmergeService.UnmergeOption> options = RecordUnmergeService.getUnmergeOptions(mergeResult.survivorId);
        Test.stopTest();

        Assert.isTrue(options.isEmpty());
        assertUnmergeFails(buildRequest(mergeResult.logId, null, null, null), 'no longer exists');
    }

    private static void assertUnmergeFails(RecordUnmergeService.UnmergeRequest request, String expectedMessage) {
        try {
            RecordUnmergeService.unmergeRecords(request);
            Assert.fail('Expected unmerge to fail with: ' + expectedMessage);
        } catch (RecordMergeService.RecordMergeException e) {
            Assert.isTrue(e.getMessage().contains(expectedMessage), 'Unexpected message: ' + e.getMessage());
        }
    }

    @IsTest
    static void parseUnmergeData_RejectsBadFiles() {
        for (String body : new List<String>{ 'not json', '{"formatVersion": 99}', '{}' }) {
            try {
                RecordUnmergeService.parseUnmergeData(body);
                Assert.fail('Expected the file to be rejected: ' + body);
            } catch (RecordMergeService.RecordMergeException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
    }

    @IsTest
    static void toFieldValue_ConvertsJsonValuesToFieldTypes() {
        Map<String, Schema.SObjectField> accountFields = Schema.SObjectType.Account.fields.getMap();
        Map<String, Schema.SObjectField> taskFields = Schema.SObjectType.Task.fields.getMap();
        Map<String, Schema.SObjectField> opportunityFields = Schema.SObjectType.Opportunity.fields.getMap();
        Datetime reminder = Datetime.newInstanceGmt(2026, 1, 2, 3, 4, 5);

        Assert.isNull(RecordUnmergeService.toFieldValue(accountFields.get('Name').getDescribe(), null));
        Assert.areEqual('Acme', RecordUnmergeService.toFieldValue(accountFields.get('Name').getDescribe(), 'Acme'));
        Assert.areEqual(25, RecordUnmergeService.toFieldValue(accountFields.get('NumberOfEmployees').getDescribe(), 25));
        Assert.areEqual(1500.50, RecordUnmergeService.toFieldValue(accountFields.get('AnnualRevenue').getDescribe(), 1500.50));
        Assert.areEqual(Date.newInstance(2026, 1, 2), RecordUnmergeService.toFieldValue(opportunityFields.get('CloseDate').getDescribe(), '2026-01-02'));
        Assert.areEqual(reminder, RecordUnmergeService.toFieldValue(taskFields.get('ReminderDateTime').getDescribe(),
            JSON.deserializeUntyped(JSON.serialize(reminder))));
        Assert.areEqual(true, RecordUnmergeService.toFieldValue(taskFields.get('IsReminderSet').getDescribe(), true));
        Assert.areEqual(false, RecordUnmergeService.toFieldValue(taskFields.get('IsReminderSet').getDescribe(), 'false'));
    }
}
