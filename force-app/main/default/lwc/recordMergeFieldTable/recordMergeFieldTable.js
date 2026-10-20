import { LightningElement, api } from 'lwc';

/**
 * One row per field with a radio button for each of two values.
 * Rows come from buildFieldRows() in recordMerge. Fires "valueselect"
 * with { field, side } when a value is chosen.
 */
export default class RecordMergeFieldTable extends LightningElement {
    @api rows = [];
    @api leftHeader;
    @api rightHeader;
    @api tableLabel = 'Field comparison';

    handleValueSelect(event) {
        const { field, side } = event.target.dataset;
        this.dispatchEvent(new CustomEvent('valueselect', { detail: { field, side } }));
    }
}
