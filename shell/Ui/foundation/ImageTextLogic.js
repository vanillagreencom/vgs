.pragma library

// ImageText's decisions, with no QML objects, so scripts/test-image-text-
// logic.js runs them under node: the StyledText a list of segments draws,
// the tokens it may be cut between, and the cut with an ellipsis.
//
// A segment is { markup } for StyledText the caller has already made safe,
// or { image, alt } for a local image URL and the plain text drawn in its
// place when it cannot be. An image draws as an `<img>` of `size` by `size`
// pixels, aligned to the middle of its line.

var ELLIPSIS = "\u2026";

// An image URL the component draws: a file URL whose text cannot end the
// attribute or start another tag. Any other draws its alt text.
function drawableUrl(url) {
    return typeof url === "string" && /^file:\/\/\/[^"<>&]+$/.test(url);
}

function escape(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// The unique drawable image URLs of `segments`, in order.
function imageUrls(segments) {
    var out = [];
    for (var i = 0; i < segments.length; i++) {
        var url = segments[i].image;
        if (drawableUrl(url) && out.indexOf(url) === -1) out.push(url);
    }
    return out;
}

// Markup cut into tokens: `tag` a whole `<...>` run, `break` a `<br>` tag,
// `space` a run of white space, `word` a run of anything else, an entity
// such as `&amp;` inside one. A cut falls between tokens, so it never
// splits a tag, an entity or a word. An unterminated `<` runs to the end,
// as the renderer reads it.
function markupTokens(markup) {
    var out = [];
    var re = /<[^>]*>?|\s+|[^<\s]+/g;
    var found;
    while ((found = re.exec(markup)) !== null) {
        var text = found[0];
        var kind = text.charAt(0) === "<" ? (/^<br\s*\/?>$/i.test(text) ? "break" : "tag") : /^\s/.test(text) ? "space" : "word";
        out.push({ kind: kind, markup: text });
    }
    return out;
}

// Every segment as tokens; an image is one `image` token, or its alt text
// when its URL is not drawable or `failed` names it.
function tokens(segments, size, failed) {
    var out = [];
    for (var i = 0; i < segments.length; i++) {
        var segment = segments[i];
        if (typeof segment.markup === "string") {
            out = out.concat(markupTokens(segment.markup));
        } else if (drawableUrl(segment.image) && failed.indexOf(segment.image) === -1) {
            out.push({ kind: "image", markup: "<img src=\"" + segment.image + "\" width=\"" + size + "\" height=\"" + size + "\" align=\"middle\">" });
        } else {
            out = out.concat(markupTokens(escape(segment.alt)));
        }
    }
    return out;
}

function hasImage(list) {
    for (var i = 0; i < list.length; i++)
        if (list[i].kind === "image") return true;
    return false;
}

function join(list, count) {
    var out = "";
    for (var i = 0; i < count; i++) out += list[i].markup;
    return out;
}

// The prefix lengths a cut may keep: each ends on a word or an image, so
// no cut ends on white space, a line break or an opening tag.
function cuts(list) {
    var out = [];
    for (var i = 0; i < list.length; i++)
        if (list[i].kind === "word" || list[i].kind === "image") out.push(i + 1);
    return out;
}

// The first `count` tokens, then the ellipsis.
function cut(list, count) {
    return join(list, count) + ELLIPSIS;
}

// The longest cut `fits` accepts, found by bisection over cuts(list), or
// the whole text when it fits as it is: { markup, cut } with `cut` false
// for the whole text. `fits(markup)` answers whether the markup draws
// within the lines allowed; a longer prefix never fits where a shorter one
// did not.
function elide(list, fits) {
    var whole = join(list, list.length);
    if (fits(whole)) return { markup: whole, cut: false };
    var at = cuts(list);
    var low = 0;
    var high = at.length - 1;
    var best = -1;
    while (low <= high) {
        var mid = (low + high) >> 1;
        if (fits(cut(list, at[mid]))) {
            best = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }
    return { markup: best === -1 ? ELLIPSIS : cut(list, at[best]), cut: true };
}
