// Toast queue policy: the three ways an entry can leave the queue without
// having been shown, in one place so the property they share can be tested
// rather than described.
//
// That property is REACHABILITY: after a drop, the removed entry must not be
// reachable from the queue the service goes on to hold. It is not "must use
// filter" and it is not "must not use splice" -- `Array.prototype.splice()`
// removes the array's reference just as a filter does, so banning it forbids a
// correct implementation without proving anything. Every function here returns
// the queue the caller assigns back, and scripts/test-toast-actions.js checks
// the reachability property against this implementation, against a splice-based
// one, and against a leaky one, so the check is known to accept both correct
// forms and reject the incorrect one.
//
// The other rule these encode: some categories must never be dropped by a trim
// at all. `undroppableCategories` is ToastService's list, passed in as a
// predicate so this file stays free of policy about which categories those are.

// Every entry except those in `category`. Used when a category supersedes its
// own queued entry, and when one is dismissed on request.
function dropCategory(entries, category) {
    return entries.filter(function (entry) {
        return entry.category !== category;
    });
}

// Every entry except those at `level`, keeping protected ones whatever their
// level. An undroppable error is still undroppable.
function dropLevel(entries, level, isUndroppable) {
    return entries.filter(function (entry) {
        return entry.level !== level || isUndroppable(entry.category);
    });
}

// Shortens `entries` to at most `limit` by removing DROPPABLE entries from the
// end. Protected entries are never removed, so the result can exceed `limit` by
// their count -- bounded in practice because showToast() replaces a queued entry
// sharing a category before enqueueing, so each protected category holds at most
// one slot.
//
// Trimming from the end keeps the oldest entries, which are the ones closest to
// being shown.
function trimToLimit(entries, limit, isUndroppable) {
    var result = entries.slice();
    for (var i = result.length - 1; i >= 0 && result.length > limit; i--) {
        if (!isUndroppable(result[i].category)) {
            result = result.slice(0, i).concat(result.slice(i + 1));
        }
    }
    return result;
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        dropCategory: dropCategory,
        dropLevel: dropLevel,
        trimToLimit: trimToLimit
    };
}
