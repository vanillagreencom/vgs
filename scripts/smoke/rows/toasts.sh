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

# An earlier row left the fixture disabled; its service is the consumer here.
expect "enabling the fixture for the toast rows is allowed" ok ipc shell setPluginEnabled acme.probe true
expect_poll "the fixture service is back" True record_exists acme.probe
expect "no toast shows at first" '[]' toast_titles visible
expect "the toast host has no surface at first" 0 layer_count vgs:toast
expect "a service shows a toast" ok toast "Saved|success|0"
expect "the shown toast is in the lending record under its plugin" '[{"plugin": "acme.probe", "title": "Saved", "tone": "success"}]' python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["toasts"]["visible"]))' < <(ipc shell lent)
expect_poll "the toast host maps one surface" 1 layer_count vgs:toast
expect "the toast sits on the focused screen" "$(bar_key | sed 's/^bar://')" toast_screen
geometry expect "the toast surface sits in the top-right corner" "[[$((mon_w - 12 - 360)), 12, 360, $(toast_surface_height)]]" layers_of vgs:toast

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
