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