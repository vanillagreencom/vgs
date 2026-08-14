.pragma library

// Paste from history is injected as a keystroke into whatever window holds
// focus, so the keystroke has to match that window's paste binding. Terminal
// emulators keep Ctrl+V for the terminal itself (readline reads it as
// quoted-insert), so sending Ctrl+V there types stray input instead of
// pasting; they take Ctrl+Shift+V.
//
// The list is bounded on purpose: an app id that is not on it gets Ctrl+V,
// which is correct for ordinary GUI apps and is the behavior every target had
// before. Legacy X11 terminals (xterm, rxvt-unicode) are deliberately absent:
// their paste bindings are configuration-dependent and the ones they ship by
// default target the primary selection rather than the clipboard, so guessing
// a combo for them would trade one wrong keystroke for another.
//
// Two lists, because app ids come in two shapes. TERMINAL_APP_IDS is matched
// against the whole app id only, so a generic name (st, hyper, rio) claims
// nothing but itself. TERMINAL_APP_NAMES is additionally matched against the
// last segment of a reverse-DNS id (org.wezfurlong.wezterm,
// com.mitchellh.ghostty), and holds only names distinctive enough that an
// unrelated app carrying one is implausible.
//
// A terminal whose name is too generic to segment-match therefore needs its
// reverse-DNS id spelled out in full in the first list — org.gnome.Terminal and
// page.codeberg.dnkl.foot end in "terminal" and "foot", which nobody else may
// claim by suffix.
var TERMINAL_APP_IDS = [
    "blackbox",
    "com.raggesilver.blackbox",
    "com.rioterm.rio",
    "contour",
    "dev.warp.warp",
    "foot",
    "footclient",
    "havoc",
    "hyper",
    "io.elementary.terminal",
    "kgx",
    "org.contourterminal.contour",
    "org.gnome.console",
    "org.gnome.terminal",
    "page.codeberg.dnkl.foot",
    "rio",
    "sakura",
    "st",
    "tabby",
    "wayst",
    "zutty"
];

var TERMINAL_APP_NAMES = [
    "alacritty",
    "cool-retro-term",
    "deepin-terminal",
    "extraterm",
    "ghostty",
    "gnome-terminal",
    "gnome-terminal-server",
    "guake",
    "kitty",
    "konsole",
    "lxterminal",
    "mate-terminal",
    "ptyxis",
    "qterminal",
    "terminator",
    "terminology",
    "termite",
    "tilix",
    "wezterm",
    "wezterm-gui",
    "xfce4-terminal",
    "yakuake"
];

// App ids are reported with whatever casing the vendor chose (Alacritty,
// org.gnome.Console), and a desktop-file-derived id can carry the .desktop
// suffix. The lists below are lower-case and suffix-free.
function normalizeAppId(appId) {
    var id = String(appId === undefined || appId === null ? "" : appId).trim().toLowerCase();
    if (id.length > 8 && id.lastIndexOf(".desktop") === id.length - 8)
        id = id.slice(0, id.length - 8);
    return id;
}

function isTerminalAppId(appId) {
    var id = normalizeAppId(appId);
    if (id.length === 0)
        return false;
    if (TERMINAL_APP_IDS.indexOf(id) !== -1 || TERMINAL_APP_NAMES.indexOf(id) !== -1)
        return true;
    var lastSegment = id.slice(id.lastIndexOf(".") + 1);
    return lastSegment !== id && TERMINAL_APP_NAMES.indexOf(lastSegment) !== -1;
}

// An app id is a string the client chose, so it can carry anything — escape
// sequences that render when an operator reads the log in a terminal, newlines
// that forge extra log lines, and Unicode format characters that reorder the
// rest of the line visually (U+202E and the directional isolates) or end it for
// a JS-based viewer (U+2028, U+2029). Everything that reaches a log line goes
// through here: those characters are dropped and the rest is clamped. Returns
// "" for an id that is empty or was entirely stripped, which callers render as
// their own "unknown" wording.
var MAX_LOGGED_APP_ID_LENGTH = 64;

function displayAppId(appId) {
    var id = String(appId === undefined || appId === null ? "" : appId)
        .replace(/[\x00-\x1f\x7f-\x9f\u200b-\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g, "");
    if (id.length <= MAX_LOGGED_APP_ID_LENGTH)
        return id;
    return id.slice(0, MAX_LOGGED_APP_ID_LENGTH) + "...";
}

// argv for wtype: press modifiers, press+release the key, release modifiers.
// An empty or unknown app id resolves to Ctrl+V — the target is unknown, and
// that is the documented fallback rather than a guess.
function pasteCommand(appId) {
    if (isTerminalAppId(appId))
        return ["wtype", "-M", "ctrl", "-M", "shift", "-P", "v", "-p", "v", "-m", "shift", "-m", "ctrl"];
    return ["wtype", "-M", "ctrl", "-P", "v", "-p", "v", "-m", "ctrl"];
}

// Releases both modifiers a paste can press, pressing nothing. An injection
// terminated mid-keystroke never runs its own release, so this is what clears
// the seat afterwards.
function releaseModifiersCommand() {
    return ["wtype", "-m", "shift", "-m", "ctrl"];
}
