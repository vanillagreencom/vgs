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
