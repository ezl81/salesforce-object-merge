import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import getComparison from '@salesforce/apex/RecordMergeController.getComparison';
import mergeRecords from '@salesforce/apex/RecordMergeController.mergeRecords';
import getUnmergeOptions from '@salesforce/apex/RecordMergeController.getUnmergeOptions';
import { buildFieldRows, allSelections, isBlank, reduceError } from 'c/recordMergeUtils';

//The master picker values. Side 'A' is always the record page's record,
//side 'B' the record chosen in the picker.
const CURRENT = 'current';
const OTHER = 'other';

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

    //Record_Merge_Log__c Id shown in c-record-unmerge, otherwise null
    unmergeLogId = null;

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
        return !!this.unmergeLogId;
    }

    get isMergeMode() {
        return !this.unmergeLogId;
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
        this.selections = allSelections(this.comparison.fields, this.masterSide);
    }

    handleUseAllOther() {
        this.selections = allSelections(this.comparison.fields, this.otherSide);
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

    //Start - unmerge

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
            buttonTitle: `Unmerge ${option.abandonedName || option.abandonedId}`
        }));
    }

    handleUnmergeStart(event) {
        this.errorMessage = null;
        this.resetState();
        this.unmergeLogId = event.currentTarget.dataset.logId;
    }

    handleUnmergeCancel() {
        this.unmergeLogId = null;
    }

    async handleUnmerged() {
        this.unmergeLogId = null;
        await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        await this.loadUnmergeOptions();
    }

    //End - unmerge

    handleError(err) {
        this.errorMessage = reduceError(err);
        console.log('Error = ' + JSON.stringify(err));
    }
}
