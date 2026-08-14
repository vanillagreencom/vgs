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
// claim by suffix. Every <vendor>-terminal name in the second list is covered
// that way: gnome, xfce, deepin and mate.
//
// Those vendor ids are inferred from packaging metadata — desktop files,
// AppStream ids, Flathub — not confirmed against a running session, which is
// also why they are exact whole-id entries: a wrong one matches nothing and
// costs nothing, while a wrong segment would claim other vendors' apps. On the
// same evidence and by the same rule, Hyper is deliberately absent: no id of
// that shape could be found for it at all, and co.zeit.hyper is a package name
// rather than an app id, so listing it would assert something unevidenced.
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

// An app id is a string the client chose, so it can carry anything — escape
// sequences that render when an operator reads the log in a terminal, newlines
// that forge extra log lines, and Unicode format characters that reorder the
// rest of the line visually (U+202E and the directional isolates) or end it for
// a JS-based viewer (U+2028, U+2029). Everything that reaches a log line goes
// through here: those characters are dropped and the rest is clamped. Returns
// "" for an id that is empty or was entirely stripped, which callers render as
// their own "unknown" wording.
//
// The class is the whole Unicode format category (Cf), not the bidi controls
// alone: choosing characters one at a time is how U+061C ARABIC LETTER MARK was
// missed while its neighbours were stripped. Cf reaches past the BMP and these
// patterns match UTF-16 code units, so the format characters above U+FFFF are
// matched as their surrogate pairs, which is why this is an alternation rather
// than one character class. Characters that merely render blank without
// reordering or ending a line (U+3164 HANGUL FILLER and its kin) are outside the
// category and are left alone: they cannot forge a log line.
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
