/**
 * RecordUnmergeService
 *
 * Reverses a merge done by RecordMergeService.
 *
 * During a merge an unmerge file (Unmerge_<abandonedId>.json) is saved as a File
 * on the abandoned record and on its Record_Merge_Log__c. The file holds:
 *  - every field value of the abandoned record at the time of the merge,
 *  - the survivor's values before the merge for every field the merge changed,
 *  - the child records (and files) that were moved to the survivor.
 * A merge can be unmerged as long as that file is still linked to its log.
 *
 * An unmerge:
 *  1. Reverts the chosen survivor fields to their values from before the merge.
 *  2. Restores the abandoned record: undeleted from the recycle bin when it is still
 *     there (so it keeps its Id), otherwise recreated as a new record.
 *  3. Writes the chosen value of every field (lookups included) on the restored record:
 *     its own value from the merge, or the survivor's current value.
 *  4. Moves the chosen child records and files back to the restored record.
 *  5. Stamps the log with Unmerged_On__c and Restored_Record_Id__c so it can't be unmerged twice.
 * Everything runs under one savepoint, so any failure rolls the whole unmerge back.
 *
 * Security: the same as a merge. Field updates, the undelete and the insert run in
 * USER_MODE; child records are moved back without sharing. The user needs edit
 * access to the survivor.
 *
 * Usage (see RecordMergeController):
 *
 *     List<RecordUnmergeService.UnmergeOption> options = RecordUnmergeService.getUnmergeOptions(survivorId);
 *     RecordUnmergeService.UnmergePreview preview = RecordUnmergeService.getUnmergePreview(options[0].logId);
 *
 *     RecordUnmergeService.UnmergeRequest request = new RecordUnmergeService.UnmergeRequest();
 *     request.logId = options[0].logId;
 *     request.restoredFromSurvivor = new List<String>{ 'Website' };
 *     request.survivorFieldsToRevert = new List<String>{ 'Phone' };
 *     request.relatedRecordIds = new List<Id>{ contactId };
 *     RecordUnmergeService.UnmergeResult result = RecordUnmergeService.unmergeRecords(request);
 */
public with sharing class RecordUnmergeService {

    public static final Integer FORMAT_VERSION = 1;
    public static final String FILE_PREFIX = 'Unmerge_';

    //How the abandoned record will be brought back
    public static final String MODE_UNDELETE = 'UNDELETE';
    public static final String MODE_RECREATE = 'RECREATE';
    public static final String MODE_EXISTS = 'EXISTS';

    private static final String CONTENT_DOCUMENT_LINK = 'ContentDocumentLink';

    //Merges listed in the component
    private static final Integer MAX_OPTIONS = 50;

    @TestVisible
    private static Boolean simulateFailureAfterRestore = false;

    //Database.emptyRecycleBin doesn't purge records inside a test, so tests use this instead
    @TestVisible
    private static Boolean simulatePurgedRecord = false;

    //Start - unmerge file

    /**
     * saveUnmergeFile()
     * Called by RecordMergeService.mergeRecords() after the log is written and before
     * the abandoned record is deleted. Saves the JSON needed to reverse the merge as a
     * File on the log and on the abandoned record.
     * @return The ContentDocument Id of the file
     */
    public static Id saveUnmergeFile(Schema.DescribeSObjectResult objectDescribe, Record_Merge_Log__c log,
            SObject survivor, SObject abandoned, Map<String, Object> fieldChanges, Map<String, List<Id>> reparentedIds) {

        UnmergeData data = new UnmergeData();
        data.formatVersion = FORMAT_VERSION;
        data.objectApiName = objectDescribe.getName();
        data.logId = log.Id;
        data.survivorId = survivor.Id;
        data.survivorName = RecordMergeService.getRecordName(objectDescribe, survivor);
        data.abandonedId = abandoned.Id;
        data.abandonedName = RecordMergeService.getRecordName(objectDescribe, abandoned);
        data.mergedOn = Datetime.now();
        data.mergedById = UserInfo.getUserId();
        data.survivorChanges = fieldChanges;
        data.reparentedRecords = reparentedIds;

        for (Schema.SObjectField field : objectDescribe.fields.getMap().values()) {
            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
            if (!fieldDescribe.isAccessible() || RecordMergeService.isExcludedType(fieldDescribe.getType())) {
                continue;
            }
            String apiName = fieldDescribe.getName();
            data.abandonedValues.put(apiName, abandoned.get(apiName));
            if (fieldDescribe.isUpdateable()) {
                data.abandonedDisplayValues.put(apiName, RecordMergeService.getDisplayValue(fieldDescribe, abandoned));
            }
        }

        String title = unmergeFileTitle(abandoned.Id);
        //Published to the log, which always accepts files and outlives the abandoned record
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = title + '.json',
            VersionData = Blob.valueOf(JSON.serializePretty(data)),
            Description = ('Unmerge data for "' + data.abandonedName + '", merged into "' + data.survivorName + '".').left(1000),
            FirstPublishLocationId = log.Id
        );
        Database.insert(version, AccessLevel.SYSTEM_MODE);
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;

        //Also put it on the abandoned record, so it is there again if the record is undeleted
        try {
            Database.insert(new ContentDocumentLink(
                LinkedEntityId = abandoned.Id,
                ContentDocumentId = documentId,
                ShareType = 'V'
            ), AccessLevel.SYSTEM_MODE);
        } catch (DmlException e) {
            //Some standard objects don't take files - the log copy is enough to unmerge
            System.debug('Unable to link the unmerge file to ' + abandoned.Id + ': ' + e.getMessage());
        }
        return documentId;
    }

    public static String unmergeFileTitle(Id abandonedId) {
        return FILE_PREFIX + String.valueOf(abandonedId);
    }

    //End - unmerge file

    //Start - options and preview

    /**
     * getUnmergeOptions()
     * Merges into this record that can still be unmerged: the log isn't stamped
     * as unmerged and its unmerge file still exists. Newest first.
     */
    public static List<UnmergeOption> getUnmergeOptions(Id recordId) {
        if (recordId == null) {
            return new List<UnmergeOption>();
        }
        return new SystemContext().findUnmergeOptions(recordId);
    }

    /**
     * getUnmergePreview()
     * Everything the user chooses from before unmerging:
     *  - restoredFields: per field, the abandoned record's value at the merge (A) or the survivor's current value (B)
     *  - survivorFields: per field the merge changed on the survivor, its current value (A) or its value before the merge (B)
     *  - relatedGroups: child records and files moved by the merge that are still on the survivor
     */
    public static UnmergePreview getUnmergePreview(Id logId) {
        UnmergeContext context = loadContext(logId);
        UnmergeData data = context.data;
        Schema.DescribeSObjectResult objectDescribe = context.objectDescribe;
        SObject survivor = RecordMergeService.queryRecords(objectDescribe, new Set<Id>{ data.survivorId }).get(data.survivorId);
        SystemContext systemContext = new SystemContext();

        UnmergePreview preview = new UnmergePreview();
        preview.logId = context.log.Id;
        preview.logName = context.log.Name;
        preview.objectApiName = objectDescribe.getName();
        preview.objectLabel = objectDescribe.getLabel();
        preview.survivorId = data.survivorId;
        preview.survivorName = RecordMergeService.getRecordName(objectDescribe, survivor);
        preview.abandonedId = data.abandonedId;
        preview.abandonedName = data.abandonedName;
        preview.mergedOn = context.log.CreatedDate;
        preview.mergedByName = context.log.CreatedBy?.Name;
        preview.restoreMode = systemContext.getRestoreMode(objectDescribe, data.abandonedId);

        Map<String, Schema.DescribeFieldResult> comparableFields = new Map<String, Schema.DescribeFieldResult>();
        for (Schema.DescribeFieldResult fieldDescribe : RecordMergeService.getComparableFields(objectDescribe)) {
            comparableFields.put(fieldDescribe.getName().toLowerCase(), fieldDescribe);
            String apiName = fieldDescribe.getName();
            if (!data.abandonedValues.containsKey(apiName)) {
                continue;
            }
            Object snapshotValue = toFieldValue(fieldDescribe, data.abandonedValues.get(apiName));
            preview.restoredFields.add(buildComparison(fieldDescribe,
                snapshotValue, snapshotDisplay(fieldDescribe, data, snapshotValue),
                survivor.get(apiName), RecordMergeService.getDisplayValue(fieldDescribe, survivor)));
        }

        for (String apiName : data.survivorChanges.keySet()) {
            Schema.DescribeFieldResult fieldDescribe = comparableFields.get(apiName.toLowerCase());
            if (fieldDescribe == null) {
                continue;
            }
            SurvivorChange change = (SurvivorChange) data.survivorChanges.get(apiName);
            Object previousValue = toFieldValue(fieldDescribe, change.previousValue);
            Object currentValue = survivor.get(fieldDescribe.getName());
            preview.survivorFields.add(buildComparison(fieldDescribe,
                currentValue, RecordMergeService.getDisplayValue(fieldDescribe, survivor),
                previousValue, change.previousDisplay != null ? change.previousDisplay : stringOrBlank(previousValue)));
            //Someone edited it after the merge, so reverting it would lose that edit
            if (!RecordMergeService.valuesEqual(currentValue, toFieldValue(fieldDescribe, change.newValue))) {
                preview.survivorFieldsChangedSinceMerge.add(fieldDescribe.getName());
            }
        }

        preview.relatedGroups = systemContext.getRelatedGroups(objectDescribe.getSObjectType(), data.reparentedRecords, data.survivorId);
        return preview;
    }

    private static RecordMergeService.FieldComparison buildComparison(Schema.DescribeFieldResult fieldDescribe,
            Object valueA, String displayA, Object valueB, String displayB) {
        RecordMergeService.FieldComparison comparison = new RecordMergeService.FieldComparison();
        comparison.apiName = fieldDescribe.getName();
        comparison.label = fieldDescribe.getLabel();
        comparison.type = fieldDescribe.getType().name();
        comparison.valueA = valueA;
        comparison.valueB = valueB;
        comparison.displayA = displayA;
        comparison.displayB = displayB;
        comparison.isDifferent = !RecordMergeService.valuesEqual(valueA, valueB);
        return comparison;
    }

    private static String snapshotDisplay(Schema.DescribeFieldResult fieldDescribe, UnmergeData data, Object snapshotValue) {
        String display = data.abandonedDisplayValues.get(fieldDescribe.getName());
        return display != null ? display : stringOrBlank(snapshotValue);
    }

    private static String stringOrBlank(Object value) {
        return value == null ? '' : String.valueOf(value);
    }

    //End - options and preview

    //Start - unmerge

    /**
     * unmergeRecords()
     * Reverse the merge recorded by request.logId. Field values are always taken
     * from the unmerge file or the database; the request only says which to use.
     * @param request logId, restoredFromSurvivor (fields the restored record takes from the survivor
     *                instead of its own merge-time value), survivorFieldsToRevert, relatedRecordIds
     *                (child record and ContentDocument Ids to move back)
     */
    public static UnmergeResult unmergeRecords(UnmergeRequest request) {
        if (request == null || request.logId == null) {
            throw new RecordMergeService.RecordMergeException('An unmerge request is required.');
        }
        UnmergeContext context = loadContext(request.logId);
        UnmergeData data = context.data;
        Schema.DescribeSObjectResult objectDescribe = context.objectDescribe;
        if (!objectDescribe.isUpdateable()) {
            throw new RecordMergeService.RecordMergeException('You need edit access on ' + objectDescribe.getLabelPlural() + ' to unmerge records.');
        }
        assertEditAccess(data.survivorId);

        Map<String, Schema.DescribeFieldResult> comparableFields = new Map<String, Schema.DescribeFieldResult>();
        for (Schema.DescribeFieldResult fieldDescribe : RecordMergeService.getComparableFields(objectDescribe)) {
            comparableFields.put(fieldDescribe.getName().toLowerCase(), fieldDescribe);
        }
        SystemContext systemContext = new SystemContext();

        Savepoint savepoint = Database.setSavepoint();
        try {
            //The survivor as the user saw it in the preview, before anything is reverted
            SObject survivor = RecordMergeService.queryRecords(objectDescribe, new Set<Id>{ data.survivorId }).get(data.survivorId);
            Map<String, Object> restoredValues = buildRestoredValues(comparableFields, data, survivor, request.restoredFromSurvivor);

            //Reverted first, so unique values copied by the merge are free again for the restored record
            List<String> revertedFields = revertSurvivorFields(objectDescribe, comparableFields, data, survivor, request.survivorFieldsToRevert);

            String restoreMode = systemContext.getRestoreMode(objectDescribe, data.abandonedId);
            Id restoredId = restoreRecord(objectDescribe, comparableFields, data, restoreMode, restoredValues);

            if (Test.isRunningTest() && simulateFailureAfterRestore) {
                throw new RecordMergeService.RecordMergeException('Simulated failure after restore');
            }

            Set<Id> relatedIds = request.relatedRecordIds == null ? new Set<Id>() : new Set<Id>(request.relatedRecordIds);
            Integer movedCount = systemContext.moveRelatedBack(objectDescribe.getSObjectType(), data.reparentedRecords,
                relatedIds, data.survivorId, restoredId);

            Database.update(new Record_Merge_Log__c(
                Id = context.log.Id,
                Unmerged_On__c = Datetime.now(),
                Restored_Record_Id__c = String.valueOf(restoredId)
            ), AccessLevel.SYSTEM_MODE);

            UnmergeResult result = new UnmergeResult();
            result.logId = context.log.Id;
            result.survivorId = data.survivorId;
            result.restoredId = restoredId;
            result.restoredName = data.abandonedName;
            result.restoreMode = restoreMode;
            result.revertedFields = revertedFields;
            result.movedCount = movedCount;
            return result;
        } catch (Exception e) {
            Database.rollback(savepoint);
            System.debug('RecordUnmergeService.unmergeRecords failed: ' + e.getMessage());
            System.debug(e.getStackTraceString());
            throw e;
        }
    }

    /**
     * buildRestoredValues()
     * fieldApiName -> value for the restored record: its own value from the merge,
     * or the survivor's current value for the fields in fromSurvivor.
     */
    private static Map<String, Object> buildRestoredValues(Map<String, Schema.DescribeFieldResult> comparableFields,
            UnmergeData data, SObject survivor, List<String> fromSurvivor) {

        Set<String> fromSurvivorKeys = new Set<String>();
        for (String fieldName : fromSurvivor == null ? new List<String>() : fromSurvivor) {
            Schema.DescribeFieldResult fieldDescribe = comparableFields.get(fieldName.toLowerCase());
            if (fieldDescribe == null || !data.abandonedValues.containsKey(fieldDescribe.getName())) {
                throw new RecordMergeService.RecordMergeException('The field ' + fieldName + ' cannot be restored.');
            }
            fromSurvivorKeys.add(fieldName.toLowerCase());
        }

        Map<String, Object> values = new Map<String, Object>();
        for (Schema.DescribeFieldResult fieldDescribe : comparableFields.values()) {
            String apiName = fieldDescribe.getName();
            if (!data.abandonedValues.containsKey(apiName)) {
                continue;
            }
            values.put(apiName, fromSurvivorKeys.contains(apiName.toLowerCase())
                ? survivor.get(apiName)
                : toFieldValue(fieldDescribe, data.abandonedValues.get(apiName)));
        }
        return values;
    }

    /**
     * revertSurvivorFields()
     * Put the survivor's pre-merge value back on each requested field the merge changed.
     * @return The API names of the fields that were changed
     */
    private static List<String> revertSurvivorFields(Schema.DescribeSObjectResult objectDescribe,
            Map<String, Schema.DescribeFieldResult> comparableFields, UnmergeData data, SObject survivor, List<String> fieldNames) {

        List<String> reverted = new List<String>();
        if (fieldNames == null || fieldNames.isEmpty()) {
            return reverted;
        }

        Map<String, SurvivorChange> changesByKey = new Map<String, SurvivorChange>();
        for (String apiName : data.survivorChanges.keySet()) {
            changesByKey.put(apiName.toLowerCase(), (SurvivorChange) data.survivorChanges.get(apiName));
        }

        SObject survivorUpdate = objectDescribe.getSObjectType().newSObject(data.survivorId);
        for (String fieldName : fieldNames) {
            Schema.DescribeFieldResult fieldDescribe = comparableFields.get(fieldName.toLowerCase());
            SurvivorChange change = changesByKey.get(fieldName.toLowerCase());
            if (fieldDescribe == null || change == null) {
                throw new RecordMergeService.RecordMergeException('The field ' + fieldName + ' was not changed by the merge, so it cannot be reverted.');
            }
            String apiName = fieldDescribe.getName();
            Object previousValue = toFieldValue(fieldDescribe, change.previousValue);
            if (RecordMergeService.valuesEqual(survivor.get(apiName), previousValue)) {
                continue;
            }
            survivorUpdate.put(apiName, previousValue);
            reverted.add(apiName);
        }

        if (!reverted.isEmpty()) {
            Database.update(survivorUpdate, AccessLevel.USER_MODE);
        }
        return reverted;
    }

    /**
     * restoreRecord()
     * Bring the abandoned record back with the chosen values.
     * @return The restored record's Id - a new Id when it had to be recreated
     */
    private static Id restoreRecord(Schema.DescribeSObjectResult objectDescribe, Map<String, Schema.DescribeFieldResult> comparableFields,
            UnmergeData data, String restoreMode, Map<String, Object> restoredValues) {

        Schema.SObjectType objectType = objectDescribe.getSObjectType();

        if (restoreMode == MODE_RECREATE) {
            if (!objectDescribe.isCreateable()) {
                throw new RecordMergeService.RecordMergeException(data.abandonedName + ' is no longer in the recycle bin, and you need create access on ' +
                    objectDescribe.getLabelPlural() + ' to recreate it.');
            }
            SObject record = objectType.newSObject();
            for (String apiName : restoredValues.keySet()) {
                Schema.DescribeFieldResult fieldDescribe = comparableFields.get(apiName.toLowerCase());
                Object value = restoredValues.get(apiName);
                //The old Id no longer exists, so a lookup to it (e.g. ParentId) can't be restored
                if (value == null || !fieldDescribe.isCreateable() || isReferenceTo(fieldDescribe, value, data.abandonedId)) {
                    continue;
                }
                record.put(apiName, value);
            }
            Database.insert(record, AccessLevel.USER_MODE);
            return record.Id;
        }

        if (restoreMode == MODE_UNDELETE) {
            if (!objectDescribe.isUndeletable()) {
                throw new RecordMergeService.RecordMergeException('You need access to undelete ' + objectDescribe.getLabelPlural() + ' to unmerge this record.');
            }
            Database.undelete(data.abandonedId, true, AccessLevel.USER_MODE);
        }

        //Only write what differs from the record as it is now
        SObject current = RecordMergeService.queryRecords(objectDescribe, new Set<Id>{ data.abandonedId }).get(data.abandonedId);
        SObject recordUpdate = objectType.newSObject(data.abandonedId);
        Boolean hasChanges = false;
        for (String apiName : restoredValues.keySet()) {
            Schema.DescribeFieldResult fieldDescribe = comparableFields.get(apiName.toLowerCase());
            Object value = restoredValues.get(apiName);
            //A lookup to itself would make the record its own parent
            if (isReferenceTo(fieldDescribe, value, data.abandonedId) || RecordMergeService.valuesEqual(current.get(apiName), value)) {
                continue;
            }
            recordUpdate.put(apiName, value);
            hasChanges = true;
        }
        if (hasChanges) {
            Database.update(recordUpdate, AccessLevel.USER_MODE);
        }
        return data.abandonedId;
    }

    private static Boolean isReferenceTo(Schema.DescribeFieldResult fieldDescribe, Object value, Id recordId) {
        if (fieldDescribe.getType() != Schema.DisplayType.REFERENCE || value == null) {
            return false;
        }
        try {
            return Id.valueOf(String.valueOf(value)) == recordId;
        } catch (Exception e) {
            return false;
        }
    }

    private static void assertEditAccess(Id recordId) {
        List<UserRecordAccess> access = [
            SELECT RecordId, HasEditAccess FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :recordId
        ];
        if (access.isEmpty() || !access[0].HasEditAccess) {
            throw new RecordMergeService.RecordMergeException('You need edit access to this record to unmerge it.');
        }
    }

    //End - unmerge

    //Start - file helpers

    private static UnmergeContext loadContext(Id logId) {
        if (logId == null || logId.getSObjectType() != Record_Merge_Log__c.SObjectType) {
            throw new RecordMergeService.RecordMergeException('A Record Merge Log Id is required to unmerge.');
        }
        UnmergeContext context = new SystemContext().loadUnmergeFile(logId);

        if (context.data.survivorId == null || context.data.abandonedId == null ||
                String.valueOf(context.data.survivorId) != context.log.Surviving_Record_Id__c ||
                String.valueOf(context.data.abandonedId) != context.log.Abandoned_Record_Id__c) {
            throw new RecordMergeService.RecordMergeException('The unmerge file does not match its merge log.');
        }
        context.objectDescribe = context.data.survivorId.getSObjectType().getDescribe();
        return context;
    }

    /**
     * parseUnmergeData()
     * Read the unmerge file. Parsed by hand because JSON.deserialize can't fill Object values.
     */
    @TestVisible
    private static UnmergeData parseUnmergeData(String body) {
        Map<String, Object> raw;
        try {
            raw = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (Exception e) {
            throw new RecordMergeService.RecordMergeException('The unmerge file is not valid: ' + e.getMessage());
        }

        UnmergeData data = new UnmergeData();
        data.formatVersion = raw.get('formatVersion') == null ? null : Integer.valueOf(raw.get('formatVersion'));
        if (data.formatVersion == null || data.formatVersion > FORMAT_VERSION) {
            throw new RecordMergeService.RecordMergeException('The unmerge file was written by a newer version of Record Merge.');
        }
        data.objectApiName = (String) raw.get('objectApiName');
        data.logId = toId(raw.get('logId'));
        data.survivorId = toId(raw.get('survivorId'));
        data.survivorName = (String) raw.get('survivorName');
        data.abandonedId = toId(raw.get('abandonedId'));
        data.abandonedName = (String) raw.get('abandonedName');
        data.mergedById = toId(raw.get('mergedById'));
        if (raw.get('mergedOn') != null) {
            data.mergedOn = (Datetime) JSON.deserialize(JSON.serialize(raw.get('mergedOn')), Datetime.class);
        }

        Map<String, Object> abandonedValues = (Map<String, Object>) raw.get('abandonedValues');
        if (abandonedValues != null) {
            data.abandonedValues = abandonedValues;
        }
        Map<String, Object> displayValues = (Map<String, Object>) raw.get('abandonedDisplayValues');
        if (displayValues != null) {
            for (String apiName : displayValues.keySet()) {
                data.abandonedDisplayValues.put(apiName, (String) displayValues.get(apiName));
            }
        }

        Map<String, Object> survivorChanges = (Map<String, Object>) raw.get('survivorChanges');
        if (survivorChanges != null) {
            for (String apiName : survivorChanges.keySet()) {
                Map<String, Object> rawChange = (Map<String, Object>) survivorChanges.get(apiName);
                SurvivorChange change = new SurvivorChange();
                change.label = (String) rawChange.get('label');
                change.previousValue = rawChange.get('previousValue');
                change.newValue = rawChange.get('newValue');
                change.previousDisplay = (String) rawChange.get('previousDisplay');
                change.newDisplay = (String) rawChange.get('newDisplay');
                data.survivorChanges.put(apiName, change);
            }
        }

        Map<String, Object> reparented = (Map<String, Object>) raw.get('reparentedRecords');
        if (reparented != null) {
            for (String key : reparented.keySet()) {
                List<Id> ids = new List<Id>();
                for (Object recordId : (List<Object>) reparented.get(key)) {
                    ids.add(toId(recordId));
                }
                data.reparentedRecords.put(key, ids);
            }
        }
        return data;
    }

    private static Id toId(Object value) {
        if (value == null) {
            return null;
        }
        try {
            return Id.valueOf(String.valueOf(value));
        } catch (Exception e) {
            throw new RecordMergeService.RecordMergeException('The unmerge file has an invalid record Id: ' + value);
        }
    }

    /**
     * toFieldValue()
     * Convert a value read back from JSON to the Apex type of its field
     * (dates and times come back as strings, numbers as Integer or Decimal).
     */
    @TestVisible
    private static Object toFieldValue(Schema.DescribeFieldResult fieldDescribe, Object value) {
        if (value == null) {
            return null;
        }
        String text = String.valueOf(value);
        switch on fieldDescribe.getType() {
            when BOOLEAN {
                return value instanceof Boolean ? value : Boolean.valueOf(text);
            }
            when INTEGER {
                return Decimal.valueOf(text).intValue();
            }
            when LONG {
                return Decimal.valueOf(text).longValue();
            }
            when DOUBLE, CURRENCY, PERCENT {
                return Decimal.valueOf(text);
            }
            when DATE {
                return Date.valueOf(text);
            }
            when DATETIME {
                return (Datetime) JSON.deserialize(JSON.serialize(text), Datetime.class);
            }
            when TIME {
                return (Time) JSON.deserialize(JSON.serialize(text), Time.class);
            }
            when else {
                return text;
            }
        }
    }

    //End - file helpers

    /**
     * SystemContext
     * Reads logs and unmerge files and moves child records without sharing, like the
     * merge does. Logs may be owned by another user, and every child that was moved
     * by the merge should be able to move back, not just the ones the user can see.
     */
    private without sharing class SystemContext {

        public List<UnmergeOption> findUnmergeOptions(Id survivorId) {
            String survivorKey = String.valueOf(survivorId);
            List<Record_Merge_Log__c> logs = [
                SELECT Id, Name, Abandoned_Record_Id__c, Abandoned_Record_Name__c, CreatedDate, CreatedBy.Name
                FROM Record_Merge_Log__c
                WHERE Surviving_Record_Id__c = :survivorKey AND Unmerged_On__c = null
                ORDER BY CreatedDate DESC
                LIMIT :MAX_OPTIONS
            ];

            List<UnmergeOption> options = new List<UnmergeOption>();
            if (logs.isEmpty()) {
                return options;
            }
            Map<Id, Id> documentIdsByLog = findUnmergeDocumentIds(logs);
            for (Record_Merge_Log__c log : logs) {
                if (!documentIdsByLog.containsKey(log.Id)) {
                    continue;
                }
                UnmergeOption option = new UnmergeOption();
                option.logId = log.Id;
                option.logName = log.Name;
                option.abandonedId = log.Abandoned_Record_Id__c;
                option.abandonedName = log.Abandoned_Record_Name__c;
                option.mergedOn = log.CreatedDate;
                option.mergedByName = log.CreatedBy?.Name;
                option.unmergeFileId = documentIdsByLog.get(log.Id);
                options.add(option);
            }
            return options;
        }

        public UnmergeContext loadUnmergeFile(Id logId) {
            List<Record_Merge_Log__c> logs = [
                SELECT Id, Name, Object_Api_Name__c, Surviving_Record_Id__c, Abandoned_Record_Id__c,
                    Abandoned_Record_Name__c, Unmerged_On__c, CreatedDate, CreatedBy.Name
                FROM Record_Merge_Log__c
                WHERE Id = :logId
            ];
            if (logs.isEmpty()) {
                throw new RecordMergeService.RecordMergeException('The merge log could not be found.');
            }
            Record_Merge_Log__c log = logs[0];
            if (log.Unmerged_On__c != null) {
                throw new RecordMergeService.RecordMergeException('This merge was already unmerged on ' + log.Unmerged_On__c.format() + '.');
            }

            Id documentId = findUnmergeDocumentIds(logs).get(log.Id);
            if (documentId == null) {
                throw new RecordMergeService.RecordMergeException('The unmerge file for this merge no longer exists, so it cannot be unmerged.');
            }
            ContentVersion version = [
                SELECT VersionData FROM ContentVersion
                WHERE ContentDocumentId = :documentId AND IsLatest = true
                LIMIT 1
            ];

            UnmergeContext context = new UnmergeContext();
            context.log = log;
            context.data = parseUnmergeData(version.VersionData.toString());
            return context;
        }

        //Log Id -> ContentDocument Id of its unmerge file
        private Map<Id, Id> findUnmergeDocumentIds(List<Record_Merge_Log__c> logs) {
            Map<Id, String> titlesByLog = new Map<Id, String>();
            for (Record_Merge_Log__c log : logs) {
                if (String.isNotBlank(log.Abandoned_Record_Id__c)) {
                    titlesByLog.put(log.Id, FILE_PREFIX + log.Abandoned_Record_Id__c);
                }
            }

            Map<Id, Id> documentIdsByLog = new Map<Id, Id>();
            if (titlesByLog.isEmpty()) {
                return documentIdsByLog;
            }
            Set<Id> logIds = titlesByLog.keySet();
            for (ContentDocumentLink link : [
                    SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title
                    FROM ContentDocumentLink
                    WHERE LinkedEntityId IN :logIds]) {
                if (link.ContentDocument.Title == titlesByLog.get(link.LinkedEntityId)) {
                    documentIdsByLog.put(link.LinkedEntityId, link.ContentDocumentId);
                }
            }
            return documentIdsByLog;
        }

        /**
         * getRestoreMode()
         * UNDELETE when the abandoned record is in the recycle bin, EXISTS when it was
         * already restored some other way, RECREATE when it has been purged.
         */
        public String getRestoreMode(Schema.DescribeSObjectResult objectDescribe, Id recordId) {
            if (Test.isRunningTest() && simulatePurgedRecord) {
                return MODE_RECREATE;
            }
            Map<String, Object> binds = new Map<String, Object>{ 'recordId' => recordId };
            List<SObject> rows;
            try {
                rows = Database.queryWithBinds('SELECT Id, IsDeleted FROM ' + objectDescribe.getName() + ' WHERE Id = :recordId ALL ROWS',
                    binds, AccessLevel.SYSTEM_MODE);
            } catch (Exception e) {
                //Objects without a recycle bin
                rows = Database.queryWithBinds('SELECT Id FROM ' + objectDescribe.getName() + ' WHERE Id = :recordId',
                    binds, AccessLevel.SYSTEM_MODE);
                return rows.isEmpty() ? MODE_RECREATE : MODE_EXISTS;
            }
            if (rows.isEmpty()) {
                return MODE_RECREATE;
            }
            return rows[0].get('IsDeleted') == true ? MODE_UNDELETE : MODE_EXISTS;
        }

        /**
         * getRelatedGroups()
         * The records the merge moved that still point at the survivor, by relationship.
         */
        public List<RelatedGroup> getRelatedGroups(Schema.SObjectType parentType, Map<String, List<Id>> reparented, Id survivorId) {
            List<RelatedGroup> groups = new List<RelatedGroup>();
            List<String> keys = new List<String>(reparented.keySet());
            keys.sort();

            for (String key : keys) {
                RelatedTarget target = parseTarget(parentType, key);
                List<Id> recordIds = reparented.get(key);
                if (target == null || recordIds.isEmpty()) {
                    continue;
                }

                RelatedGroup relatedGroup = new RelatedGroup();
                relatedGroup.key = key;
                relatedGroup.childObjectApiName = target.childDescribe.getName();
                relatedGroup.fieldApiName = target.fieldDescribe.getName();
                relatedGroup.label = target.isContentDocumentLink
                    ? 'Files'
                    : target.childDescribe.getLabelPlural() + ' (' + target.fieldDescribe.getLabel() + ')';
                relatedGroup.movedCount = recordIds.size();

                if (target.isContentDocumentLink) {
                    for (ContentDocumentLink link : [
                            SELECT ContentDocumentId, ContentDocument.Title FROM ContentDocumentLink
                            WHERE LinkedEntityId = :survivorId AND ContentDocumentId IN :recordIds]) {
                        relatedGroup.records.add(new RelatedRecord(link.ContentDocumentId, link.ContentDocument.Title));
                    }
                } else {
                    String nameField = findNameField(target.childDescribe);
                    String query = String.format('SELECT Id{0} FROM {1} WHERE Id IN :recordIds AND {2} = :survivorId ORDER BY Id', new List<Object>{
                        nameField == null ? '' : ', ' + nameField,
                        target.childDescribe.getName(),
                        target.fieldDescribe.getName()
                    });
                    for (SObject child : Database.queryWithBinds(query,
                            new Map<String, Object>{ 'recordIds' => recordIds, 'survivorId' => survivorId }, AccessLevel.SYSTEM_MODE)) {
                        Object name = nameField == null ? null : child.get(nameField);
                        relatedGroup.records.add(new RelatedRecord(child.Id, name == null ? String.valueOf(child.Id) : String.valueOf(name)));
                    }
                }

                if (!relatedGroup.records.isEmpty()) {
                    groups.add(relatedGroup);
                }
            }
            return groups;
        }

        /**
         * moveRelatedBack()
         * Point the chosen child records (and files) that the merge moved back at the
         * restored record. Records that no longer point at the survivor are left alone.
         * @return How many records and files were moved
         */
        public Integer moveRelatedBack(Schema.SObjectType parentType, Map<String, List<Id>> reparented,
                Set<Id> selectedIds, Id survivorId, Id restoredId) {

            Integer movedCount = 0;
            if (selectedIds.isEmpty()) {
                return movedCount;
            }

            Map<Schema.SObjectType, Map<Id, SObject>> updatesByType = new Map<Schema.SObjectType, Map<Id, SObject>>();
            List<ContentDocumentLink> linksToInsert = new List<ContentDocumentLink>();
            List<ContentDocumentLink> linksToDelete = new List<ContentDocumentLink>();

            for (String key : reparented.keySet()) {
                Set<Id> recordIds = new Set<Id>(reparented.get(key));
                recordIds.retainAll(selectedIds);
                RelatedTarget target = parseTarget(parentType, key);
                if (recordIds.isEmpty() || target == null) {
                    continue;
                }

                if (target.isContentDocumentLink) {
                    //An undeleted record gets its own file links back, so only add the missing ones
                    Set<Id> alreadyLinked = new Set<Id>();
                    for (ContentDocumentLink link : [
                            SELECT ContentDocumentId FROM ContentDocumentLink
                            WHERE LinkedEntityId = :restoredId AND ContentDocumentId IN :recordIds]) {
                        alreadyLinked.add(link.ContentDocumentId);
                    }
                    for (ContentDocumentLink link : [
                            SELECT Id, ContentDocumentId, ShareType, Visibility FROM ContentDocumentLink
                            WHERE LinkedEntityId = :survivorId AND ContentDocumentId IN :recordIds]) {
                        if (!alreadyLinked.contains(link.ContentDocumentId)) {
                            linksToInsert.add(new ContentDocumentLink(
                                LinkedEntityId = restoredId,
                                ContentDocumentId = link.ContentDocumentId,
                                ShareType = link.ShareType,
                                Visibility = link.Visibility
                            ));
                        }
                        linksToDelete.add(link);
                        movedCount++;
                    }
                    continue;
                }

                String query = String.format('SELECT Id FROM {0} WHERE Id IN :recordIds AND {1} = :survivorId', new List<Object>{
                    target.childDescribe.getName(),
                    target.fieldDescribe.getName()
                });
                List<SObject> children = Database.queryWithBinds(query,
                    new Map<String, Object>{ 'recordIds' => recordIds, 'survivorId' => survivorId }, AccessLevel.SYSTEM_MODE);

                if (!updatesByType.containsKey(target.childType)) {
                    updatesByType.put(target.childType, new Map<Id, SObject>());
                }
                Map<Id, SObject> typeUpdates = updatesByType.get(target.childType);
                for (SObject child : children) {
                    SObject childUpdate = typeUpdates.get(child.Id);
                    if (childUpdate == null) {
                        childUpdate = target.childType.newSObject(child.Id);
                        typeUpdates.put(child.Id, childUpdate);
                    }
                    childUpdate.put(target.fieldDescribe.getName(), restoredId);
                    movedCount++;
                }
            }

            Integer rowCount = linksToInsert.size() + linksToDelete.size();
            for (Map<Id, SObject> typeUpdates : updatesByType.values()) {
                rowCount += typeUpdates.size();
            }
            //+1 leaves room for the log update
            if (Limits.getDmlRows() + rowCount + 1 > Limits.getLimitDmlRows()) {
                throw new RecordMergeService.RecordMergeException('Too many related records (' + rowCount + ') to move back in one transaction. Select fewer records.');
            }

            for (Map<Id, SObject> typeUpdates : updatesByType.values()) {
                if (!typeUpdates.isEmpty()) {
                    Database.update(typeUpdates.values(), AccessLevel.SYSTEM_MODE);
                }
            }
            if (!linksToInsert.isEmpty()) {
                Database.insert(linksToInsert, AccessLevel.SYSTEM_MODE);
            }
            if (!linksToDelete.isEmpty()) {
                Database.delete(linksToDelete, AccessLevel.SYSTEM_MODE);
            }
            return movedCount;
        }

        /**
         * parseTarget()
         * Turn a "ChildObject.LookupField" key from the unmerge file into its describes.
         * Returns null unless the field is still an updateable lookup to the merged object.
         */
        private RelatedTarget parseTarget(Schema.SObjectType parentType, String key) {
            List<String> parts = key == null ? new List<String>() : key.split('\\.');
            if (parts.size() != 2) {
                return null;
            }
            Schema.SObjectType childType = Schema.getGlobalDescribe().get(parts[0]);
            if (childType == null) {
                return null;
            }
            Schema.DescribeSObjectResult childDescribe = childType.getDescribe(SObjectDescribeOptions.DEFERRED);
            Schema.SObjectField field = childDescribe.fields.getMap().get(parts[1]);
            if (field == null) {
                return null;
            }

            RelatedTarget target = new RelatedTarget();
            target.childType = childType;
            target.childDescribe = childDescribe;
            target.fieldDescribe = field.getDescribe();
            target.isContentDocumentLink = childDescribe.getName() == CONTENT_DOCUMENT_LINK;
            if (target.isContentDocumentLink) {
                return target;
            }
            if (target.fieldDescribe.getType() != Schema.DisplayType.REFERENCE ||
                    !target.fieldDescribe.getReferenceTo().contains(parentType) ||
                    !target.fieldDescribe.isUpdateable()) {
                return null;
            }
            return target;
        }

        private String findNameField(Schema.DescribeSObjectResult childDescribe) {
            for (Schema.SObjectField field : childDescribe.fields.getMap().values()) {
                Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
                if (fieldDescribe.isNameField()) {
                    return fieldDescribe.getName();
                }
            }
            return null;
        }
    }

    private class UnmergeContext {
        public Record_Merge_Log__c log;
        public UnmergeData data;
        public Schema.DescribeSObjectResult objectDescribe;
    }

    private class RelatedTarget {
        public Schema.SObjectType childType;
        public Schema.DescribeSObjectResult childDescribe;
        public Schema.DescribeFieldResult fieldDescribe;
        public Boolean isContentDocumentLink;
    }

    /**
     * UnmergeData
     * The contents of the unmerge file.
     */
    public class UnmergeData {
        public Integer formatVersion;
        public String objectApiName;
        public Id logId;
        public Id survivorId;
        public String survivorName;
        public Id abandonedId;
        public String abandonedName;
        public Datetime mergedOn;
        public Id mergedById;
        //Every accessible field of the abandoned record when it was merged
        public Map<String, Object> abandonedValues = new Map<String, Object>();
        //Display values (lookup names, formatted dates) for the editable fields
        public Map<String, String> abandonedDisplayValues = new Map<String, String>();
        //Fields the merge changed on the survivor. Written from RecordMergeService's field changes
        //(maps with the same keys as SurvivorChange) and read back as SurvivorChange
        public Map<String, Object> survivorChanges = new Map<String, Object>();
        //ChildObject.LookupField -> Ids moved to the survivor (ContentDocument Ids for files)
        public Map<String, List<Id>> reparentedRecords = new Map<String, List<Id>>();
    }

    public class SurvivorChange {
        public String label;
        public Object previousValue;
        public Object newValue;
        public String previousDisplay;
        public String newDisplay;
    }

    public class UnmergeOption {
        public Id logId;
        public String logName;
        public String abandonedId;
        public String abandonedName;
        public Datetime mergedOn;
        public String mergedByName;
        public Id unmergeFileId;
    }

    public class UnmergePreview {
        public Id logId;
        public String logName;
        public String objectApiName;
        public String objectLabel;
        public Id survivorId;
        public String survivorName;
        public Id abandonedId;
        public String abandonedName;
        public Datetime mergedOn;
        public String mergedByName;
        //UNDELETE, RECREATE or EXISTS
        public String restoreMode;
        //A = the abandoned record's value at the merge, B = the survivor's current value
        public List<RecordMergeService.FieldComparison> restoredFields = new List<RecordMergeService.FieldComparison>();
        //A = the survivor's current value, B = its value before the merge
        public List<RecordMergeService.FieldComparison> survivorFields = new List<RecordMergeService.FieldComparison>();
        //Survivor fields edited again after the merge
        public List<String> survivorFieldsChangedSinceMerge = new List<String>();
        public List<RelatedGroup> relatedGroups = new List<RelatedGroup>();
    }

    public class RelatedGroup {
        public String key;
        public String label;
        public String childObjectApiName;
        public String fieldApiName;
        //How many the merge moved; records may be fewer if some were moved or deleted since
        public Integer movedCount;
        public List<RelatedRecord> records = new List<RelatedRecord>();
    }

    public class RelatedRecord {
        public Id id;
        public String name;

        public RelatedRecord(Id id, String name) {
            this.id = id;
            this.name = name;
        }
    }

    public class UnmergeRequest {
        public Id logId;
        //Fields the restored record takes from the survivor instead of its own value from the merge
        public List<String> restoredFromSurvivor;
        //Survivor fields to put back to their value from before the merge
        public List<String> survivorFieldsToRevert;
        //Child record and ContentDocument Ids to move back to the restored record
        public List<Id> relatedRecordIds;
    }

    public class UnmergeResult {
        public Id logId;
        public Id survivorId;
        public Id restoredId;
        public String restoredName;
        public String restoreMode;
        public List<String> revertedFields;
        public Integer movedCount;
    }
}
