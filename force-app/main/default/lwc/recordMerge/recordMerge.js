import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import getComparison from '@salesforce/apex/RecordMergeController.getComparison';
import mergeRecords from '@salesforce/apex/RecordMergeController.mergeRecords';

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

    showOnlyDifferences = true;
    isLoading = false;
    errorMessage = null;

    get title() {
        return this.cardTitle || 'Merge Records';
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
            const masterBlank = this.isBlank(this.valueForSide(field, this.masterSide));
            const otherBlank = this.isBlank(this.valueForSide(field, this.otherSide));
            selections[field.apiName] = masterBlank && !otherBlank ? this.otherSide : this.masterSide;
        });
        this.selections = selections;
    }

    valueForSide(field, side) {
        return side === 'A' ? field.valueA : field.valueB;
    }

    displayForSide(field, side) {
        return side === 'A' ? field.displayA : field.displayB;
    }

    isBlank(value) {
        return value === null || value === undefined || value === '';
    }

    //End - master record

    //Start - field comparison

    get rows() {
        if (!this.comparison) {
            return [];
        }
        const masterSide = this.masterSide;
        const otherSide = this.otherSide;
        return this.comparison.fields
            .filter((field) => !this.showOnlyDifferences || field.isDifferent)
            .map((field) => {
                const selected = this.selections[field.apiName];
                const masterDisplay = this.displayForSide(field, masterSide);
                const otherDisplay = this.displayForSide(field, otherSide);
                return {
                    key: field.apiName,
                    label: field.label,
                    radioName: `merge-${field.apiName}`,
                    rowClass: field.isDifferent ? 'slds-hint-parent merge-row_different' : 'slds-hint-parent',
                    master: {
                        inputId: `${field.apiName}-master`,
                        side: masterSide,
                        checked: selected === masterSide,
                        display: masterDisplay || '(blank)',
                        displayClass: masterDisplay ? 'merge-value' : 'merge-value merge-value_blank'
                    },
                    other: {
                        inputId: `${field.apiName}-other`,
                        side: otherSide,
                        checked: selected === otherSide,
                        display: otherDisplay || '(blank)',
                        displayClass: otherDisplay ? 'merge-value' : 'merge-value merge-value_blank'
                    }
                };
            });
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get differenceCountLabel() {
        const count = this.comparison ? this.comparison.fields.filter((field) => field.isDifferent).length : 0;
        return `Show only differences (${count})`;
    }

    handleValueSelect(event) {
        const { field, side } = event.target.dataset;
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
        const selections = {};
        this.comparison.fields.forEach((field) => {
            selections[field.apiName] = side;
        });
        this.selections = selections;
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
                    message: `"${this.otherName}" was merged into "${this.masterName}".`,
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