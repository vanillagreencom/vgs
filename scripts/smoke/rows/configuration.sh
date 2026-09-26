# An unreadable user file settles, keeps the bar, and refuses every write
# until it reads again.
set -euo pipefail
config_user_state() { ipc shell listPlugins | python3 -c 'import json,sys; print(json.load(sys.stdin)["config"]["user"])'; }
expected_errors+=('config: user file unreadable at ')
chmod 000 "$home/.config/vgs/shell.json"
expect "reloading an unreadable user file answers ok" ok ipc shell reloadConfig
expect_poll "the user file reads as unreadable" unreadable config_user_state
expect "a write to an unreadable user file is refused" "refused: user-config=unreadable path=$home/.config/vgs/shell.json" ipc shell setPluginEnabled acme.tick false
expect "the bar stays with an unreadable user file" "$monitors" bar_count
chmod 644 "$home/.config/vgs/shell.json"
expect "reloading the readable user file answers ok" ok ipc shell reloadConfig
expect_poll "the user file reads as loaded again" loaded config_user_state

# A user file that parses but fails PluginLogic.configError is malformed: the
# defect is logged, the last good value keeps the bar, and writes are refused
# until the file passes again.
user_good="$(cat "$home/.config/vgs/shell.json")"
expected_errors+=('config: .*/shell\.json malformed: plugins\.0 must be an object with a string id')
printf '{ "version": 1, "plugins": ["acme.tick"] }\n' >"$home/.config/vgs/shell.json.tmp" && mv -T -- "$home/.config/vgs/shell.json.tmp" "$home/.config/vgs/shell.json"
expect_poll "a user file with a malformed plugins row reads as malformed" malformed config_user_state
expect_log "the malformed row is logged with its path in the file" 1 'config: .*/shell\.json malformed: plugins\.0 must be an object with a string id'
expect "a write to a malformed user file is refused" "refused: user-config=malformed path=$home/.config/vgs/shell.json" ipc shell setPluginEnabled acme.tick false
expect "the bar stays with a malformed user file" "$monitors" bar_count
expect_widgets "the placed widget stays with a malformed user file" '["acme.tick"]'
printf '%s\n' "$user_good" >"$home/.config/vgs/shell.json.tmp" && mv -T -- "$home/.config/vgs/shell.json.tmp" "$home/.config/vgs/shell.json"
expect_poll "the user file reads as loaded once the row is fixed" loaded config_user_state

# theme.json recolours every surface through Color; the bar's foreground is
# read back from a built bar instance. A file that does not parse, is not
# an object, or holds a role that is not a colour is logged and the last
# good palette stays.
theme="$home/.config/vgs/theme.json"
# A QML color reads back as its channel object; the row compares its hex.
bar_foreground() { ipc shell readInstance "$(bar_key)" vgs.bar foreground | python3 -c 'import json,sys; c=json.load(sys.stdin); print("#%02x%02x%02x" % tuple(round(c[k] * 255) for k in "rgb"))'; }
expect "the bar draws the default foreground with no theme file" '#cacccc' bar_foreground
printf '{ "foreground": "#123456" }\n' >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"
expect_poll "a theme file recolours the bar's foreground" '#123456' bar_foreground
expected_errors+=('theme: .*/theme\.json does not parse: ')
printf '{ nope\n' >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"
expect_log "a theme file that does not parse is logged" 1 'theme: .*/theme\.json does not parse: '
expect "an unparseable theme file keeps the last good palette" '#123456' bar_foreground
expected_errors+=('theme: .*/theme\.json malformed: theme must be an object' 'theme: .*/theme\.json malformed: foreground is not a colour: "#12345"')
printf '[ "#654321" ]\n' >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"
expect_log "a theme file that is not an object is logged" 1 'theme: .*/theme\.json malformed: theme must be an object'
expect "a theme file that is not an object keeps the last good palette" '#123456' bar_foreground
printf '{ "foreground": "#12345" }\n' >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"
expect_log "a theme role that is not a colour is logged" 1 'theme: .*/theme\.json malformed: foreground is not a colour: "#12345"'
expect "a theme role that is not a colour keeps the last good palette" '#123456' bar_foreground
# A theme file removed while the shell runs clears every override, so the
# bar draws the same defaults a fresh start without the file would. The
# watcher keeps the file's directory, so a file created in its place is read
# again. A file that turns unreadable is logged and the last good palette
# stays; a permission change alone reaches the watcher, so no reload is
# forced.
rm -f -- "${theme:?}"
expect_poll "a removed theme file returns the bar's foreground to the default" '#cacccc' bar_foreground
printf '{ "foreground": "#654321" }\n' >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"
expect_poll "a theme file created after a removal recolours the bar's foreground" '#654321' bar_foreground
expected_errors+=('theme: .*/theme\.json unreadable: ')
chmod 000 -- "$theme"
expect_log "a theme file that turns unreadable is logged" 1 'theme: .*/theme\.json unreadable: '
expect "an unreadable theme file keeps the last good palette" '#654321' bar_foreground
chmod 644 -- "$theme"
printf '{ "foreground": "#123456" }\n' >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"
expect_poll "a theme file readable again recolours the bar's foreground" '#123456' bar_foreground
