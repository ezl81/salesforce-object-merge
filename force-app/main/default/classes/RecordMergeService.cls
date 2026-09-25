/**
 * RecordMergeService
 *
 * Generic merge of two records of the same SObject type. Works for any object
 * (Database.merge only supports Account, Contact, Lead, Case and Individual).
 *
 * A merge:
 *  1. Copies the chosen field values from the abandoned record to the survivor.
 *  2. Re-parents every child record of the abandoned record to the survivor.
 *  3. Writes a Record_Merge_Log__c with a JSON snapshot of the abandoned record.
 *  4. Deletes the abandoned record (it goes to the recycle bin).
 * Everything runs under one savepoint, so any failure rolls the whole merge back.
 *
 * Security: the survivor update and the abandoned delete run in USER_MODE, so the
 * user needs edit and delete access on the object and FLS on the copied fields.
 * Child records are re-parented without sharing (like the standard merge) so
 * records the user can't see aren't orphaned or cascade-deleted. The user still
 * needs edit access on the child object and lookup field.
 *
 * Usage (see RecordMergeController):
 *
 *     RecordMergeService.ComparisonResult comparison = RecordMergeService.getComparison(recordIdA, recordIdB);
 *
 *     RecordMergeService.MergeRequest request = new RecordMergeService.MergeRequest();
 *     request.survivorId = recordIdA;
 *     request.abandonedId = recordIdB;
 *     request.selections = new Map<String, String>{ 'Phone' => recordIdB };
 *     RecordMergeService.MergeResult result = RecordMergeService.mergeRecords(request);
 */
public with sharing class RecordMergeService {

    public static final Integer LONG_TEXT_MAX_LENGTH = 131072;

    //ContentDocumentLink.LinkedEntityId can't be updated, so files are moved
    //by inserting a new link for the survivor instead.
    private static final String CONTENT_DOCUMENT_LINK = 'ContentDocumentLink';

    //Queries kept in reserve so the merge can finish once re-parenting is done.
    private static final Integer QUERY_HEADROOM = 5;

    @TestVisible
    private static Boolean simulateFailureBeforeDelete = false;

    //Start - comparison

    /**
     * getComparison()
     * Compare every field the user can edit on two records of the same type,
     * and count the child records attached to each one.
     * @param recordIdA The first record (the current record page)
     * @param recordIdB The second record (the one picked by the user)
     */
    public static ComparisonResult getComparison(Id recordIdA, Id recordIdB) {
        validateIds(recordIdA, recordIdB);

        Schema.DescribeSObjectResult objectDescribe = recordIdA.getSObjectType().getDescribe();
        Map<Id, SObject> records = queryRecords(objectDescribe, new Set<Id>{ recordIdA, recordIdB });
        SObject recordA = records.get(recordIdA);
        SObject recordB = records.get(recordIdB);

        ComparisonResult result = new ComparisonResult();
        result.objectApiName = objectDescribe.getName();
        result.objectLabel = objectDescribe.getLabel();
        result.recordIdA = recordIdA;
        result.recordIdB = recordIdB;
        result.nameA = getRecordName(objectDescribe, recordA);
        result.nameB = getRecordName(objectDescribe, recordB);

        for (Schema.DescribeFieldResult fieldDescribe : getComparableFields(objectDescribe)) {
            result.fields.add(buildFieldComparison(fieldDescribe, recordA, recordB));
        }

        new SystemContext().countChildren(getReparentTargets(objectDescribe), recordIdA, recordIdB, result);
        return result;
    }

    private static FieldComparison buildFieldComparison(Schema.DescribeFieldResult fieldDescribe, SObject recordA, SObject recordB) {
        FieldComparison comparison = new FieldComparison();
        comparison.apiName = fieldDescribe.getName();
        comparison.label = fieldDescribe.getLabel();
        comparison.type = fieldDescribe.getType().name();
        comparison.valueA = recordA.get(comparison.apiName);
        comparison.valueB = recordB.get(comparison.apiName);
        comparison.displayA = getDisplayValue(fieldDescribe, recordA);
        comparison.displayB = getDisplayValue(fieldDescribe, recordB);
        comparison.isDifferent = !valuesEqual(comparison.valueA, comparison.valueB);
        return comparison;
    }

    //End - comparison

    //Start - merge

    /**
     * mergeRecords()
     * Merge the abandoned record into the survivor. Only the field names and the
     * record each value comes from are taken from the request; the values themselves
     * are always read from the database.
     * @param request survivorId, abandonedId and selections (field API name -> Id of the record to take the value from)
     */
    public static MergeResult mergeRecords(MergeRequest request) {
        if (request == null) {
            throw new RecordMergeException('A merge request is required.');
        }
        validateIds(request.survivorId, request.abandonedId);

        Schema.DescribeSObjectResult objectDescribe = request.survivorId.getSObjectType().getDescribe();
        if (!objectDescribe.isUpdateable() || !objectDescribe.isDeletable()) {
            throw new RecordMergeException('You need edit and delete access on ' + objectDescribe.getLabelPlural() + ' to merge records.');
        }

        Map<String, Schema.DescribeFieldResult> comparableFields = new Map<String, Schema.DescribeFieldResult>();
        for (Schema.DescribeFieldResult fieldDescribe : getComparableFields(objectDescribe)) {
            comparableFields.put(fieldDescribe.getName().toLowerCase(), fieldDescribe);
        }

        Savepoint savepoint = Database.setSavepoint();
        try {
            Map<Id, SObject> records = queryRecords(objectDescribe, new Set<Id>{ request.survivorId, request.abandonedId });
            SObject survivor = records.get(request.survivorId);
            SObject abandoned = records.get(request.abandonedId);

            Map<String, Object> fieldChanges = copySelectedFields(objectDescribe, comparableFields, request, survivor, abandoned);

            Map<String, List<Id>> reparentedIds = new SystemContext().reparentChildren(
                getReparentTargets(objectDescribe), request.survivorId, request.abandonedId);

            Record_Merge_Log__c log = new Record_Merge_Log__c(
                Object_Api_Name__c = objectDescribe.getName(),
                Surviving_Record_Id__c = String.valueOf(request.survivorId),
                Abandoned_Record_Id__c = String.valueOf(request.abandonedId),
                Abandoned_Record_Name__c = getRecordName(objectDescribe, abandoned).left(255),
                Abandoned_Record_JSON__c = toLogJson(abandoned),
                Field_Selections_JSON__c = toLogJson(fieldChanges),
                Reparented_Records_JSON__c = toLogJson(reparentedIds)
            );
            //System mode so the history is always written, whatever the user's access to the log object
            Database.insert(log, AccessLevel.SYSTEM_MODE);

            if (Test.isRunningTest() && simulateFailureBeforeDelete) {
                throw new RecordMergeException('Simulated failure before delete');
            }

            Database.delete(objectDescribe.getSObjectType().newSObject(request.abandonedId), AccessLevel.USER_MODE);

            MergeResult result = new MergeResult();
            result.logId = log.Id;
            result.survivorId = request.survivorId;
            result.abandonedId = request.abandonedId;
            result.reparentedCount = 0;
            for (List<Id> ids : reparentedIds.values()) {
                result.reparentedCount += ids.size();
            }
            return result;
        } catch (Exception e) {
            Database.rollback(savepoint);
            System.debug('RecordMergeService.mergeRecords failed: ' + e.getMessage());
            System.debug(e.getStackTraceString());
            throw e;
        }
    }

    /**
     * copySelectedFields()
     * Update the survivor with every value the user chose from the abandoned record.
     * Returns fieldApiName -> { label, previousValue, newValue } for the log.
     */
    private static Map<String, Object> copySelectedFields(Schema.DescribeSObjectResult objectDescribe,
            Map<String, Schema.DescribeFieldResult> comparableFields, MergeRequest request, SObject survivor, SObject abandoned) {

        Map<String, Object> fieldChanges = new Map<String, Object>();
        if (request.selections == null || request.selections.isEmpty()) {
            return fieldChanges;
        }

        SObject survivorUpdate = objectDescribe.getSObjectType().newSObject(request.survivorId);
        SObject abandonedUpdate = objectDescribe.getSObjectType().newSObject(request.abandonedId);
        Boolean clearAbandonedUniqueValues = false;

        for (String fieldName : request.selections.keySet()) {
            Schema.DescribeFieldResult fieldDescribe = comparableFields.get(fieldName.toLowerCase());
            if (fieldDescribe == null) {
                throw new RecordMergeException('The field ' + fieldName + ' cannot be merged.');
            }

            Id sourceId = toId(request.selections.get(fieldName));
            if (sourceId == request.survivorId) {
                continue;
            }
            if (sourceId != request.abandonedId) {
                throw new RecordMergeException('The value for ' + fieldDescribe.getLabel() + ' must come from one of the two records being merged.');
            }

            String apiName = fieldDescribe.getName();
            Object previousValue = survivor.get(apiName);
            Object newValue = abandoned.get(apiName);
            if (valuesEqual(previousValue, newValue)) {
                continue;
            }
            //A lookup pointing at the survivor would make the record its own parent
            if (fieldDescribe.getType() == Schema.DisplayType.REFERENCE && newValue != null &&
                    Id.valueOf(String.valueOf(newValue)) == request.survivorId) {
                continue;
            }

            survivorUpdate.put(apiName, newValue);
            //A unique value can't exist on both records at once, so clear it on the abandoned record first
            if (fieldDescribe.isUnique() && fieldDescribe.isNillable()) {
                abandonedUpdate.put(apiName, null);
                clearAbandonedUniqueValues = true;
            }
            fieldChanges.put(apiName, new Map<String, Object>{
                'label' => fieldDescribe.getLabel(),
                'previousValue' => previousValue,
                'newValue' => newValue
            });
        }

        if (clearAbandonedUniqueValues) {
            Database.update(abandonedUpdate, AccessLevel.USER_MODE);
        }
        if (!fieldChanges.isEmpty()) {
            Database.update(survivorUpdate, AccessLevel.USER_MODE);
        }
        return fieldChanges;
    }

    //End - merge

    //Start - describe helpers

    /**
     * getComparableFields()
     * Fields the user can read and edit, sorted by label. Compound Address and
     * Geolocation fields are skipped - their component fields are compared instead.
     */
    @TestVisible
    private static List<Schema.DescribeFieldResult> getComparableFields(Schema.DescribeSObjectResult objectDescribe) {
        Map<String, Schema.DescribeFieldResult> fieldsBySortKey = new Map<String, Schema.DescribeFieldResult>();
        for (Schema.SObjectField field : objectDescribe.fields.getMap().values()) {
            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
            if (fieldDescribe.isAccessible() && fieldDescribe.isUpdateable() && !isExcludedType(fieldDescribe.getType())) {
                fieldsBySortKey.put(fieldDescribe.getLabel().toLowerCase() + '|' + fieldDescribe.getName(), fieldDescribe);
            }
        }
        List<String> sortKeys = new List<String>(fieldsBySortKey.keySet());
        sortKeys.sort();

        List<Schema.DescribeFieldResult> fields = new List<Schema.DescribeFieldResult>();
        for (String sortKey : sortKeys) {
            fields.add(fieldsBySortKey.get(sortKey));
        }
        return fields;
    }

    private static Boolean isExcludedType(Schema.DisplayType fieldType) {
        return fieldType == Schema.DisplayType.ADDRESS ||
            fieldType == Schema.DisplayType.LOCATION ||
            fieldType == Schema.DisplayType.BASE64;
    }

    /**
     * getReparentTargets()
     * Child relationships whose lookup can be pointed at another parent: the child
     * object must be queryable and updateable and the lookup field updateable.
     * This leaves out History, Share and Feed objects and master-detail
     * relationships that don't allow re-parenting.
     */
    @TestVisible
    private static List<ReparentTarget> getReparentTargets(Schema.DescribeSObjectResult objectDescribe) {
        List<ReparentTarget> targets = new List<ReparentTarget>();
        Set<String> seenKeys = new Set<String>();

        for (Schema.ChildRelationship relationship : objectDescribe.getChildRelationships()) {
            Schema.DescribeSObjectResult childDescribe = relationship.getChildSObject().getDescribe(SObjectDescribeOptions.DEFERRED);
            Schema.DescribeFieldResult fieldDescribe = relationship.getField().getDescribe();
            String key = childDescribe.getName() + '.' + fieldDescribe.getName();
            if (seenKeys.contains(key)) {
                continue;
            }
            seenKeys.add(key);

            Boolean isContentDocumentLink = childDescribe.getName() == CONTENT_DOCUMENT_LINK;
            Boolean canReparent = childDescribe.isQueryable() && childDescribe.isUpdateable() &&
                fieldDescribe.isUpdateable() && fieldDescribe.isFilterable();
            if (!isContentDocumentLink && !canReparent) {
                continue;
            }

            ReparentTarget target = new ReparentTarget();
            target.childType = relationship.getChildSObject();
            target.childObjectApiName = childDescribe.getName();
            target.childObjectLabel = childDescribe.getLabelPlural();
            target.fieldApiName = fieldDescribe.getName();
            target.fieldLabel = fieldDescribe.getLabel();
            target.isGroupable = fieldDescribe.isGroupable() && !isContentDocumentLink;
            target.isSelfRelationship = relationship.getChildSObject() == objectDescribe.getSObjectType();
            targets.add(target);
        }
        return targets;
    }

    /**
     * lookupNamePath()
     * Relationship path used to show a lookup's name instead of its Id
     * (e.g. OwnerId -> Owner.Name), or null when the target has no readable Name.
     */
    private static String lookupNamePath(Schema.DescribeFieldResult fieldDescribe) {
        if (fieldDescribe.getType() != Schema.DisplayType.REFERENCE || String.isBlank(fieldDescribe.getRelationshipName())) {
            return null;
        }
        List<Schema.SObjectType> referenceTo = fieldDescribe.getReferenceTo();
        if (referenceTo.isEmpty()) {
            return null;
        }
        //Polymorphic lookups (Owner, What, Who) always expose Name
        if (referenceTo.size() == 1) {
            Schema.DescribeSObjectResult targetDescribe = referenceTo[0].getDescribe(SObjectDescribeOptions.DEFERRED);
            Schema.SObjectField nameField = targetDescribe.fields.getMap().get('Name');
            if (!targetDescribe.isAccessible() || nameField == null ||
                    !nameField.getDescribe().isAccessible() || !nameField.getDescribe().isNameField()) {
                return null;
            }
        }
        return fieldDescribe.getRelationshipName() + '.Name';
    }

    //End - describe helpers

    //Start - record helpers

    /**
     * queryRecords()
     * Query both records with every accessible field (for the log snapshot) plus
     * the lookup names used for display. Throws if either record isn't visible.
     */
    private static Map<Id, SObject> queryRecords(Schema.DescribeSObjectResult objectDescribe, Set<Id> recordIds) {
        Set<String> selectFields = new Set<String>{ 'Id' };
        for (Schema.SObjectField field : objectDescribe.fields.getMap().values()) {
            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
            if (!fieldDescribe.isAccessible() || isExcludedType(fieldDescribe.getType())) {
                continue;
            }
            selectFields.add(fieldDescribe.getName());
            if (fieldDescribe.isUpdateable()) {
                String namePath = lookupNamePath(fieldDescribe);
                if (namePath != null) {
                    selectFields.add(namePath);
                }
            }
        }

        String query = String.format('SELECT {0} FROM {1} WHERE Id IN :recordIds', new List<Object>{
            String.join(new List<String>(selectFields), ', '),
            objectDescribe.getName()
        });
        System.debug('RecordMergeService query = ' + query);

        Map<Id, SObject> records = new Map<Id, SObject>(Database.queryWithBinds(
            query, new Map<String, Object>{ 'recordIds' => recordIds }, AccessLevel.USER_MODE));
        if (records.size() != recordIds.size()) {
            throw new RecordMergeException('One or both records could not be found, or you do not have access to them.');
        }
        return records;
    }

    private static String getRecordName(Schema.DescribeSObjectResult objectDescribe, SObject record) {
        for (Schema.SObjectField field : objectDescribe.fields.getMap().values()) {
            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
            if (fieldDescribe.isNameField() && fieldDescribe.isAccessible()) {
                Object name = record.get(fieldDescribe.getName());
                if (name != null) {
                    return String.valueOf(name);
                }
            }
        }
        return String.valueOf(record.Id);
    }

    private static String getDisplayValue(Schema.DescribeFieldResult fieldDescribe, SObject record) {
        Object value = record.get(fieldDescribe.getName());
        if (value == null) {
            return '';
        }
        switch on fieldDescribe.getType() {
            when DATE {
                return ((Date) value).format();
            }
            when DATETIME {
                return ((Datetime) value).format();
            }
            when BOOLEAN {
                return (Boolean) value ? 'True' : 'False';
            }
            when REFERENCE {
                if (lookupNamePath(fieldDescribe) != null) {
                    SObject related = record.getSObject(fieldDescribe.getRelationshipName());
                    if (related != null && related.get('Name') != null) {
                        return String.valueOf(related.get('Name'));
                    }
                }
                return String.valueOf(value);
            }
            when else {
                return String.valueOf(value);
            }
        }
    }

    //String == is case-insensitive in Apex, so compare with equals() to catch case-only differences
    @TestVisible
    private static Boolean valuesEqual(Object valueA, Object valueB) {
        if (valueA == null || valueB == null) {
            return valueA == null && valueB == null;
        }
        return String.valueOf(valueA).equals(String.valueOf(valueB));
    }

    private static void validateIds(Id recordIdA, Id recordIdB) {
        if (recordIdA == null || recordIdB == null) {
            throw new RecordMergeException('Two records are required to merge.');
        }
        if (recordIdA == recordIdB) {
            throw new RecordMergeException('Choose two different records to merge.');
        }
        if (recordIdA.getSObjectType() != recordIdB.getSObjectType()) {
            throw new RecordMergeException('Both records must be the same type of record.');
        }
    }

    private static Id toId(String value) {
        try {
            return Id.valueOf(value);
        } catch (Exception e) {
            throw new RecordMergeException('Invalid record Id: ' + value);
        }
    }

    /**
     * toLogJson()
     * Serialize a value for a Long Text Area on the log. Anything too long is
     * wrapped as { "_truncated": true, "originalLength": n, "content": "..." }.
     */
    @TestVisible
    private static String toLogJson(Object value) {
        String serialized = JSON.serializePretty(value);
        if (serialized.length() <= LONG_TEXT_MAX_LENGTH) {
            return serialized;
        }

        Integer contentLength = LONG_TEXT_MAX_LENGTH - 1000;
        String truncated;
        do {
            truncated = JSON.serialize(new Map<String, Object>{
                '_truncated' => true,
                'originalLength' => serialized.length(),
                'content' => serialized.left(contentLength)
            });
            contentLength -= 10000;
        } while (truncated.length() > LONG_TEXT_MAX_LENGTH && contentLength > 0);
        return truncated;
    }

    //End - record helpers

    /**
     * SystemContext
     * Reads and moves child records without sharing, so every child is moved to
     * the survivor, not just the ones the running user can see. Otherwise hidden
     * children would be orphaned or cascade-deleted with the abandoned record.
     */
    private without sharing class SystemContext {

        public void countChildren(List<ReparentTarget> targets, Id recordIdA, Id recordIdB, ComparisonResult result) {
            Set<Id> recordIds = new Set<Id>{ recordIdA, recordIdB };

            for (ReparentTarget target : targets) {
                if (Limits.getQueries() >= Limits.getLimitQueries() - QUERY_HEADROOM) {
                    result.reparentSummaryIncomplete = true;
                    break;
                }

                Map<Id, Integer> countsByParent = new Map<Id, Integer>();
                try {
                    if (target.isGroupable) {
                        String query = String.format(
                            'SELECT {0} parentId, COUNT(Id) total FROM {1} WHERE {0} IN :recordIds GROUP BY {0}',
                            new List<Object>{ target.fieldApiName, target.childObjectApiName });
                        for (SObject aggregate : Database.queryWithBinds(query, new Map<String, Object>{ 'recordIds' => recordIds }, AccessLevel.SYSTEM_MODE)) {
                            countsByParent.put((Id) aggregate.get('parentId'), (Integer) aggregate.get('total'));
                        }
                    } else {
                        String query = String.format('SELECT {0} FROM {1} WHERE {0} IN :recordIds LIMIT 10000',
                            new List<Object>{ target.fieldApiName, target.childObjectApiName });
                        for (SObject child : Database.queryWithBinds(query, new Map<String, Object>{ 'recordIds' => recordIds }, AccessLevel.SYSTEM_MODE)) {
                            Id parentId = (Id) child.get(target.fieldApiName);
                            countsByParent.put(parentId, (countsByParent.containsKey(parentId) ? countsByParent.get(parentId) : 0) + 1);
                        }
                    }
                } catch (Exception e) {
                    //Only a preview - skip relationships that can't be counted
                    System.debug('Unable to count ' + target.childObjectApiName + '.' + target.fieldApiName + ': ' + e.getMessage());
                    continue;
                }

                Integer countA = countsByParent.containsKey(recordIdA) ? countsByParent.get(recordIdA) : 0;
                Integer countB = countsByParent.containsKey(recordIdB) ? countsByParent.get(recordIdB) : 0;
                if (countA + countB == 0) {
                    continue;
                }

                ReparentSummary summary = new ReparentSummary();
                summary.childObjectApiName = target.childObjectApiName;
                summary.childObjectLabel = target.childObjectLabel;
                summary.fieldApiName = target.fieldApiName;
                summary.fieldLabel = target.fieldLabel;
                summary.countA = countA;
                summary.countB = countB;
                result.reparentSummary.add(summary);
            }
        }

        /**
         * reparentChildren()
         * Point every child of the abandoned record at the survivor.
         * Returns ChildObject.Field -> list of re-parented record Ids (ContentDocument Ids for files).
         */
        public Map<String, List<Id>> reparentChildren(List<ReparentTarget> targets, Id survivorId, Id abandonedId) {
            Map<String, List<Id>> reparentedIds = new Map<String, List<Id>>();
            //A child can reference the abandoned record through more than one lookup,
            //so updates are collected per record to avoid duplicate Ids in one DML
            Map<Schema.SObjectType, Map<Id, SObject>> updatesByType = new Map<Schema.SObjectType, Map<Id, SObject>>();
            List<ContentDocumentLink> linksToInsert = new List<ContentDocumentLink>();

            for (ReparentTarget target : targets) {
                if (Limits.getQueries() >= Limits.getLimitQueries() - QUERY_HEADROOM) {
                    throw new RecordMergeException('This record has too many related objects to merge in one transaction (SOQL query limit).');
                }

                String key = target.childObjectApiName + '.' + target.fieldApiName;

                if (target.childObjectApiName == CONTENT_DOCUMENT_LINK) {
                    List<Id> documentIds = new List<Id>();
                    for (ContentDocumentLink link : buildContentDocumentLinks(survivorId, abandonedId)) {
                        linksToInsert.add(link);
                        documentIds.add(link.ContentDocumentId);
                    }
                    if (!documentIds.isEmpty()) {
                        reparentedIds.put(key, documentIds);
                    }
                    continue;
                }

                //Self lookups (e.g. Account.ParentId) must not point the survivor at itself
                String query = String.format('SELECT Id FROM {0} WHERE {1} = :abandonedId{2}', new List<Object>{
                    target.childObjectApiName,
                    target.fieldApiName,
                    target.isSelfRelationship ? ' AND Id != :survivorId' : ''
                });

                List<SObject> children;
                try {
                    children = Database.queryWithBinds(query,
                        new Map<String, Object>{ 'abandonedId' => abandonedId, 'survivorId' => survivorId },
                        AccessLevel.SYSTEM_MODE);
                } catch (Exception e) {
                    throw new RecordMergeException('Unable to read related ' + target.childObjectLabel + ': ' + e.getMessage());
                }
                if (children.isEmpty()) {
                    continue;
                }

                if (!updatesByType.containsKey(target.childType)) {
                    updatesByType.put(target.childType, new Map<Id, SObject>());
                }
                Map<Id, SObject> typeUpdates = updatesByType.get(target.childType);
                List<Id> childIds = new List<Id>();
                for (SObject child : children) {
                    SObject childUpdate = typeUpdates.get(child.Id);
                    if (childUpdate == null) {
                        childUpdate = target.childType.newSObject(child.Id);
                        typeUpdates.put(child.Id, childUpdate);
                    }
                    childUpdate.put(target.fieldApiName, survivorId);
                    childIds.add(child.Id);
                }
                reparentedIds.put(key, childIds);
            }

            //Fail with a clear message before any DML rather than partway through
            Integer rowCount = linksToInsert.size();
            for (Map<Id, SObject> typeUpdates : updatesByType.values()) {
                rowCount += typeUpdates.size();
            }
            //+2 leaves room for the log insert and the abandoned record delete
            if (Limits.getDmlRows() + rowCount + 2 > Limits.getLimitDmlRows()) {
                throw new RecordMergeException('This record has too many related records (' + rowCount + ') to merge in one transaction.');
            }

            for (Map<Id, SObject> typeUpdates : updatesByType.values()) {
                Database.update(typeUpdates.values(), AccessLevel.SYSTEM_MODE);
            }
            if (!linksToInsert.isEmpty()) {
                Database.insert(linksToInsert, AccessLevel.SYSTEM_MODE);
            }
            return reparentedIds;
        }

        //The abandoned record's own links are removed when it is deleted
        private List<ContentDocumentLink> buildContentDocumentLinks(Id survivorId, Id abandonedId) {
            Set<Id> alreadyLinked = new Set<Id>();
            for (ContentDocumentLink link : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :survivorId]) {
                alreadyLinked.add(link.ContentDocumentId);
            }

            List<ContentDocumentLink> newLinks = new List<ContentDocumentLink>();
            for (ContentDocumentLink link : [SELECT ContentDocumentId, ShareType, Visibility FROM ContentDocumentLink WHERE LinkedEntityId = :abandonedId]) {
                if (alreadyLinked.contains(link.ContentDocumentId)) {
                    continue;
                }
                newLinks.add(new ContentDocumentLink(
                    LinkedEntityId = survivorId,
                    ContentDocumentId = link.ContentDocumentId,
                    ShareType = link.ShareType,
                    Visibility = link.Visibility
                ));
            }
            return newLinks;
        }
    }

    public class ComparisonResult {
        public String objectApiName;
        public String objectLabel;
        public Id recordIdA;
        public Id recordIdB;
        public String nameA;
        public String nameB;
        public List<FieldComparison> fields = new List<FieldComparison>();
        public List<ReparentSummary> reparentSummary = new List<ReparentSummary>();
        //True when the SOQL limit was reached before every relationship was counted
        public Boolean reparentSummaryIncomplete = false;
    }

    public class FieldComparison {
        public String apiName;
        public String label;
        public String type;
        public Object valueA;
        public Object valueB;
        public String displayA;
        public String displayB;
        public Boolean isDifferent;
    }

    public class ReparentSummary {
        public String childObjectApiName;
        public String childObjectLabel;
        public String fieldApiName;
        public String fieldLabel;
        public Integer countA;
        public Integer countB;
    }

    public class MergeRequest {
        public Id survivorId;
        public Id abandonedId;
        //Field API name -> Id of the record (survivor or abandoned) to take the value from
        public Map<String, String> selections;
    }

    public class MergeResult {
        public Id logId;
        public Id survivorId;
        public Id abandonedId;
        public Integer reparentedCount;
    }

    @TestVisible
    private class ReparentTarget {
        public Schema.SObjectType childType;
        public String childObjectApiName;
        public String childObjectLabel;
        public String fieldApiName;
        public String fieldLabel;
        public Boolean isGroupable;
        public Boolean isSelfRelationship;
    }

    public class RecordMergeException extends Exception {}
}