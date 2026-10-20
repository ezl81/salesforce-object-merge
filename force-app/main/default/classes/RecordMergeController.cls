/**
 * @description       : Backs the recordMerge LWC. All of the merge logic lives in RecordMergeService.
 * @author            : Brian Ezell (Simply EZ)
 * @group             :
 * @last modified on  : 09-24-2026
 * @last modified by  : Brian Ezell (Simply EZ)
**/
public with sharing class RecordMergeController {

    /**
     * getComparison()
     * Returns a serialized RecordMergeService.ComparisonResult comparing the two records.
     */
    @AuraEnabled
    public static String getComparison(Id recordIdA, Id recordIdB) {
        try {
            System.debug('***STARTING RecordMergeController.getComparison***');
            return JSON.serialize(RecordMergeService.getComparison(recordIdA, recordIdB));
        } catch (Exception e) {
            throw buildAuraException(e);
        }
    }

    /**
     * mergeRecords()
     * @param request Serialized RecordMergeService.MergeRequest:
     *   { "survivorId": "...", "abandonedId": "...", "selections": { "Phone": "<abandonedId>" } }
     * @return Serialized RecordMergeService.MergeResult
     */
    @AuraEnabled
    public static String mergeRecords(String request) {
        try {
            System.debug('***STARTING RecordMergeController.mergeRecords***');
            System.debug('Request = ' + request);
            RecordMergeService.MergeRequest mergeRequest =
                (RecordMergeService.MergeRequest) JSON.deserialize(request, RecordMergeService.MergeRequest.class);
            return JSON.serialize(RecordMergeService.mergeRecords(mergeRequest));
        } catch (Exception e) {
            throw buildAuraException(e);
        }
    }

    /**
     * getUnmergeOptions()
     * @return Serialized List<RecordUnmergeService.UnmergeOption>: merges into this record that can be unmerged
     */
    @AuraEnabled
    public static String getUnmergeOptions(Id recordId) {
        try {
            System.debug('***STARTING RecordMergeController.getUnmergeOptions***');
            return JSON.serialize(RecordUnmergeService.getUnmergeOptions(recordId));
        } catch (Exception e) {
            throw buildAuraException(e);
        }
    }

    /**
     * getUnmergePreview()
     * @return Serialized RecordUnmergeService.UnmergePreview for the merge recorded by logId
     */
    @AuraEnabled
    public static String getUnmergePreview(Id logId) {
        try {
            System.debug('***STARTING RecordMergeController.getUnmergePreview***');
            return JSON.serialize(RecordUnmergeService.getUnmergePreview(logId));
        } catch (Exception e) {
            throw buildAuraException(e);
        }
    }

    /**
     * unmergeRecords()
     * @param request Serialized RecordUnmergeService.UnmergeRequest:
     *   { "logId": "...", "restoredFromSurvivor": ["Website"], "survivorFieldsToRevert": ["Phone"], "relatedRecordIds": ["003..."] }
     * @return Serialized RecordUnmergeService.UnmergeResult
     */
    @AuraEnabled
    public static String unmergeRecords(String request) {
        try {
            System.debug('***STARTING RecordMergeController.unmergeRecords***');
            System.debug('Request = ' + request);
            RecordUnmergeService.UnmergeRequest unmergeRequest =
                (RecordUnmergeService.UnmergeRequest) JSON.deserialize(request, RecordUnmergeService.UnmergeRequest.class);
            return JSON.serialize(RecordUnmergeService.unmergeRecords(unmergeRequest));
        } catch (Exception e) {
            throw buildAuraException(e);
        }
    }

    /**
     * getMergeHistory()
     * @param request Serialized RecordUnmergeService.HistoryRequest (all optional):
     *   { "objectApiName": "Account", "status": "available", "searchText": "Acme", "offsetSize": 0 }
     * @return Serialized RecordUnmergeService.HistoryResult
     */
    @AuraEnabled
    public static String getMergeHistory(String request) {
        try {
            System.debug('***STARTING RecordMergeController.getMergeHistory***');
            RecordUnmergeService.HistoryRequest historyRequest = String.isBlank(request)
                ? new RecordUnmergeService.HistoryRequest()
                : (RecordUnmergeService.HistoryRequest) JSON.deserialize(request, RecordUnmergeService.HistoryRequest.class);
            return JSON.serialize(RecordUnmergeService.getMergeHistory(historyRequest));
        } catch (Exception e) {
            throw buildAuraException(e);
        }
    }

    private static AuraHandledException buildAuraException(Exception e) {
        System.debug('***EXCEPTION***');
        System.debug(e.getMessage());
        System.debug(e.getStackTraceString());
        AuraHandledException auraException = new AuraHandledException(e.getMessage());
        //setMessage so the real message is visible to tests and not just "Script-thrown exception"
        auraException.setMessage(e.getMessage());
        return auraException;
    }
}