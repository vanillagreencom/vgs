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
var TERMINAL_APP_IDS = [
    "blackbox",
    "com.raggesilver.blackbox",
    "contour",
    "dev.warp.warp",
    "foot",
    "footclient",
    "havoc",
    "hyper",
    "io.elementary.terminal",
    "kgx",
    "org.gnome.console",
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

// Wayland app ids and Hyprland window classes differ in case for the same
// application (Alacritty vs alacritty), and desktop-file-derived ids can carry
// the suffix.
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

// argv for wtype: press modifiers, press+release the key, release modifiers.
// An empty or unknown app id resolves to Ctrl+V — the target is unknown, and
// that is the documented fallback rather than a guess.
function pasteCommand(appId) {
    if (isTerminalAppId(appId))
        return ["wtype", "-M", "ctrl", "-M", "shift", "-P", "v", "-p", "v", "-m", "shift", "-m", "ctrl"];
    return ["wtype", "-M", "ctrl", "-P", "v", "-p", "v", "-m", "ctrl"];
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        TERMINAL_APP_IDS: TERMINAL_APP_IDS,
        TERMINAL_APP_NAMES: TERMINAL_APP_NAMES,
        normalizeAppId: normalizeAppId,
        isTerminalAppId: isTerminalAppId,
        pasteCommand: pasteCommand
    };
}
