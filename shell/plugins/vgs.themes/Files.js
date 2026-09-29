.pragma library

// The `file://` URL of absolute PATH, each segment percent-encoded, so a
// name holding `#`, `?` or a space reaches the file it names. The
// background and the theme browser load images through it.
function fileUrl(path) {
    return "file://" + path.split("/").map(encodeURIComponent).join("/");
}
