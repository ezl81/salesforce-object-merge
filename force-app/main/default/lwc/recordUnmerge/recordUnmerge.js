import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getUnmergePreview from '@salesforce/apex/RecordMergeController.getUnmergePreview';
import unmergeRecords from '@salesforce/apex/RecordMergeController.unmergeRecords';
import { buildFieldRows, allSelections, reduceError } from 'c/recordMergeUtils';

//Unmerge comparisons (see RecordUnmergeService.UnmergePreview):
//restored fields - A = the deleted record's value at the merge, B = the survivor's current value
//survivor fields - A = the survivor's current value, B = its value before the merge
const SNAPSHOT = 'A';
const SURVIVOR_CURRENT = 'B';
const KEEP_CURRENT = 'A';
const BEFORE_MERGE = 'B';

const RESTORE_MODE_MESSAGES = {
    UNDELETE: (name) => `"${name}" will be restored from the recycle bin and keep its original Id.`,
    RECREATE: (name) =>
        `"${name}" is no longer in the recycle bin, so it will be recreated as a new record with a new Id. ` +
        'Its field history and anything that pointed to the old Id cannot be restored.',
    EXISTS: (name) => `"${name}" has already been restored. The values and related records you choose will be applied to it.`
};

/**
 * Unmerge screen for one Record_Merge_Log__c.
 * Fires "unmerged" (detail: RecordUnmergeService.UnmergeResult) when done and "cancel" when closed.
 */
export default class RecordUnmerge extends NavigationMixin(LightningElement) {
    //Record_Merge_Log__c Id of the merge to reverse
    @api logId;

    //RecordUnmergeService.UnmergePreview
    preview = null;

    //Field apiName -> SNAPSHOT | SURVIVOR_CURRENT
    restoreSelections = {};

    //Field apiName -> KEEP_CURRENT | BEFORE_MERGE
    survivorSelections = {};

    //Related group key -> Ids to move back
    relatedSelections = {};

    showOnlyDifferences = true;
    isLoading = false;
    errorMessage = null;

    connectedCallback() {
        this.loadPreview();
    }

    async loadPreview() {
        this.isLoading = true;
        this.errorMessage = null;
        try {
            const preview = JSON.parse(await getUnmergePreview({ logId: this.logId }));
            this.applyDefaults(preview);
            this.preview = preview;
        } catch (error) {
            this.preview = null;
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }

    //Restored record: its own values from the merge. Survivor: put back what the merge
    //changed, unless the field was edited again after the merge. Related: move everything back.
    applyDefaults(preview) {
        this.restoreSelections = allSelections(preview.restoredFields, SNAPSHOT);

        const changedSinceMerge = new Set(preview.survivorFieldsChangedSinceMerge);
        const survivorSelections = {};
        preview.survivorFields.forEach((field) => {
            survivorSelections[field.apiName] = changedSinceMerge.has(field.apiName) ? KEEP_CURRENT : BEFORE_MERGE;
        });
        this.survivorSelections = survivorSelections;

        this.relatedSelections = this.allRelatedSelections(preview, true);
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    handleShowOnlyDifferences(event) {
        this.showOnlyDifferences = event.target.checked;
    }

    //Start - header

    get restoredName() {
        return this.preview?.abandonedName ?? '';
    }

    get survivorName() {
        return this.preview?.survivorName ?? '';
    }

    get title() {
        return `Unmerge "${this.restoredName}" from "${this.survivorName}"`;
    }

    get restoreModeMessage() {
        const message = RESTORE_MODE_MESSAGES[this.preview?.restoreMode];
        return message ? message(this.restoredName) : '';
    }

    get isRecreate() {
        return this.preview?.restoreMode === 'RECREATE';
    }

    get restoreModeClass() {
        return this.isRecreate
            ? 'slds-notify slds-notify_alert slds-alert_warning slds-var-m-top_small'
            : 'slds-box slds-box_x-small slds-theme_info slds-var-m-top_small';
    }

    get differenceCountLabel() {
        if (!this.preview) {
            return '';
        }
        const count = [...this.preview.restoredFields, ...this.preview.survivorFields].filter((field) => field.isDifferent).length;
        return `Show only differences (${count})`;
    }

    //End - header

    //Start - values for the restored record

    get restoreRows() {
        if (!this.preview) {
            return [];
        }
        return buildFieldRows(this.preview.restoredFields, this.restoreSelections, SNAPSHOT, SURVIVOR_CURRENT,
            'restore', this.showOnlyDifferences);
    }

    get hasRestoreRows() {
        return this.restoreRows.length > 0;
    }

    get restoreSnapshotHeader() {
        return `${this.restoredName} when merged`;
    }

    get restoreSurvivorHeader() {
        return `Current on ${this.survivorName}`;
    }

    handleRestoreValueSelect(event) {
        const { field, side } = event.detail;
        this.restoreSelections = { ...this.restoreSelections, [field]: side };
    }

    handleRestoreUseAllSnapshot() {
        this.restoreSelections = allSelections(this.preview.restoredFields, SNAPSHOT);
    }

    handleRestoreUseAllSurvivor() {
        this.restoreSelections = allSelections(this.preview.restoredFields, SURVIVOR_CURRENT);
    }

    //End - values for the restored record

    //Start - values the merge changed on the survivor

    get survivorRows() {
        if (!this.preview) {
            return [];
        }
        return buildFieldRows(this.preview.survivorFields, this.survivorSelections, KEEP_CURRENT, BEFORE_MERGE,
            'survivor', this.showOnlyDifferences);
    }

    get hasSurvivorFields() {
        return !!this.preview && this.preview.survivorFields.length > 0;
    }

    get hasSurvivorRows() {
        return this.survivorRows.length > 0;
    }

    get hasChangedSinceMerge() {
        return !!this.preview && this.preview.survivorFieldsChangedSinceMerge.length > 0;
    }

    handleSurvivorValueSelect(event) {
        const { field, side } = event.detail;
        this.survivorSelections = { ...this.survivorSelections, [field]: side };
    }

    handleSurvivorRevertAll() {
        this.survivorSelections = allSelections(this.preview.survivorFields, BEFORE_MERGE);
    }

    handleSurvivorKeepAll() {
        this.survivorSelections = allSelections(this.preview.survivorFields, KEEP_CURRENT);
    }

    //End - values the merge changed on the survivor

    //Start - related records

    get relatedGroups() {
        if (!this.preview) {
            return [];
        }
        return this.preview.relatedGroups.map((relatedGroup) => {
            const value = this.relatedSelections[relatedGroup.key] || [];
            return {
                key: relatedGroup.key,
                label: `${relatedGroup.label}: ${value.length} of ${relatedGroup.records.length} selected`,
                options: relatedGroup.records.map((record) => ({ label: record.name, value: record.id })),
                value
            };
        });
    }

    get hasRelatedGroups() {
        return this.relatedGroups.length > 0;
    }

    get selectedRelatedIds() {
        return Object.values(this.relatedSelections).flat();
    }

    allRelatedSelections(preview, selectAll) {
        const selections = {};
        preview.relatedGroups.forEach((relatedGroup) => {
            selections[relatedGroup.key] = selectAll ? relatedGroup.records.map((record) => record.id) : [];
        });
        return selections;
    }

    handleRelatedChange(event) {
        const { key } = event.target.dataset;
        this.relatedSelections = { ...this.relatedSelections, [key]: event.detail.value };
    }

    handleRelatedSelectAll() {
        this.relatedSelections = this.allRelatedSelections(this.preview, true);
    }

    handleRelatedSelectNone() {
        this.relatedSelections = this.allRelatedSelections(this.preview, false);
    }

    //End - related records

    //Start - unmerge

    async handleUnmerge() {
        const relatedIds = this.selectedRelatedIds;
        const restoreMessage = this.isRecreate ? `"${this.restoredName}" will be recreated with a new Id. ` : '';
        const confirmed = await LightningConfirm.open({
            label: 'Confirm Unmerge',
            theme: 'warning',
            message: `${restoreMessage}"${this.restoredName}" will be restored with the selected values, and ` +
                `${relatedIds.length} related record(s) will be moved back to it from "${this.survivorName}". Continue?`
        });
        if (!confirmed) {
            return;
        }

        const request = {
            logId: this.preview.logId,
            restoredFromSurvivor: Object.keys(this.restoreSelections)
                .filter((apiName) => this.restoreSelections[apiName] === SURVIVOR_CURRENT),
            survivorFieldsToRevert: Object.keys(this.survivorSelections)
                .filter((apiName) => this.survivorSelections[apiName] === BEFORE_MERGE),
            relatedRecordIds: relatedIds
        };

        this.isLoading = true;
        this.errorMessage = null;
        try {
            const result = JSON.parse(await unmergeRecords({ request: JSON.stringify(request) }));
            await this.showUnmergeToast(result);
            this.dispatchEvent(new CustomEvent('unmerged', { detail: result }));
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async showUnmergeToast(result) {
        const url = await this[NavigationMixin.GenerateUrl]({
            type: 'standard__recordPage',
            attributes: {
                recordId: result.restoredId,
                actionName: 'view'
            }
        });
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Records unmerged',
                message: '{0} was restored and ' + result.movedCount + ' related record(s) were moved back to it.',
                messageData: [{ url, label: result.restoredName || 'The record' }],
                variant: 'success'
            })
        );
    }

    //End - unmerge

    handleError(err) {
        this.errorMessage = reduceError(err);
        console.log('Error = ' + JSON.stringify(err));
    }
}
