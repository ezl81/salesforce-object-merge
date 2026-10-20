/**
 * Helpers shared by recordMerge, recordUnmerge and recordMergeHistory.
 */

export function isBlank(value) {
    return value === null || value === undefined || value === '';
}

/**
 * Rows for c-record-merge-field-table: one radio for the left side and one for
 * the right side of each field. Sides are 'A' or 'B' (valueA/displayA or valueB/displayB).
 */
export function buildFieldRows(fields, selections, leftSide, rightSide, groupName, onlyDifferences) {
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

//Field apiName -> side, for every field
export function allSelections(fields, side) {
    const selections = {};
    fields.forEach((field) => {
        selections[field.apiName] = side;
    });
    return selections;
}

export function reduceError(error) {
    if (Array.isArray(error?.body)) {
        return error.body.map((e) => e.message).join(', ');
    } else if (error?.body?.message) {
        return error.body.message;
    }
    return error?.message ?? 'Unknown error';
}
