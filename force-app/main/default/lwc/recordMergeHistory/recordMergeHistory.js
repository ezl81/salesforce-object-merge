import { LightningElement, api } from 'lwc';
import getMergeHistory from '@salesforce/apex/RecordMergeController.getMergeHistory';
import { reduceError } from 'c/recordMergeUtils';

//RecordUnmergeService status filters
const STATUS_OPTIONS = [
    { label: 'Can be unmerged', value: 'available' },
    { label: 'Unmerged', value: 'unmerged' },
    { label: 'All merges', value: 'all' }
];

const ALL_OBJECTS = '';
const SEARCH_DELAY_MS = 400;

const COLUMNS = [
    { label: 'Deleted Record', fieldName: 'abandonedName', wrapText: true },
    { label: 'Object', fieldName: 'objectLabel', initialWidth: 130 },
    {
        label: 'Merged Into',
        fieldName: 'survivorUrl',
        type: 'url',
        wrapText: true,
        typeAttributes: { label: { fieldName: 'survivorName' }, target: '_self' }
    },
    {
        label: 'Merged On',
        fieldName: 'mergedOn',
        type: 'date',
        initialWidth: 170,
        typeAttributes: { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }
    },
    { label: 'Merged By', fieldName: 'mergedByName', initialWidth: 150 },
    {
        label: 'Status',
        fieldName: 'status',
        initialWidth: 190,
        cellAttributes: { iconName: { fieldName: 'statusIcon' }, iconPosition: 'left' }
    },
    {
        label: 'Restored Record',
        fieldName: 'restoredUrl',
        type: 'url',
        wrapText: true,
        typeAttributes: { label: { fieldName: 'restoredLabel' }, target: '_self' }
    },
    {
        label: 'Merge Log',
        fieldName: 'logUrl',
        type: 'url',
        initialWidth: 130,
        typeAttributes: { label: { fieldName: 'logName' }, target: '_self' }
    },
    {
        type: 'button',
        initialWidth: 120,
        typeAttributes: {
            label: 'Unmerge',
            name: 'unmerge',
            iconName: 'utility:undo',
            variant: 'brand-outline',
            disabled: { fieldName: 'unmergeDisabled' }
        }
    }
];

const STATUS_ICONS = {
    'Can unmerge': 'utility:undo',
    Unmerged: 'utility:success'
};

function recordUrl(recordId) {
    return recordId ? `/lightning/r/${recordId}/view` : null;
}

/**
 * Every merge done with Record Merge (Record_Merge_Log__c), newest first.
 * Unmerge opens c-record-unmerge for the merge, so a deleted record can be
 * brought back without going through the recycle bin.
 */
export default class RecordMergeHistory extends LightningElement {
    @api cardTitle;

    columns = COLUMNS;
    statusOptions = STATUS_OPTIONS;

    //Filters
    objectApiName = ALL_OBJECTS;
    status = 'available';
    searchText = '';

    //RecordUnmergeService.HistoryRow[] with display fields added
    rows = [];
    objectOptions = [];
    hasMore = false;
    nextOffset = 0;

    //Record_Merge_Log__c Id shown in c-record-unmerge, otherwise null
    unmergeLogId = null;

    isLoading = false;
    errorMessage = null;
    searchTimeout;

    connectedCallback() {
        this.loadHistory(true);
    }

    disconnectedCallback() {
        clearTimeout(this.searchTimeout);
    }

    get title() {
        return this.cardTitle || 'Merge History';
    }

    get isListMode() {
        return !this.unmergeLogId;
    }

    get isUnmergeMode() {
        return !!this.unmergeLogId;
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get objectFilterOptions() {
        return [{ label: 'All objects', value: ALL_OBJECTS }, ...this.objectOptions];
    }

    get countLabel() {
        const count = `${this.rows.length}${this.hasMore ? '+' : ''}`;
        return `${count} merge${this.rows.length === 1 && !this.hasMore ? '' : 's'}`;
    }

    //Start - loading

    async loadHistory(reset) {
        const offsetSize = reset ? 0 : this.nextOffset;
        this.isLoading = true;
        this.errorMessage = null;
        try {
            const result = JSON.parse(
                await getMergeHistory({
                    request: JSON.stringify({
                        objectApiName: this.objectApiName || null,
                        status: this.status,
                        searchText: this.searchText || null,
                        offsetSize
                    })
                })
            );
            const rows = result.rows.map((row) => this.toDisplayRow(row));
            this.rows = reset ? rows : [...this.rows, ...rows];
            this.hasMore = result.hasMore;
            this.nextOffset = result.nextOffset;
            if (result.objectOptions) {
                this.objectOptions = result.objectOptions
                    .map((option) => ({ label: option.label, value: option.value }))
                    .sort((a, b) => a.label.localeCompare(b.label));
            }
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }

    toDisplayRow(row) {
        return {
            ...row,
            survivorUrl: recordUrl(row.survivorId),
            restoredUrl: recordUrl(row.restoredId),
            restoredLabel: row.restoredName || row.restoredId,
            logUrl: recordUrl(row.logId),
            statusIcon: STATUS_ICONS[row.status] || 'utility:warning',
            unmergeDisabled: !row.canUnmerge
        };
    }

    handleLoadMore() {
        this.loadHistory(false);
    }

    handleRefresh() {
        this.loadHistory(true);
    }

    //End - loading

    //Start - filters

    handleObjectChange(event) {
        this.objectApiName = event.detail.value;
        this.loadHistory(true);
    }

    handleStatusChange(event) {
        this.status = event.detail.value;
        this.loadHistory(true);
    }

    handleSearchChange(event) {
        this.searchText = event.detail.value;
        clearTimeout(this.searchTimeout);
        //eslint-disable-next-line @lwc/lwc/no-async-operation
        this.searchTimeout = setTimeout(() => this.loadHistory(true), SEARCH_DELAY_MS);
    }

    //End - filters

    //Start - unmerge

    handleRowAction(event) {
        const { action, row } = event.detail;
        if (action.name === 'unmerge' && row.canUnmerge) {
            this.errorMessage = null;
            this.unmergeLogId = row.logId;
        }
    }

    handleUnmergeCancel() {
        this.unmergeLogId = null;
    }

    handleUnmerged() {
        this.unmergeLogId = null;
        this.loadHistory(true);
    }

    //End - unmerge

    handleError(err) {
        this.errorMessage = reduceError(err);
        console.log('Error = ' + JSON.stringify(err));
    }
}
