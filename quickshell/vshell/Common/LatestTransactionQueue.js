function emptyState() {
    return {
        nextGeneration: 1,
        activeRequest: null,
        queuedRequest: null
    };
}

function submit(state, request) {
    var current = state || emptyState();
    var tagged = Object.assign({}, request, {
        generation: current.nextGeneration
    });
    if (current.activeRequest) {
        return {
            state: {
                nextGeneration: current.nextGeneration + 1,
                activeRequest: current.activeRequest,
                queuedRequest: tagged
            },
            startRequest: null,
            supersededRequest: current.queuedRequest
        };
    }
    return {
        state: {
            nextGeneration: current.nextGeneration + 1,
            activeRequest: tagged,
            queuedRequest: null
        },
        startRequest: tagged,
        supersededRequest: null
    };
}

function complete(state, generation) {
    var current = state || emptyState();
    if (!current.activeRequest || current.activeRequest.generation !== generation) {
        return {
            state: current,
            completedRequest: null,
            completedLatest: false,
            startRequest: null,
            ignored: true
        };
    }
    if (current.queuedRequest) {
        return {
            state: {
                nextGeneration: current.nextGeneration,
                activeRequest: current.queuedRequest,
                queuedRequest: null
            },
            completedRequest: current.activeRequest,
            completedLatest: false,
            startRequest: current.queuedRequest,
            ignored: false
        };
    }
    return {
        state: {
            nextGeneration: current.nextGeneration,
            activeRequest: null,
            queuedRequest: null
        },
        completedRequest: current.activeRequest,
        completedLatest: true,
        startRequest: null,
        ignored: false
    };
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        emptyState: emptyState,
        submit: submit,
        complete: complete
    };
}
