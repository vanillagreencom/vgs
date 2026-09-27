function emptyState() {
    return {
        activeRequest: null,
        queuedRequest: null
    };
}

function isBusy(state) {
    return !!(state && state.activeRequest);
}

// Return a new state so QML property bindings observe every transition.
function submit(state, request) {
    var current = state || emptyState();
    if (current.activeRequest) {
        // Persisted commits/resets are authoritative. A visual preview must not
        // supersede one, or its required refresh would be suppressed.
        if (current.activeRequest.preview !== true && request.preview === true) {
            return {
                state: current,
                startRequest: null,
                dropped: true
            };
        }
        return {
            state: {
                activeRequest: current.activeRequest,
                queuedRequest: request
            },
            startRequest: null,
            dropped: false
        };
    }

    return {
        state: {
            activeRequest: request,
            queuedRequest: null
        },
        startRequest: request,
        dropped: false
    };
}

// The queued request supersedes the completed result, regardless of whether
// that result succeeded. Only a terminal result should refresh or be announced.
function complete(state, succeeded) {
    var current = state || emptyState();
    if (current.queuedRequest) {
        return {
            state: {
                activeRequest: current.queuedRequest,
                queuedRequest: null
            },
            startRequest: current.queuedRequest,
            superseded: true,
            refresh: false,
            announce: false,
            success: null
        };
    }

    return {
        state: emptyState(),
        startRequest: null,
        superseded: false,
        refresh: true,
        announce: true,
        success: succeeded === true
    };
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        emptyState: emptyState,
        isBusy: isBusy,
        submit: submit,
        complete: complete
    };
}
