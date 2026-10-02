.pragma library

// The one judge of a manager or surface reply: `ok`, or `ok <detail>` such
// as `ok hidden=<ids>`, is success; every other reply is a refusal to show.
function isOk(reply) {
    return reply === "ok" || reply.indexOf("ok ") === 0;
}

// Display only. Plugins, Config and PluginLogic keep their reply contracts;
// Registry keeps build failures and HyprlandLayer keeps shortcut problems.
var MESSAGES = [
    [/^unknown: /, "This plugin is no longer available. Close Settings and open it again."],
    [/^refused: user-config=pending(?: |$)/, "VGS is loading your settings. Try again shortly."],
    [/^refused: user-config=(?:unparseable|malformed)(?: |$)/, "Your saved settings are invalid. VGS kept the last working settings."],
    [/^refused: user-config=unreadable(?: |$)/, "VGS could not read your settings. Close Settings and open it again to retry."],
    [/^refused: user-config=unwritable(?: |$)/, "VGS could not save this change. Try again."],
    [/^refused: disabled=\S+$|^refused: (?:action|secret|placed|tui)=\S+ reason=disabled$/, "Turn on this plugin before you change it."],
    [/^refused: bundled=\S+$/, "This plugin is included with VGS. Update VGS to update it, or turn it off to stop it."],
    [/^refused: setting=\S+ (?:undeclared|entry=none)$/, "This setting is no longer available. Close Settings and open it again."],
    [/^refused: setting=\S+ want=number$/, "Enter a number."],
    [/^refused: setting=\S+ want=string$/, "Enter text for this setting."],
    [/^refused: setting=\S+ want=boolean$/, "Use the switch to change this setting."],
    [/^refused: setting=\S+ want=(?:one-of-presets|one-of:.+)$/, "Choose a value from the list."],
    [/^refused: setting=\S+ want=datetime-format reason=(?:empty|multiline|too-long|unclosed-quote|no-field)$/, "The date or time format is invalid. Change the format."],
    [/^refused: setting=\S+ want=at-least:(-?\d+(?:\.\d+)?(?:e[+-]?\d+)?)$/, function (match) { return "Use a value of at least " + match[1] + "."; }],
    [/^refused: setting=\S+ want=at-most:(-?\d+(?:\.\d+)?(?:e[+-]?\d+)?)$/, function (match) { return "Use a value of at most " + match[1] + "."; }],
    [/^refused: key=\S+ undeclared$/, "This shortcut is no longer available. Close Settings and open it again."],
    [/^refused: key=\S+ (?:want=string-or-null|must be a string such as SUPER\+SPACE)$/, "Select the shortcut field and press its new keys."],
    [/^refused: key=\S+ (?:has an empty part: .+|ends in the modifier .+ and names no key|names no key: .+)$/, "The shortcut needs a key. Select the field and press its new keys."],
    [/^refused: key=\S+ has the unknown modifier .+, want one of .+$/, "VGS could not use this shortcut. Select the field and press its new keys."],
    [/^refused: key=\S+ repeats the modifier \S+$/, "The shortcut repeats a key. Select the field and press its new keys."],
    [/^refused: placed=\S+ reason=no-bar-widget$/, "This plugin has no bar item."],
    [/^refused: action=\S+ reason=undeclared$|^refused: tui=\S+ reason=(?:undeclared|args)$/, "This action is no longer available. Close Settings and open it again."],
    [/^refused: action=\S+ reason=not-offered$/, "This setup step is not needed now."],
    [/^refused: requirements=\S+ reason=satisfied$/, "All tools are installed."],
    [/^refused: notices=full limit=\d+$/, "Close an open setup notice and try again."],
    [/^refused: tui=\S+ reason=launcher-missing$/, "The setup window could not open. VGS is missing its terminal launcher, xdg-terminal-exec. Reinstall VGS to restore it."],
    [/^refused: secret=\S+ reason=busy$/, "VGS is saving another account. Try again shortly."],
    [/^refused: secret=\S+ reason=(?:undeclared|unlisted)$/, "This account is no longer available. Close Settings and open it again."],
    [/^refused: secret=\S+ reason=not-offered$/, "This account has changed. Close Settings and open it again."],
    [/^refused: secret=\S+ reason=value$/, "Enter a key on one line with at most 4096 characters."],
    [/^refused: secret write failed start-failed$/, "VGS could not open the key store. Try again."],
    [/^refused: secret write failed exit=-?\d+$/, "VGS could not change the saved account. Try again."],
    [/^build failed: [^:]+: refused: capability=\S+ held-by=\S+$/, "Another plugin uses this feature. Turn off that plugin before you turn on this one."],
    [/^build failed: [^:]+: /, "This plugin could not start. Check for an update."],
    [/^hyprland: .+ for \S+:\S+ skipped: already bound by .+$/, "Another plugin uses this shortcut. Change the shortcut under Keys."],
    [/^hyprland: appearance declaration ignored for \S+: already owned by .+$/, "Another plugin controls the window appearance. Turn off that plugin to use this one."],
    [/^hyprland: .+ for \S+:\S+ skipped: already set by .+$/, "Another plugin controls this setting. Turn off that plugin to use this one."],
    [/^hyprland: \S+ for \S+:\S+ skipped: want=(?:number|string|boolean|whole-number|one-of-presets|one-of:.+|at-(?:least|most):-?\d+(?:\.\d+)?(?:e[+-]?\d+)?|characters:.+|datetime-format reason=(?:empty|multiline|too-long|unclosed-quote|no-field))$/, "A saved setting is invalid. Choose another value."],
    [/^hyprland: shell\.json keys\.\S+ names no bind of \S+$/, "VGS ignored a saved shortcut that this plugin no longer supports."]
];

function line(reply) {
    if (isOk(reply)) return "";
    const text = String(reply);
    for (const row of MESSAGES) {
        const match = row[0].exec(text);
        if (match !== null) return typeof row[1] === "function" ? row[1](match) : row[1];
    }
    return "VGS could not complete this action. Close Settings and open it again to retry.";
}
