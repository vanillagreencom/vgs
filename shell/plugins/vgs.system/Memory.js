.pragma library

// The section the System window showed last, which `{}` opens again. The
// window is destroyed when it closes; this library is loaded once per
// engine, so the id outlives the window and goes with the shell. A new
// source revision of the plugin loads it again, empty.
var lastPane = "";

function remember(id) {
    lastPane = id;
}

function last() {
    return lastPane;
}
