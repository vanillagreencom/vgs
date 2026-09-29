# Toasts, shown by the fixture service through its `toasts` capability and
# read back from the core's lending record, the compositor's layer list and
# the host. Every way a toast ends runs one release: expiry, the user's
# click on its close button, the disposer the plugin holds and the
# instance's teardown.
set -euo pipefail
toast() { ipc acme.probe invoke toast "$1"; }
toast_titles() { ipc shell lent | python3 -c 'import json,sys; t=json.load(sys.stdin)["toasts"]; print(json.dumps([e["title"] for e in t[sys.argv[1]]]))' "$1"; }
toast_screen() { ipc shell lent | python3 -c 'import json,sys; print(json.load(sys.stdin)["toasts"]["screen"])'; }
toast_surface_height() { layers_of vgs:toast | python3 -c 'import json,sys; l=json.load(sys.stdin); print(l[0][3] if l else 0)'; }
settings_open() { [[ $(ipc smoke instanceGeometry window vgs.settings) != absent ]] && echo open || echo closed; }
toast_bar_geometry() {
  local toast_layers bar_layers margin
  toast_layers="$(layers_of vgs:toast)" || return
  bar_layers="$(layers_of vgs:bar)" || return
  margin="$(ipc smoke themeValue toast.margin)" || return
  python3 - "$toast_layers" "$bar_layers" "$margin" <<'PY'
import json, sys
toasts, bars, margin = json.loads(sys.argv[1]), json.loads(sys.argv[2]), int(json.loads(sys.argv[3]))
if not toasts or not bars:
    print("absent")
    sys.exit()
print("toast=%d,%d,%d,%d bar=%d,%d,%d,%d margin=%d" % (*toasts[0], *bars[0], margin))
PY
}
toast_bar_contract_value() {
  python3 -c 'import re,sys
t = sys.stdin.read().strip()
m = re.fullmatch(r"toast=(\d+),(\d+),(\d+),(\d+) bar=(\d+),(\d+),(\d+),(\d+) margin=(\d+)", t)
if not m: print(t); sys.exit()
tx, ty, tw, th, bx, by, bw, bh, margin = map(int, m.groups())
horizontal = tx < bx + bw and bx < tx + tw
vertical = ty < by + bh and by < ty + th
problems = []
if horizontal and vertical:
    problems.append("overlap")
elif horizontal:
    gap = ty - (by + bh) if by < ty else by - (ty + th)
    if gap < margin:
        problems.append("margin")
print("ok" if not problems else "violation " + ",".join(problems))'
}
toast_bar_clear() {
  local t
  t="$(toast_bar_geometry)" || return
  toast_bar_contract_value <<<"$t"
}
note_toast_bar_geometry() {
  local t
  t="$(toast_bar_geometry)" || { fail "toast geometry unreadable"; return; }
  ok "toast geometry measured: $t"
}

# An earlier row left the fixture disabled; its service is the consumer here.
expect "enabling the fixture for the toast rows is allowed" ok ipc shell setPluginEnabled acme.probe true
expect_poll "the fixture service is back" True record_exists acme.probe
expect "no toast shows at first" '[]' toast_titles visible
expect "the toast host has no surface at first" 0 layer_count vgs:toast
expect "a service shows a toast" ok toast "Saved|success|0"
expect "the shown toast is in the lending record under its plugin" '[{"plugin": "acme.probe", "title": "Saved", "tone": "success"}]' python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["toasts"]["visible"]))' < <(ipc shell lent)
expect_poll "the toast host maps one surface" 1 layer_count vgs:toast
expect "the toast sits on the focused screen" "$(bar_key | sed 's/^bar://')" toast_screen
toast_margin="$(ipc smoke themeValue toast.margin)"
geometry expect "the toast surface sits below the bar in the top-right corner" "[[$((mon_w - toast_margin - 360)), $((bar_reserved + toast_margin)), 360, $(toast_surface_height)]]" layers_of vgs:toast
expect "the toast/bar overlap predicate rejects an overlap" "violation overlap" toast_bar_contract_value <<<"toast=1400,10,360,44 bar=0,0,$mon_w,$bar_reserved margin=$toast_margin"
geometry expect "the toast surface clears the bar by the toast margin" ok toast_bar_clear
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
read -r cx cy cw ch < <(ipc smoke toastCloseGeometry 0 | python3 -c 'import json,sys; print(*json.load(sys.stdin))')
read -r lx ly < <(layers_of vgs:toast | python3 -c 'import json,sys; l=json.load(sys.stdin)[0]; print(l[0], l[1])')
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
expect "the ceiling holds the record at its limit" 20 python3 -c 'import json,sys; print(len(json.load(sys.stdin)["toasts"]["waiting"]))' < <(ipc shell lent)

# Disabling the plugin releases every toast it holds and the surface.
expect "disabling the fixture is allowed" ok ipc shell setPluginEnabled acme.probe false
expect_poll "a disabled plugin's toasts are released" '[]' toast_titles visible
expect "its waiting toasts are released too" '[]' toast_titles waiting
expect_poll "the toast host destroyed its surface" 0 layer_count vgs:toast
expect "re-enabling the fixture is allowed" ok ipc shell setPluginEnabled acme.probe true
expect_poll "the fixture is back" True plugin_enabled acme.probe
