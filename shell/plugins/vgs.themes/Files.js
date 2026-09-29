.pragma library

// The `file://` URL of absolute PATH, each segment percent-encoded, so a
// name holding `#`, `?` or a space reaches the file it names. The
// background and the theme browser load images through it.
function fileUrl(path) {
    return "file://" + path.split("/").map(encodeURIComponent).join("/");
}

// fileUrl(PATH) with STAMP as its query, which a local file URL ignores. A
// new stamp is a new source, so an image loads again rather than from Qt's
// pixmap cache, which keys a decode by its URL and outlives the item.
function stampedUrl(path, stamp) {
    return fileUrl(path) + "?" + encodeURIComponent(String(stamp));
}
