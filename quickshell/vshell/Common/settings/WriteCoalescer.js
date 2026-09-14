.pragma library

// Write coalescing for a JSON-backed store. A setter marks the store dirty and restarts
// the store's one timer; the commit serialises once, writes once, then runs the hooks
// queued since the previous commit. Hooks run after the write because the helpers they
// start read the persisted file.

function create() {
    return {
        dirty: false,
        hooks: [],
        lastWrittenText: null
    };
}

function markDirty(state) {
    state.dirty = true;
}

function pending(state) {
    return state.dirty || state.hooks.length > 0;
}

// Returns a hook map for Spec.set: `immediate` hooks run at assignment, `deferred` hooks
// queue for the next commit. A hook queued again for the same key keeps the old value
// from its first call, the value the key held before the batch began.
function deferHooks(state, immediate, deferred) {
    var out = {};
    for (var name in immediate)
        out[name] = immediate[name];
    for (var queued in deferred)
        out[queued] = _queueing(state, queued, deferred[queued]);
    return out;
}

function _queueing(state, name, fn) {
    return function (root, key, oldValue) {
        for (var i = 0; i < state.hooks.length; i++) {
            if (state.hooks[i].name === name && state.hooks[i].key === key)
                return;
        }
        state.hooks.push({
            name: name,
            fn: fn,
            root: root,
            key: key,
            oldValue: oldValue
        });
    };
}

// Performs the pending write when `canWrite` holds, then runs the queued hooks in queue
// order. A hook that assigns a persisted key is written by a second write, made only when
// the serialised text differs from the first. A refused write is dropped, as an
// uncoalesced save would drop it; the hooks still run because the assignments they follow
// already happened. Returns the number of writes.
function commit(state, canWrite, serialize, write) {
    var writes = 0;
    if (state.dirty && canWrite) {
        var text = serialize();
        state.lastWrittenText = text;
        write(text);
        writes++;
    }
    state.dirty = false;
    var hooks = state.hooks;
    state.hooks = [];
    for (var i = 0; i < hooks.length; i++)
        hooks[i].fn(hooks[i].root, hooks[i].key, hooks[i].oldValue);
    if (hooks.length > 0 && canWrite) {
        var after = serialize();
        if (after !== state.lastWrittenText) {
            state.lastWrittenText = after;
            write(after);
            writes++;
        }
        state.dirty = false;
    }
    return writes;
}

// A file watcher reporting text identical to this store's last write is that write's echo.
function isSelfEcho(state, text) {
    return state.lastWrittenText !== null && text === state.lastWrittenText;
}
