.pragma library

function sourceIndex(options, filteredOptions, value, filteredIndex) {
    let occurrence = 0;
    for (let i = 0; i < filteredIndex; i++) {
        if (filteredOptions[i] === value)
            occurrence++;
    }
    for (let i = 0; i < options.length; i++) {
        if (options[i] !== value)
            continue;
        if (occurrence === 0)
            return i;
        occurrence--;
    }
    return -1;
}

function toggledValues(values, value) {
    return values.includes(value) ? values.filter(entry => entry !== value) : [...values, value];
}

function iconMap(options, icons) {
    const map = {};
    for (let i = 0; i < options.length; i++) {
        if (icons.length > i)
            map[options[i]] = icons[i];
    }
    return map;
}
