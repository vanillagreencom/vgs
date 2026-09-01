.pragma library

function optionRecords(options, icons, colors) {
    return options.map((value, sourceIndex) => ({
        id: sourceIndex,
        sourceIndex,
        value,
        label: String(value),
        icon: icons.length > sourceIndex ? icons[sourceIndex] : "",
        color: colors[value]
    }));
}

function toggledValues(values, value) {
    return values.includes(value) ? values.filter(entry => entry !== value) : [...values, value];
}
