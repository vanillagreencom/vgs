.pragma library

let nextPoolId = 1;
const pools = {};

function createPool() {
    const id = String(nextPoolId++);
    pools[id] = {
        placeholders: []
    };
    return id;
}

function pool(id) {
    if (!pools[id])
        pools[id] = {
            placeholders: []
        };
    return pools[id];
}

function clear(id) {
    pool(id).placeholders = [];
}

function destroy(id) {
    delete pools[id];
}

function placeholder(id, index, makePlaceholder) {
    const p = pool(id);
    if (p.placeholders.length <= index)
        p.placeholders.push(makePlaceholder());
    return p.placeholders[index];
}
