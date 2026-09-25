/**
 * @description Unit tests for RecordMergeController (the LWC-facing JSON layer).
 * The merge logic itself is covered by RecordMergeServiceTest.
 */
@IsTest
private class RecordMergeControllerTest {

    @TestSetup
    static void setupTestData() {
        insert new List<Account>{
            new Account(Name = 'Controller Survivor Co', Phone = '111-111-1111'),
            new Account(Name = 'Controller Abandoned Co', Phone = '222-222-2222')
        };
    }

    private static Map<String, Id> getAccountIds() {
        Map<String, Id> idsByName = new Map<String, Id>();
        for (Account account : [SELECT Id, Name FROM Account]) {
            idsByName.put(account.Name, account.Id);
        }
        return idsByName;
    }

    @IsTest
    static void getComparison_ReturnsSerializedResult() {
        Map<String, Id> ids = getAccountIds();

        Test.startTest();
        String response = RecordMergeController.getComparison(ids.get('Controller Survivor Co'), ids.get('Controller Abandoned Co'));
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(response);
        Assert.areEqual('Account', parsed.get('objectApiName'));
        Assert.areEqual('Controller Survivor Co', parsed.get('nameA'));
        Assert.isFalse(((List<Object>) parsed.get('fields')).isEmpty());
    }

    @IsTest
    static void mergeRecords_MergesAndReturnsLogId() {
        Map<String, Id> ids = getAccountIds();
        Id survivorId = ids.get('Controller Survivor Co');
        Id abandonedId = ids.get('Controller Abandoned Co');

        String request = JSON.serialize(new Map<String, Object>{
            'survivorId' => survivorId,
            'abandonedId' => abandonedId,
            'selections' => new Map<String, String>{ 'Phone' => abandonedId }
        });

        Test.startTest();
        String response = RecordMergeController.mergeRecords(request);
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(response);
        Assert.isNotNull(parsed.get('logId'));
        Assert.areEqual('222-222-2222', [SELECT Phone FROM Account WHERE Id = :survivorId].Phone);
        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Id = :abandonedId]);
    }

    @IsTest
    static void errors_AreReturnedAsAuraHandledExceptions() {
        Id survivorId = getAccountIds().get('Controller Survivor Co');

        try {
            RecordMergeController.getComparison(survivorId, survivorId);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('two different records'));
        }

        try {
            RecordMergeController.mergeRecords('not json');
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage());
        }
    }
}