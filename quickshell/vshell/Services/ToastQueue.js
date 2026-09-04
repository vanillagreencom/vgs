// Queue operations must release references to dropped entries.
// The caller supplies protected categories, which trimming must retain.

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
