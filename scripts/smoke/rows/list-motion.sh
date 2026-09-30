# The list motion of qs.Ui, ListCursor, in the Settings plugin list and the
# launcher: under a slowed motion scale the cursor travels between rows, a
# reading caught between where it stood and where it rests, which is the
# contrast that proves the reader sees motion; at motion.scale 0 it lands at
# once, with no reading between. The rows run with the plugins disabled as
# the rows before left them, and leave them so, with the default theme.
set -euo pipefail
motion_theme="$home/.config/vgs/theme.json"
write_motion_theme() { printf '%s\n' "$1" >"$motion_theme.tmp" && mv -T -- "$motion_theme.tmp" "$motion_theme"; }
cursor_y() { ipc smoke readShownDescendant "$1" "$2" ListCursor y; }
# glide_seen HOST ID KEY: press KEY in the list the instance HOST/ID draws
# and read its ListCursor's y six times after. `moving` when two readings in
# a row both left where the cursor stood and differ, as a travel reads;
# `still` when none did, as a cursor that lands at once reads its old place
# and then only its new one.
glide_seen() {
  local from reading readings=()
  from="$(cursor_y "$1" "$2")" || return
  [[ $from =~ ^-?[0-9.e+-]+$ ]] || { echo "unreadable: $from"; return; }
  type_keys -k "$3" || return
  for _ in 1 2 3 4 5 6; do
    reading="$(cursor_y "$1" "$2")" || return
    readings+=("$reading")
  done
  python3 - "$from" "${readings[@]}" <<'PY'
import sys
start, *seen = (float(v) for v in sys.argv[1:])
moved = [v for v in seen if v != start]
print("moving" if any(a != b for a, b in zip(moved, moved[1:])) else "still")
PY
}

# Motion four times slower: the Settings list travels over 250 * 4 ms and
# the launcher's over its own 250 * 4 ms.
write_motion_theme '{ "schemaVersion": 1, "name": "slowlist", "tokens": { "motion": { "scale": 4 } } }'
expect_poll "the slowed scale reaches the list motion" 1000 ipc smoke themeValue motion.list.travel.duration

expect "enabling the Settings plugin for the list motion is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect "the Settings window summons for the list motion" ok ipc shell summon window vgs.settings '{}'
expect_poll "the Settings window takes the keyboard" true ipc smoke activeFocusIn window vgs.settings
expect_poll "the Settings list's cursor holds its first row" true ipc smoke readShownDescendant window vgs.settings ListCursor shown
render expect "the Settings list's cursor travels to the next row under a slowed scale" moving glide_seen window vgs.settings Down
write_motion_theme '{ "schemaVersion": 1, "name": "still", "tokens": { "motion": { "scale": 0 } } }'
expect_poll "motion scale 0 reaches the list motion" 0 ipc smoke themeValue motion.list.travel.duration
expect "at motion scale 0 the Settings list's cursor lands on the row at once" still glide_seen window vgs.settings Up
# A filter moves rows under a resting pointer: the list disarms the pointer
# first, so a row that lands under it takes nothing from the keyboard. The
# pointer arrives on the second row by two motions, which arm it.
settings_second="$(ipc smoke itemTexts window vgs.settings ListItem | py_reply 'import json,sys; print(json.load(sys.stdin)[1][0])')" || settings_second=""
settings_row_box="$(ipc smoke windowGeometry window vgs.settings ListItem "$settings_second")" || settings_row_box=""
if read -r row_x row_y < <(at_centre window:Settings "$settings_row_box") && hover "$((row_x - 6))" "$row_y" && hover "$row_x" "$row_y"; then
  expect_poll "a moving pointer arms the Settings list" true ipc smoke readShownDescendant window vgs.settings ListCursor armed
  type_keys e || fail "typing a filter into the Settings search failed"
  expect_poll "the filter reaches the Settings list" '"e"' ipc smoke readShownDescendant window vgs.settings ListPage query
  expect "a filter disarms the pointer resting over the Settings list" false ipc smoke readShownDescendant window vgs.settings ListCursor armed
  rest_pointer || fail "moving the pointer off the Settings list failed"
else
  fail "the pointer did not reach the Settings list's row ${settings_second:-unread}"
fi
expect "hiding the Settings window after the list motion is allowed" ok ipc shell hide window vgs.settings
expect_poll "the Settings window is gone" 0 window_count Settings
expect "disabling the Settings plugin after the list motion is allowed" ok ipc shell setPluginEnabled vgs.settings false

# The launcher's list: Ctrl+B lists the categories and the first Down
# gives the list its cursor, on the first row.
expect "enabling the launcher for the list motion is allowed" ok ipc shell setPluginEnabled vgs.launcher true
launcher_categories() {
  expect "the launcher summons for the list motion" ok ipc shell summon overlay vgs.launcher '{}'
  expect_poll "the launcher holds the keyboard for the list motion" true ipc smoke activeFocusIn overlay vgs.launcher
  type_keys -M ctrl -k b -m ctrl -k Down || fail "listing the categories failed"
  expect_poll "the launcher's cursor holds the first category" true ipc smoke readShownDescendant overlay vgs.launcher ListCursor shown
}
launcher_travel() { ipc smoke readInstance overlay vgs.launcher listMotion | py_reply 'import json,sys; print(json.load(sys.stdin)["travel"]["duration"])'; }
write_motion_theme '{ "schemaVersion": 1, "name": "slowlist", "tokens": { "motion": { "scale": 4 } } }'
launcher_categories
expect_poll "the slowed scale reaches the launcher's list motion" 1000 launcher_travel
render expect "the launcher's cursor travels to the next row under a slowed scale" moving glide_seen overlay vgs.launcher Down
write_motion_theme '{ "schemaVersion": 1, "name": "still", "tokens": { "motion": { "scale": 0 } } }'
expect_poll "motion scale 0 reaches the launcher's list motion" 0 launcher_travel
expect "at motion scale 0 the launcher's cursor lands on the row at once" still glide_seen overlay vgs.launcher Down
type_keys -k Escape -k Escape || fail "closing the launcher failed"
expect_poll "the launcher closes after the list motion" 0 layer_count vgs:overlay
expect "disabling the launcher after the list motion is allowed" ok ipc shell setPluginEnabled vgs.launcher false

write_motion_theme '{ "schemaVersion": 1, "name": "vgs", "tokens": {} }'
expect_poll "the defaults return after the list motion" vgs ipc smoke themeName
