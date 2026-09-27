.pragma library

// Select Ctrl+Shift+V for recognized terminal app ids and Ctrl+V otherwise.
// Match generic terminal names only as complete ids; suffix matching is limited to distinctive names.
// Terminals with configuration-dependent clipboard bindings are excluded.
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
    "org.deepin.terminal",
    "org.gnome.console",
    "org.gnome.terminal",
    "org.mate.terminal",
    "org.xfce.terminal",
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

// Strip control and Unicode format characters before logging an app id, then limit its length.
// Supplementary format characters require surrogate-pair alternatives in these UTF-16 patterns.
// Return an empty string when no characters remain.
var MAX_LOGGED_APP_ID_LENGTH = 64;
var LOG_UNSAFE_RE = /[\x00-\x1f\x7f-\x9f\u00ad\u0600-\u0605\u061c\u06dd\u070f\u0890-\u0891\u08e2\u180e\u200b-\u200f\u2028\u2029\u202a-\u202e\u2060-\u2064\u2066-\u206f\ufeff\ufff9-\ufffb]|\ud804[\udcbd\udccd]|\ud80d[\udc30-\udc3f]|\ud82f[\udca0-\udca3]|\ud834[\udd73-\udd7a]|\udb40[\udc01\udc20-\udc7f]/g;

function displayAppId(appId) {
    var id = String(appId === undefined || appId === null ? "" : appId)
        .replace(LOG_UNSAFE_RE, "");
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
