.pragma library

// One instance owns all pending releases. An early release forgets its
// callback before running it, so keeping the release handle retains no resource.
function create(reportError) {
    const pending = [];
    let closed = false;
    return {
        get count() { return pending.length; },
        register: function(cleanup) {
            if (closed) throw new Error("lifetime: registration after teardown");
            const release = releaseHandle({ pending: pending, cleanup: cleanup });
            pending.push(release);
            return release;
        },
        drain: function() {
            closed = true;
            while (pending.length > 0) {
                try {
                    pending[pending.length - 1]();
                } catch (e) {
                    reportError(e);
                }
            }
        }
    };
}

// This scope holds only the mutable entry, never the original callback.
function releaseHandle(entry) {
    const release = function() {
        if (entry.cleanup === null) return;
        const callback = entry.cleanup;
        entry.cleanup = null;
        entry.pending.splice(entry.pending.indexOf(release), 1);
        entry.pending = null;
        callback();
    };
    return release;
}
