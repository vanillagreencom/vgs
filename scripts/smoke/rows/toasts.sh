# Toasts, shown by the fixture service through its `toasts` capability and
# read back from the core's lending record, the compositor's layer list and
# the host. Every way a toast ends runs one release: expiry, the user's
# click on its close button, the disposer the plugin holds and the
# instance's teardown.
set -euo pipefail
toast() { ipc acme.probe invoke toast "$1"; }
toast_titles() { ipc shell lent | py_reply 'import json,sys; t=json.load(sys.stdin)["toasts"]; print(json.dumps([e["title"] for e in t[sys.argv[1]]]))' "$1"; }
toast_screen() { ipc shell lent | py_reply 'import json,sys; print(json.load(sys.stdin)["toasts"]["screen"])'; }
toast_surface_height() { layers_of vgs:toast | py_reply 'import json,sys; l=json.load(sys.stdin); print(l[0][3] if l else 0)'; }
settings_open() { [[ $(ipc smoke instanceGeometry window vgs.settings) != absent ]] && echo open || echo closed; }
note_toast_bar_geometry() {
  local t
  t="$(layer_bar_geometry vgs:toast toast.margin)" || { fail "toast geometry unreadable"; return; }
  ok "toast geometry measured: $t"
}
toast_gap_rect_between_first_two() {
  local first second
  first="$(ipc smoke toastWindowGeometry 0)" || return
  second="$(ipc smoke toastWindowGeometry 1)" || return
  python3 - "$first" "$second" <<'PY'
import json, sys
first, second = [json.loads(v) for v in sys.argv[1:]]
if not isinstance(first, list) or not isinstance(second, list):
    sys.exit(1)
top = first[1] + first[3]
height = second[1] - top
if height <= 0:
    sys.exit(1)
print(json.dumps([first[0], top, first[2], height]))
PY
}
toast_card_rect_first() {
  local first
  first="$(ipc smoke toastWindowGeometry 0)" || return
  python3 -c 'import json,sys; first=json.loads(sys.argv[1]); print(json.dumps(first)) if isinstance(first, list) else sys.exit(1)' "$first"
}
point_in_layer() { # X Y
  layers_of vgs:toast | py_reply 'import json,sys
layers = json.load(sys.stdin)
x, y = map(int, sys.argv[1:3])
print(any(l[0] <= x < l[0] + l[2] and l[1] <= y < l[1] + l[3] for l in layers))' "$1" "$2"
}
point_in_surface_rect() { # X Y RECT_JSON
  local layer
  layer="$(surface_box vgs:toast)" || return
  python3 -c 'import json,sys
layer, rect = json.loads(sys.argv[1]), json.loads(sys.argv[4])
x, y = map(int, sys.argv[2:4])
left, top = layer[0] + rect[0], layer[1] + rect[1]
print(left <= x < left + rect[2] and top <= y < top + rect[3])' "$layer" "$1" "$2" "$3"
}

# An earlier row left the fixture disabled; its service is the consumer here.
layers_dir="$home/.config/vgs/plugins/acme.layers"
mkdir -p "$layers_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.layers/." "$layers_dir/"
expect "rescan after adding the layers fixture for toast mask checks answers ok" ok ipc shell rescanPlugins
expect_poll "the layers fixture for toast mask checks is discovered" True plugin_known acme.layers
expect "enabling the layers fixture for toast mask checks is allowed" ok ipc shell setPluginEnabled acme.layers true
expect_poll "the layers fixture service for toast mask checks is built" True record_exists acme.layers
expect "the layer under the toasts is shown" ok layered draw
expect "the layer under the toasts takes input everywhere" ok layered full 1
expect "enabling the fixture for the toast rows is allowed" ok ipc shell setPluginEnabled acme.probe true
expect_poll "the fixture service is back" True record_exists acme.probe
expect "no toast shows at first" '[]' toast_titles visible
expect "the toast host has no surface at first" 0 layer_count vgs:toast
expect "a service shows a toast" ok toast "Saved|success|0"
expect "the shown toast is in the lending record under its plugin" '[{"plugin": "acme.probe", "title": "Saved", "tone": "success"}]' py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["toasts"]["visible"]))' < <(ipc shell lent)
expect_poll "the toast host maps one surface" 1 layer_count vgs:toast
expect "the toast sits on the focused screen" "$(bar_key | sed 's/^bar://')" toast_screen
toast_margin="$(ipc smoke themeValue toast.margin)"
geometry expect "the toast surface sits below the bar in the top-right corner" "[[$((mon_w - toast_margin - 360)), $((bar_reserved + toast_margin)), 360, $(toast_surface_height)]]" layers_of vgs:toast
expect "the layer/bar overlap predicate rejects an overlap" "violation overlap" layer_bar_contract_value <<<"layer=1400,10,360,44 bar=0,0,$mon_w,$bar_reserved margin=$toast_margin"
geometry expect "the toast surface clears the bar by the toast margin" ok layer_bar_clear vgs:toast toast.margin
expect "enabling Settings for the toast click-through check is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect_poll "the Settings widget is on the bar for the toast click-through check" True record_exists vgs.settings
click_centre "$(bar_key)" vgs.settings || fail "the right-side Settings widget receives a click while a toast shows"
expect_poll "the right-side Settings widget opens while a toast shows" open settings_open
expect "the Settings window hides after the toast click-through check" ok ipc shell hide window vgs.settings
expect_poll "the Settings window is gone after the toast click-through check" closed settings_open
expect "disabling Settings after the toast click-through check is allowed" ok ipc shell setPluginEnabled vgs.settings false
note_toast_bar_geometry

# The stack shows three; the fourth waits and shows when one ends.
expect "a second toast shows" ok toast "Two|info|0"
gap_rect="$(toast_gap_rect_between_first_two)" || fail "the gap between two toasts was not measured"
read -r gap_x gap_y < <(at_centre vgs:toast "$gap_rect") || fail "the gap between two toasts was not translated"
expect "the gap point is inside the toast layer" True point_in_layer "$gap_x" "$gap_y"
presses="$(read_layers presses)"
click "$gap_x" "$gap_y" || fail "the click in the gap between toasts failed"
expect_poll "a click in the gap between two toasts reaches the layer below" "$((presses + 1))" read_layers presses
card_rect="$(toast_card_rect_first)" || fail "the first toast was not measured"
read -r card_x card_y < <(at_centre vgs:toast "$card_rect") || fail "the first toast was not translated"
expect "the card point is inside the first toast rectangle" True point_in_surface_rect "$card_x" "$card_y" "$card_rect"
click "$card_x" "$card_y" || fail "the click inside a toast card failed"
expect "control: a click inside a toast card does not reach the layer below" "$((presses + 1))" read_layers presses
expect "a third toast shows" ok toast "Three|warning|0"
expect "a fourth toast is queued" ok toast "Four||0"
expect "three toasts show" '["Saved", "Two", "Three"]' toast_titles visible
expect "the fourth waits" '["Four"]' toast_titles waiting
expect "a plugin's disposer ends its toast" ok ipc acme.probe invoke untoast Two
expect "the waiting toast took the freed slot" '["Saved", "Three", "Four"]' toast_titles visible
expect "the queue is empty" '[]' toast_titles waiting
expect "a disposer run twice changes nothing" ok ipc acme.probe invoke untoast Saved
expect "the record lost the disposed toast" '["Three", "Four"]' toast_titles visible

# The close button runs the same release, through the compositor's pointer.
# The button's rectangle is in its window's coordinates; the window's origin
# comes from the compositor's layer list.
read -r cx cy cw ch < <(ipc smoke toastCloseGeometry 0 | py_reply 'import json,sys; print(*json.load(sys.stdin))')
read -r lx ly < <(layers_of vgs:toast | py_reply 'import json,sys; l=json.load(sys.stdin)[0]; print(l[0], l[1])')
click "$((lx + cx + cw / 2))" "$((ly + cy + ch / 2))" || fail "the click on the close button failed"
expect_poll "the close button ends the first toast" '["Four"]' toast_titles visible

# A duration expires the toast; the timer starts when it shows.
expect "a short toast shows" ok toast "Brief||300"
expect_poll "the short toast expired on its own" '["Four"]' toast_titles visible

# Refusals: malformed options and a full stack.
expect "a toast without a title is refused" "refused: toast=title must be a string of 1 to 120 characters" toast "|success"
expect "a toast with an unknown tone is refused" "refused: toast=tone must be one of neutral, accent, success, warning, danger, info" toast "T|loud"
for i in $(seq 1 22); do toast "Fill $i||0" >/dev/null; done
expect "the stack past its ceiling refuses" "refused: toasts=full limit=23" toast "Over||0"
expect "the ceiling holds the record at its limit" 20 py_reply 'import json,sys; print(len(json.load(sys.stdin)["toasts"]["waiting"]))' < <(ipc shell lent)
expect "the layer under the toasts is hidden after mask checks" ok layered undraw
expect "disabling the layers fixture after toast mask checks is allowed" ok ipc shell setPluginEnabled acme.layers false
expect_poll "the layers fixture after toast mask checks is gone" False record_exists acme.layers

# Disabling the plugin releases every toast it holds and the surface.
expect "disabling the fixture is allowed" ok ipc shell setPluginEnabled acme.probe false
expect_poll "a disabled plugin's toasts are released" '[]' toast_titles visible
expect "its waiting toasts are released too" '[]' toast_titles waiting
expect_poll "the toast host destroyed its surface" 0 layer_count vgs:toast
expect "re-enabling the fixture is allowed" ok ipc shell setPluginEnabled acme.probe true
expect_poll "the fixture is back" True plugin_enabled acme.probe
