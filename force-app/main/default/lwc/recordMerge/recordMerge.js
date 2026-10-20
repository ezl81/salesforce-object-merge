import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import getComparison from '@salesforce/apex/RecordMergeController.getComparison';
import mergeRecords from '@salesforce/apex/RecordMergeController.mergeRecords';
import getUnmergeOptions from '@salesforce/apex/RecordMergeController.getUnmergeOptions';
import getUnmergePreview from '@salesforce/apex/RecordMergeController.getUnmergePreview';
import unmergeRecords from '@salesforce/apex/RecordMergeController.unmergeRecords';

//The master picker values. Side 'A' is always the record page's record,
//side 'B' the record chosen in the picker.
const CURRENT = 'current';
const OTHER = 'other';

//Unmerge comparisons (see RecordUnmergeService.UnmergePreview):
//restored fields - A = the deleted record's value at the merge, B = this record's current value
//survivor fields - A = this record's current value, B = its value before the merge
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

function isBlank(value) {
    return value === null || value === undefined || value === '';
}

/**
 * Rows for c-record-merge-field-table: one radio for the left side and one for
 * the right side of each field. Sides are 'A' or 'B' (valueA/displayA or valueB/displayB).
 */
function buildFieldRows(fields, selections, leftSide, rightSide, groupName, onlyDifferences) {
    return fields
        .filter((field) => !onlyDifferences || field.isDifferent)
        .map((field) => {
            const selected = selections[field.apiName];
            return {
                key: field.apiName,
                label: field.label,
                radioName: `${groupName}-${field.apiName}`,
                rowClass: field.isDifferent ? 'slds-hint-parent merge-row_different' : 'slds-hint-parent',
                left: buildFieldCell(field, leftSide, selected, `${groupName}-${field.apiName}-left`),
                right: buildFieldCell(field, rightSide, selected, `${groupName}-${field.apiName}-right`)
            };
        });
}

function buildFieldCell(field, side, selected, inputId) {
    const display = side === 'A' ? field.displayA : field.displayB;
    return {
        inputId,
        side,
        checked: selected === side,
        display: display || '(blank)',
        displayClass: display ? 'merge-value' : 'merge-value merge-value_blank'
    };
}

export default class RecordMerge extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;
    @api cardTitle;

    //Id picked in the record picker
    selectedRecordId = null;

    //RecordMergeService.ComparisonResult from Apex
    comparison = null;

    //Which record survives: CURRENT or OTHER
    masterKey = CURRENT;

    //Field apiName -> 'A' | 'B' (the side the value is taken from)
    selections = {};

    //RecordUnmergeService.UnmergeOption[] - merges into this record that can be unmerged
    unmergeOptions = [];

    //RecordUnmergeService.UnmergePreview while unmerging, otherwise null
    unmergePreview = null;

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
        this.loadUnmergeOptions();
    }

    get title() {
        return this.cardTitle || 'Merge Records';
    }

    get isUnmergeMode() {
        return !!this.unmergePreview;
    }

    get isMergeMode() {
        return !this.unmergePreview;
    }

    //Start - record picker

    get pickerFilter() {
        return {
            criteria: [{ fieldPath: 'Id', operator: 'ne', value: this.recordId }]
        };
    }

    handleRecordSelect(event) {
        this.selectedRecordId = event.detail.recordId;
        this.errorMessage = null;
        if (!this.selectedRecordId) {
            this.comparison = null;
            return;
        }
        this.loadComparison();
    }

    async loadComparison() {
        this.isLoading = true;
        try {
            const response = await getComparison({ recordIdA: this.recordId, recordIdB: this.selectedRecordId });
            this.comparison = JSON.parse(response);
            this.masterKey = CURRENT;
            this.applyDefaultSelections();
        } catch (error) {
            this.comparison = null;
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }

    //End - record picker

    //Start - master record

    get masterSide() {
        return this.masterKey === CURRENT ? 'A' : 'B';
    }

    get otherSide() {
        return this.masterKey === CURRENT ? 'B' : 'A';
    }

    get masterName() {
        return this.nameForSide(this.masterSide);
    }

    get otherName() {
        return this.nameForSide(this.otherSide);
    }

    get masterHeader() {
        return `Master: ${this.masterName}`;
    }

    get otherHeader() {
        return `Will be deleted: ${this.otherName}`;
    }

    nameForSide(side) {
        if (!this.comparison) {
            return '';
        }
        return side === 'A' ? this.comparison.nameA : this.comparison.nameB;
    }

    idForSide(side) {
        return side === 'A' ? this.recordId : this.selectedRecordId;
    }

    get masterOptions() {
        if (!this.comparison) {
            return [];
        }
        return [
            { label: `This record (${this.comparison.nameA})`, value: CURRENT },
            { label: `Selected record (${this.comparison.nameB})`, value: OTHER }
        ];
    }

    handleMasterChange(event) {
        this.masterKey = event.detail.value;
        this.applyDefaultSelections();
    }

    //Keep the master's value, unless the master's value is blank and the other record has one.
    applyDefaultSelections() {
        const selections = {};
        this.comparison.fields.forEach((field) => {
            const masterBlank = isBlank(this.valueForSide(field, this.masterSide));
            const otherBlank = isBlank(this.valueForSide(field, this.otherSide));
            selections[field.apiName] = masterBlank && !otherBlank ? this.otherSide : this.masterSide;
        });
        this.selections = selections;
    }

    valueForSide(field, side) {
        return side === 'A' ? field.valueA : field.valueB;
    }

    //End - master record

    //Start - field comparison

    get rows() {
        if (!this.comparison) {
            return [];
        }
        return buildFieldRows(this.comparison.fields, this.selections, this.masterSide, this.otherSide, 'merge', this.showOnlyDifferences);
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get differenceCountLabel() {
        const count = this.comparison ? this.comparison.fields.filter((field) => field.isDifferent).length : 0;
        return `Show only differences (${count})`;
    }

    handleValueSelect(event) {
        const { field, side } = event.detail;
        this.selections = { ...this.selections, [field]: side };
    }

    handleShowOnlyDifferences(event) {
        this.showOnlyDifferences = event.target.checked;
    }

    handleUseAllMaster() {
        this.setAllSelections(this.masterSide);
    }

    handleUseAllOther() {
        this.setAllSelections(this.otherSide);
    }

    setAllSelections(side) {
        this.selections = this.allSelections(this.comparison.fields, side);
    }

    allSelections(fields, side) {
        const selections = {};
        fields.forEach((field) => {
            selections[field.apiName] = side;
        });
        return selections;
    }

    //End - field comparison

    //Start - related records

    //Child records on the abandoned record, which will all be moved to the master
    get relatedToMove() {
        if (!this.comparison) {
            return [];
        }
        const countKey = this.otherSide === 'A' ? 'countA' : 'countB';
        return this.comparison.reparentSummary
            .filter((summary) => summary[countKey] > 0)
            .map((summary) => ({
                key: `${summary.childObjectApiName}.${summary.fieldApiName}`,
                label: `${summary.childObjectLabel} (${summary.fieldLabel})`,
                count: summary[countKey]
            }));
    }

    get hasRelatedToMove() {
        return this.relatedToMove.length > 0;
    }

    get relatedTotal() {
        return this.relatedToMove.reduce((total, item) => total + item.count, 0);
    }

    get isSummaryIncomplete() {
        return !!this.comparison?.reparentSummaryIncomplete;
    }

    //End - related records

    //Start - merge

    async handleMerge() {
        const confirmed = await LightningConfirm.open({
            label: 'Confirm Merge',
            theme: 'warning',
            message: `"${this.otherName}" will be merged into "${this.masterName}" and then deleted. ` +
                `The selected values and ${this.relatedTotal} related record(s) will be moved to "${this.masterName}". Continue?`
        });
        if (!confirmed) {
            return;
        }

        const survivorId = this.idForSide(this.masterSide);
        const abandonedId = this.idForSide(this.otherSide);

        //Only values taken from the abandoned record need to be sent
        const selections = {};
        Object.keys(this.selections).forEach((apiName) => {
            if (this.selections[apiName] === this.otherSide) {
                selections[apiName] = abandonedId;
            }
        });

        this.isLoading = true;
        this.errorMessage = null;
        try {
            await mergeRecords({ request: JSON.stringify({ survivorId, abandonedId, selections }) });

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Records merged',
                    message: `"${this.otherName}" was merged into "${this.masterName}". It can be unmerged from "${this.masterName}".`,
                    variant: 'success'
                })
            );

            if (abandonedId === this.recordId) {
                //This page's record no longer exists, so go to the survivor
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId: survivorId,
                        actionName: 'view'
                    }
                });
            } else {
                await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
                this.resetState();
                await this.loadUnmergeOptions();
            }
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }

    resetState() {
        this.selectedRecordId = null;
        this.comparison = null;
        this.selections = {};
        this.masterKey = CURRENT;
    }

    //End - merge

    //Start - unmerge options

    async loadUnmergeOptions() {
        if (!this.recordId) {
            return;
        }
        try {
            this.unmergeOptions = JSON.parse(await getUnmergeOptions({ recordId: this.recordId }));
        } catch (error) {
            this.unmergeOptions = [];
            this.handleError(error);
        }
    }

    get hasUnmergeOptions() {
        return this.unmergeOptions.length > 0;
    }

    get unmergeOptionRows() {
        return this.unmergeOptions.map((option) => ({
            key: option.logId,
            logId: option.logId,
            name: option.abandonedName || option.abandonedId,
            mergedOn: option.mergedOn,
            mergedByName: option.mergedByName,
            buttonLabel: 'Unmerge',
            buttonTitle: `Unmerge ${option.abandonedName || option.abandonedId}`
        }));
    }

    async handleUnmergeStart(event) {
        const { logId } = event.currentTarget.dataset;
        this.isLoading = true;
        this.errorMessage = null;
        try {
            const preview = JSON.parse(await getUnmergePreview({ logId }));
            this.applyUnmergeDefaults(preview);
            this.unmergePreview = preview;
            this.resetState();
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }

    //Restored record: its own values from the merge. This record: put back what the merge
    //changed, unless the field was edited again after the merge. Related: move everything back.
    applyUnmergeDefaults(preview) {
        this.restoreSelections = this.allSelections(preview.restoredFields, SNAPSHOT);

        const changedSinceMerge = new Set(preview.survivorFieldsChangedSinceMerge);
        const survivorSelections = {};
        preview.survivorFields.forEach((field) => {
            survivorSelections[field.apiName] = changedSinceMerge.has(field.apiName) ? KEEP_CURRENT : BEFORE_MERGE;
        });
        this.survivorSelections = survivorSelections;

        this.relatedSelections = this.allRelatedSelections(preview, true);
    }

    handleUnmergeCancel() {
        this.unmergePreview = null;
        this.restoreSelections = {};
        this.survivorSelections = {};
        this.relatedSelections = {};
        this.errorMessage = null;
    }

    //End - unmerge options

    //Start - unmerge values

    get restoredName() {
        return this.unmergePreview?.abandonedName ?? '';
    }

    get survivorName() {
        return this.unmergePreview?.survivorName ?? '';
    }

    get unmergeTitle() {
        return `Unmerge "${this.restoredName}" from "${this.survivorName}"`;
    }

    get restoreModeMessage() {
        const message = RESTORE_MODE_MESSAGES[this.unmergePreview?.restoreMode];
        return message ? message(this.restoredName) : '';
    }

    get isRecreate() {
        return this.unmergePreview?.restoreMode === 'RECREATE';
    }

    get restoreModeClass() {
        return this.isRecreate
            ? 'slds-notify slds-notify_alert slds-alert_warning slds-var-m-top_small'
            : 'slds-box slds-box_x-small slds-theme_info slds-var-m-top_small';
    }

    get unmergeDifferenceCountLabel() {
        if (!this.unmergePreview) {
            return '';
        }
        const count = [...this.unmergePreview.restoredFields, ...this.unmergePreview.survivorFields]
            .filter((field) => field.isDifferent).length;
        return `Show only differences (${count})`;
    }

    get restoreRows() {
        if (!this.unmergePreview) {
            return [];
        }
        return buildFieldRows(this.unmergePreview.restoredFields, this.restoreSelections, SNAPSHOT, SURVIVOR_CURRENT,
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

    get survivorRows() {
        if (!this.unmergePreview) {
            return [];
        }
        return buildFieldRows(this.unmergePreview.survivorFields, this.survivorSelections, KEEP_CURRENT, BEFORE_MERGE,
            'survivor', this.showOnlyDifferences);
    }

    get hasSurvivorFields() {
        return !!this.unmergePreview && this.unmergePreview.survivorFields.length > 0;
    }

    get hasSurvivorRows() {
        return this.survivorRows.length > 0;
    }

    get survivorCurrentHeader() {
        return 'Keep current value';
    }

    get survivorBeforeHeader() {
        return 'Value before the merge';
    }

    get hasChangedSinceMerge() {
        return !!this.unmergePreview && this.unmergePreview.survivorFieldsChangedSinceMerge.length > 0;
    }

    handleRestoreValueSelect(event) {
        const { field, side } = event.detail;
        this.restoreSelections = { ...this.restoreSelections, [field]: side };
    }

    handleRestoreUseAllSnapshot() {
        this.restoreSelections = this.allSelections(this.unmergePreview.restoredFields, SNAPSHOT);
    }

    handleRestoreUseAllSurvivor() {
        this.restoreSelections = this.allSelections(this.unmergePreview.restoredFields, SURVIVOR_CURRENT);
    }

    handleSurvivorValueSelect(event) {
        const { field, side } = event.detail;
        this.survivorSelections = { ...this.survivorSelections, [field]: side };
    }

    handleSurvivorRevertAll() {
        this.survivorSelections = this.allSelections(this.unmergePreview.survivorFields, BEFORE_MERGE);
    }

    handleSurvivorKeepAll() {
        this.survivorSelections = this.allSelections(this.unmergePreview.survivorFields, KEEP_CURRENT);
    }

    //End - unmerge values

    //Start - unmerge related records

    get relatedGroups() {
        if (!this.unmergePreview) {
            return [];
        }
        return this.unmergePreview.relatedGroups.map((relatedGroup) => {
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
        this.relatedSelections = this.allRelatedSelections(this.unmergePreview, true);
    }

    handleRelatedSelectNone() {
        this.relatedSelections = this.allRelatedSelections(this.unmergePreview, false);
    }

    //End - unmerge related records

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
            logId: this.unmergePreview.logId,
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
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.handleUnmergeCancel();
            await this.loadUnmergeOptions();
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
        this.errorMessage = this.reduceError(err);
        console.log('Error = ' + JSON.stringify(err));
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        } else if (error?.body?.message) {
            return error.body.message;
        }
        return error?.message ?? 'Unknown error';
    }
}
