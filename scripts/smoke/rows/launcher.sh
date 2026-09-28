# The launcher, vgs.launcher: a first-party overlay, bar entry and service.
# The harness starts it disabled; this row enables it, drives every path
# that opens it (the shortcut, the service's IPC, the host's summon and the
# bar entry), types into it on the nested seat and reads what it drew back
# through the probe: its rows, its look and its shader. A picker answers
# through two files under the sandbox's runtime directory, read here. The
# row ends with the plugin disabled and every registration released.
set -euo pipefail
launcher() { ipc vgs.launcher invoke "$1" "${2:-}"; }
read_launcher() { ipc smoke readInstance overlay vgs.launcher "$1"; }
launcher_rows() { ipc smoke launcherRows overlay vgs.launcher | python3 -c 'import json,sys; t=sys.stdin.read(); print(json.dumps(json.loads(t)) if t.startswith("[") else t.strip())'; }
# The launcher's rows whose kind is $1, as [label, detail] pairs.
rows_of() { launcher_rows | python3 -c 'import json,sys; print(json.dumps([[l, d] for k, l, d in json.load(sys.stdin) if k == sys.argv[1]]))' "$1"; }
has_row() { launcher_rows | python3 -c 'import json,sys; print(any(r[0] == sys.argv[1] and r[1] == sys.argv[2] for r in json.load(sys.stdin)))' "$1" "$2"; }
first_row() { launcher_rows | python3 -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps(r[0][:2]) if r else "none")'; }
lent_launcher() { ipc shell lent | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([[s for s in d["shortcuts"] if s.startswith("vgs.launcher")], [t for t in d["ipcTargets"] if t == "vgs.launcher"]]))'; }
file_text() { if [[ -f $1 ]]; then python3 -c 'import sys; print(repr(open(sys.argv[1]).read()))' "$1"; else echo absent; fi; }
file_search_children() { ps -e -o ppid=,args= | python3 -c 'import sys; print(sum(1 for l in sys.stdin if l.split(None, 1)[0] == sys.argv[1] and "file-search.sh" in l))' "$shell_qs_pid"; }
# The launcher's own look as the running instance holds it, one path.
look_at() { read_launcher look | python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v[k]
print(json.dumps(v))' "$1"; }
theme="$home/.config/vgs/theme.json"
write_theme() { printf '%s\n' "$1" >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"; }
user_menu="$home/.config/vgs/launcher/menu.json"
write_menu() { mkdir -p -- "${user_menu%/*}" && printf '%s\n' "$1" >"$user_menu.tmp" && mv -T -- "$user_menu.tmp" "$user_menu"; }
selection="$rt_dir/launcher-selection"
done_file="$rt_dir/launcher-done"
reset_answer() { rm -f -- "${selection:?}" "${done_file:?}"; }
# The compositor hands a new layer the keyboard after it maps; a row types
# only once the launcher holds it.
focused() { expect_poll "${1:-the launcher holds the keyboard}" true ipc smoke activeFocusIn overlay vgs.launcher; }

# An application the apps menu lists, whose launch leaves a file behind.
mkdir -p -- "$home/.local/share/applications"
printf '[Desktop Entry]\nType=Application\nName=Smoke Launch Probe\nGenericName=Probe\nExec=touch %s\n' "$home/launched-app" >"$home/.local/share/applications/smoke-launch-probe.desktop"
# Files the file search finds, one name twice.
mkdir -p -- "$home/launcher-files/older"
touch -- "$home/launcher-files/smoke-report.txt"
touch -d '2020-01-01' -- "$home/launcher-files/older/smoke-report.txt"

expect "the launcher starts disabled in the sandbox" False plugin_enabled vgs.launcher
expect "enabling the launcher is allowed" ok ipc shell setPluginEnabled vgs.launcher true
expect_poll "the launcher's service is built" True record_exists vgs.launcher
expect_poll "the service registered its shortcut and IPC target" '[["vgs.launcher:toggle"], ["vgs.launcher"]]' lent_launcher
launcher_shortcuts() { hypr globalshortcuts | python3 -c 'import sys; print(sum(1 for line in sys.stdin if "vgs.launcher:toggle" in line))'; }
expect_poll "the compositor lists the launcher's shortcut" 1 launcher_shortcuts
expect "a closed launcher holds no surface" 0 layer_count vgs:overlay

# The service's IPC summons the overlay: the bare search field, no rows.
expect "the service summons the launcher" ok launcher summon '{}'
expect_poll "the launcher maps one overlay surface" 1 layer_count vgs:overlay
expect_poll "the launcher is open" true read_launcher opened
focused "the open launcher holds the keyboard"
expect "the launcher opens as a bare search field" '[]' launcher_rows
expect "the bare field shows no list" 0 read_launcher visibleRowsHeight
shader_ok() { ipc smoke launcherShader overlay vgs.launcher | python3 -c 'import json,re,sys; d=json.loads(sys.stdin.read()); print(bool(re.search(r"/vgsh-sources-[0-9]+/[0-9a-f]+/shaders/edgelight\.frag\.qsb$", d["url"])) and d["compiled"])'; }
render expect_poll "the edge light's shader compiled from the published revision" True shader_ok

# Typing searches every row and application; Enter launches the first.
type_keys "smoke launch" || fail "typing into the launcher failed"
expect_poll "typing reaches the search" '"smoke launch"' read_launcher filterText
expect_poll "the search ranks the planted application first" '["app", "Smoke Launch Probe"]' first_row
type_keys -k Return || fail "sending Return failed"
expect_poll "Enter launched the application" True bash -c '[[ -f $1 ]] && echo True' _ "$home/launched-app"
expect_poll "a launch closes the launcher" 0 layer_count vgs:overlay

# Categories: Ctrl+B shows the tree; a route opens a submenu by id or alias.
expect "the service toggles the launcher open" ok launcher toggle ''
expect_poll "the toggled launcher maps" 1 layer_count vgs:overlay
focused
type_keys -M ctrl -k b -m ctrl || fail "sending Ctrl+B failed"
expect_poll "Ctrl+B shows the categories" True has_row menu System
expect "an unavailable integration shows why instead of vanishing" True has_row unavailable Install
type_keys -M ctrl -k b -m ctrl || fail "sending Ctrl+B failed"
expect_poll "Ctrl+B hides them again" '[]' launcher_rows
expect "a route by alias opens its menu" ok ipc shell summon overlay vgs.launcher '{"menu":"power-menu"}'
expect_poll "the alias resolved to the system menu" '"system"' read_launcher activeMenu
expect_poll "the submenu lists its actions" True has_row action Reboot
type_keys -k BackSpace || fail "sending BackSpace failed"
expect_poll "BackSpace on an empty search goes back" '"root"' read_launcher activeMenu
expect "a query payload opens with the search filled" ok ipc shell summon overlay vgs.launcher '{"query":"reb"}'
expect_poll "the query searched the rows" True has_row action Reboot
focused
type_keys -k Escape -k Escape || fail "sending Escape failed"
expect_poll "Escape clears the search, then closes" 0 layer_count vgs:overlay

# A user menu merges over the shipped one per key; a route naming an action
# runs it without opening; a row whose command is missing says so.
write_menu "{ \"schemaVersion\": 1, \"items\": { \"system\": { \"label\": \"Power\" }, \"smoke-run\": { \"label\": \"Smoke run\", \"run\": [\"touch\", \"$home/ran-action\"] }, \"smoke-missing\": { \"label\": \"Smoke missing\", \"requires\": [\"no-such-command-smoke\"], \"run\": [\"no-such-command-smoke\"] } } }"
expect "a route naming an action runs it" ok ipc shell summon overlay vgs.launcher '{"menu":"smoke-run"}'
expect_poll "the action ran" True bash -c '[[ -f $1 ]] && echo True' _ "$home/ran-action"
expect_poll "an action route leaves no surface" 0 layer_count vgs:overlay
expect "the launcher summons with the categories" ok ipc shell summon overlay vgs.launcher '{}'
focused
type_keys -M ctrl -k b -m ctrl || fail "sending Ctrl+B failed"
expect_poll "the user's label replaced the shipped one" True has_row menu Power
missing_row() { rows_of unavailable | python3 -c 'import json,sys; print(json.dumps([r for r in json.load(sys.stdin) if r[0] == "Smoke missing"]))'; }
expect_poll "a row with a missing command is unavailable and names it" '[["Smoke missing", "needs no-such-command-smoke"]]' missing_row
expected_errors+=('launcher: menu refused: file=.*/launcher/menu\.json items\.bad-item has unknown key "action"')
write_menu '{ "schemaVersion": 1, "items": { "bad-item": { "action": "omarchy-menu" } } }'
expect_log "a user menu the judge refuses is logged with its defect" 1 'launcher: menu refused: file=.*/launcher/menu\.json items\.bad-item has unknown key "action"'
expect_poll "the refused user menu shows as a notice" True has_row notice "Your menu file was refused"
expect_poll "the shipped menu stands after the refusal" True has_row menu System
rm -f -- "${user_menu:?}"
expect_poll "a removed user menu clears its notice" False has_row notice "Your menu file was refused"
type_keys -k Escape || fail "sending Escape failed"
expect_poll "Escape closes the launcher" 0 layer_count vgs:overlay

# A payload the judge refuses throws out of open(), and the host refuses the
# summon and takes the surface down.
expected_errors+=('summon host: vgs\.launcher open\(\) failed: launcher: refused: payload=')
expect "a payload that is not JSON is refused" "refused: open-failed=vgs.launcher" ipc shell summon overlay vgs.launcher 'nope'
expect "a payload with an unknown key is refused" "refused: open-failed=vgs.launcher" ipc shell summon overlay vgs.launcher '{"fontFamily":"x"}'
expect "a picker writing outside the runtime directory is refused" "refused: open-failed=vgs.launcher" ipc shell summon overlay vgs.launcher '{"mode":"select","selectionFile":"/tmp/x","doneFile":"/tmp/y"}'
expect_poll "a refused summon leaves no surface" 0 layer_count vgs:overlay

# Pickers: a select answers its row with `ok`, Escape answers `cancel`, an
# input answers what was typed, and a second summon cancels the first.
picker() { printf '{"mode":"%s","prompt":"Pick",%s"selectionFile":"%s","doneFile":"%s"}' "$1" "${2:+\"options\":$2,}" "$selection" "$done_file"; }
reset_answer
expect "a select summons" ok ipc shell summon overlay vgs.launcher "$(picker select '["alpha","x\tbeta\tsecond"]')"
expect_poll "the select lists its options, the glyph dropped" '[["option", "alpha", ""], ["option", "beta", "second"]]' launcher_rows
focused
type_keys -k Down -k Return || fail "sending keys to the select failed"
expect_poll "the select answered ok" "'ok\\n'" file_text "$done_file"
expect "the selection is the label and its detail" "'beta\\tsecond\\n'" file_text "$selection"
expect_poll "the answered select closed" 0 layer_count vgs:overlay
reset_answer
expect "a select summons again" ok ipc shell summon overlay vgs.launcher "$(picker select '["alpha"]')"
focused
type_keys -k Escape || fail "sending Escape failed"
expect_poll "Escape answers cancel" "'cancel\\n'" file_text "$done_file"
expect "a cancelled select writes no selection" absent file_text "$selection"
reset_answer
expect "an input summons" ok ipc shell summon overlay vgs.launcher "$(picker input)"
expect_poll "the input is open" '"input"' read_launcher mode
focused
type_keys "hello" -k Return || fail "typing into the input failed"
expect_poll "the input answered ok" "'ok\\n'" file_text "$done_file"
expect "the input's selection is what was typed" "'hello\\n'" file_text "$selection"
reset_answer
expect "a select summons for replacement" ok ipc shell summon overlay vgs.launcher "$(picker select '["alpha"]')"
expect "a menu summon replaces the waiting select" ok ipc shell summon overlay vgs.launcher '{}'
expect_poll "the replaced select was answered cancel" "'cancel\\n'" file_text "$done_file"
reset_answer
expect "a select summons before a hide" ok ipc shell summon overlay vgs.launcher "$(picker select '["alpha"]')"
expect "the host hides the waiting select" ok ipc shell hide overlay vgs.launcher
expect_poll "a hidden select answers cancel" "'cancel\\n'" file_text "$done_file"
expect_poll "the hidden select holds no surface" 0 layer_count vgs:overlay

# File search: f: finds files by name, same-named hits newest first; F:
# folders; a helper that cannot build its index says why in the list.
expect "the launcher summons for files" ok ipc shell summon overlay vgs.launcher '{"query":"f:smoke-report"}'
expect_poll "f: lists both files of one name, newest first" '[["smoke-report.txt", "~/launcher-files"], ["smoke-report.txt", "~/launcher-files/older"]]' rows_of file
expect "the file index lives in the launcher's cache" True bash -c '[[ -s $1 ]] && echo True' _ "$home/.cache/vgs/launcher/f.idx"
expect "F: searches folders" ok ipc shell summon overlay vgs.launcher '{"query":"F:launcher-files"}'
expect_poll "F: lists the folder" '[["launcher-files", "~"]]' rows_of folder
focused
type_keys -k Escape -k Escape || fail "sending Escape failed"
expect_poll "the file search closed" 0 layer_count vgs:overlay
rm -rf -- "${home:?}/.cache/vgs/launcher"
printf 'not a directory\n' >"$home/.cache/vgs/launcher"
expected_errors+=('launcher: file-search: index=f error=mkdir')
expect "the launcher summons with no usable cache" ok ipc shell summon overlay vgs.launcher '{"query":"f:smoke-report"}'
expect_poll "an index the helper cannot build is a notice" '[["File search unavailable", "file-search: index=f error=mkdir"]]' rows_of notice
focused
type_keys -k Escape -k Escape || fail "sending Escape failed"
expect_poll "the failed file search closed" 0 layer_count vgs:overlay
rm -f -- "${home:?}/.cache/vgs/launcher"
expect_poll "no file search helper outlives the launcher" 0 file_search_children

# Repeated summons and hides leave one surface at most and none at the end.
for _ in 1 2 3 4 5; do
  launcher toggle '' >/dev/null
  launcher toggle '' >/dev/null
done
expect_poll "ten toggles leave no surface" 0 layer_count vgs:overlay
expect "the compositor's shortcut toggles the launcher" ok hypr dispatch 'hl.dsp.global("vgs.launcher:toggle")'
expect_poll "the shortcut opened the launcher" 1 layer_count vgs:overlay
expect "the shortcut toggles it closed" ok hypr dispatch 'hl.dsp.global("vgs.launcher:toggle")'
expect_poll "the shortcut closed the launcher" 0 layer_count vgs:overlay

# The bar entry: enabling placed it in the left section; a click opens the
# launcher on its screen, and a click outside the card closes it.
widget_placed() { bar_widget_ids | python3 -c 'import json,sys; print(all("vgs.launcher" in bar for bar in json.load(sys.stdin)))'; }
expect_poll "the bar entry is placed" True widget_placed
click_centre "$(bar_key)" vgs.launcher || fail "the click on the bar entry failed"
expect_poll "the bar entry opened the launcher" 1 layer_count vgs:overlay
# The press on the bar entry holds the pointer on the bar's surface; a
# motion moves it onto the launcher's before the click.
hover 10 "$((mon_h - 10))" || fail "moving the pointer off the card failed"
click 10 "$((mon_h - 10))" || fail "the click outside the card failed"
expect_poll "a click outside the card closed it" 0 layer_count vgs:overlay

# The theme menu lists the packages the theme capability reports. Whether
# an apply succeeded is MenuModel.applySucceeded, pinned under node: the
# launcher closes on the pick, and a destroyed instance hears no result.
expect "the launcher opens its theme menu" ok ipc shell summon overlay vgs.launcher '{"menu":"style.theme"}'
focused
expect_poll "the theme menu lists the vgs package" True has_row theme vgs
expect "the host hides the theme menu" ok ipc shell hide overlay vgs.launcher
expect_poll "the theme menu closed" 0 layer_count vgs:overlay

# The look: the theme reaches it through its mode and accent alone. Every
# other token of the theme moves and the look stays; the accent moves the
# accent; light mode applies the light glass.
expect "the launcher summons for its look" ok ipc shell summon overlay vgs.launcher '{}'
expect_poll "the look resolved" '"#c7151515"' look_at glass.fill
if ! look_before="$(read_launcher look)"; then fail "the launcher's look is unreadable"; fi
write_theme '{ "schemaVersion": 1, "name": "unrelated", "tokens": { "palette": { "foreground": "#ff00ff", "background": "#00ff00", "success": "#123456" }, "font": { "size": 22, "family": { "mono": "Serif", "sans": "Serif" } }, "space": { "unit": 7 }, "radius": { "md": 9 }, "text": { "body": { "size": 30 } }, "color": { "surface": "#ff0000" } } }'
expected_errors+=('theme: font=Serif unavailable')
expect_poll "the unrelated theme is accepted" unrelated ipc smoke themeName
unchanged_look() { [[ "$(read_launcher look)" == "$look_before" ]] && echo same || echo moved; }
expect_poll "every unrelated token leaves the launcher's look as it was" same unchanged_look
write_theme '{ "schemaVersion": 1, "name": "accent", "tokens": { "palette": { "accent": "#7aa2f7" } } }'
expect_poll "the accent reaches the launcher" '"#ff7aa2f7"' look_at palette.accent
expect "the accent reaches the caret's halo" '"#2e7aa2f7"' look_at caret.halo
expect "the accent leaves the glass" '"#c7151515"' look_at glass.fill
write_theme '{ "schemaVersion": 1, "name": "bright", "tokens": { "scheme": { "mode": "light" }, "palette": { "accent": "#a8330a" } } }'
expect_poll "light mode applies the light glass" '"#ccefefef"' look_at glass.fill
expect "light mode applies the light text" '"#ff2a2a2a"' look_at text.foreground
expect "light mode keeps the theme's accent" '"#ffa8330a"' look_at palette.accent
write_theme '{ "schemaVersion": 1, "name": "still", "tokens": { "motion": { "scale": 0 } } }'
expect_poll "reduced motion stills the launcher's durations" 0 look_at motion.duration.medium4
write_theme '{ "schemaVersion": 1, "name": "vgs", "tokens": {} }'
expect_poll "the defaults return" vgs ipc smoke themeName
expect_poll "the defaults' look is the first look" same unchanged_look

# A rescan that changes the plugin rebuilds it: a waiting picker is answered
# cancel, and the service registers its shortcut once again.
reset_answer
expect "a select summons before a rescan" ok ipc shell summon overlay vgs.launcher "$(picker select '["alpha"]')"
printf '\n' >>"$repo/shell/plugins/vgs.launcher/README.md"
expect "the rescan is accepted" ok ipc shell rescanPlugins
expect_poll "the rebuilt launcher answered the old picker cancel" "'cancel\\n'" file_text "$done_file"
expect_poll "the rebuilt service holds one shortcut and one target" '[["vgs.launcher:toggle"], ["vgs.launcher"]]' lent_launcher
# The rebuilt launcher reopened with the same payload, so it waits too.
expect "the host hides the rebuilt picker" ok ipc shell hide overlay vgs.launcher
expect_poll "the rebuilt picker closed" 0 layer_count vgs:overlay

# Disabling the plugin while a picker waits answers it, takes the surface
# down and releases every registration.
reset_answer
expect "a select summons before the disable" ok ipc shell summon overlay vgs.launcher "$(picker select '["alpha"]')"
expect "disabling the launcher is allowed" ok ipc shell setPluginEnabled vgs.launcher false
expect_poll "disabling answered the waiting picker cancel" "'cancel\\n'" file_text "$done_file"
expect_poll "the disabled launcher holds no surface" 0 layer_count vgs:overlay
expect_poll "the disabled launcher holds no registration" '[[], []]' lent_launcher
expect_poll "the disabled launcher has no build record" False record_exists vgs.launcher
expect_poll "no file search helper outlives the plugin" 0 file_search_children
