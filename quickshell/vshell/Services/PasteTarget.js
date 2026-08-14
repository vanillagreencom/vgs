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
// Names are matched against the whole app id and against the last segment of a
// reverse-DNS id (org.wezfurlong.wezterm, com.mitchellh.ghostty). Terminals
// whose last segment is a common word are listed by their full id so the
// segment match cannot claim an unrelated app.
var TERMINAL_APP_IDS = [
    "alacritty",
    "blackbox",
    "contour",
    "cool-retro-term",
    "deepin-terminal",
    "dev.warp.warp",
    "extraterm",
    "foot",
    "footclient",
    "ghostty",
    "gnome-terminal",
    "guake",
    "havoc",
    "hyper",
    "kgx",
    "kitty",
    "konsole",
    "lxterminal",
    "mate-terminal",
    "org.gnome.console",
    "ptyxis",
    "qterminal",
    "rio",
    "sakura",
    "st",
    "tabby",
    "terminator",
    "terminology",
    "termite",
    "tilix",
    "wayst",
    "wezterm",
    "wezterm-gui",
    "xfce4-terminal",
    "yakuake",
    "zutty"
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

function appIdTokens(appId) {
    var id = normalizeAppId(appId);
    if (id.length === 0)
        return [];
    var lastSegment = id.slice(id.lastIndexOf(".") + 1);
    return lastSegment === id ? [id] : [id, lastSegment];
}

function isTerminalAppId(appId) {
    var tokens = appIdTokens(appId);
    for (var i = 0; i < tokens.length; i++) {
        if (TERMINAL_APP_IDS.indexOf(tokens[i]) !== -1)
            return true;
    }
    return false;
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
        normalizeAppId: normalizeAppId,
        isTerminalAppId: isTerminalAppId,
        pasteCommand: pasteCommand
    };
}
