# Passive layers, drawn by the fixture service through its `layers`
# capability and read back from the compositor's layer list, the core's
# lending record, the fixture and the probe. One surface per screen, on the
# overlay layer, clear of reserved space, taking no keyboard focus; pointer
# input reaches the content only where it says; a screen added or removed
# gains or loses its surface; the disposer and a disable release every one.
set -euo pipefail
layers_dir="$home/.config/vgs/plugins/acme.layers"
mkdir -p "$layers_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.layers/." "$layers_dir/"
# JSON the shell answers, respaced as python prints it, so a row compares values.
respaced() { "$@" | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)))'; }
built_screens() { respaced read_layers built; }
lent_layers() { ipc shell lent | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["layers"]))'; }
on_overlay() { hypr -j layers | py_reply 'import json,sys; print(sum(1 for m in json.load(sys.stdin).values() for l in m["levels"].get("3", []) if l["namespace"]=="vgs:layer" and l["pid"]!=-1))'; }
screen_names() { hypr -j monitors | py_reply 'import json,sys; print(json.dumps(sorted(m["name"] for m in json.load(sys.stdin))))'; }

expect "rescan after adding the layers fixture answers ok" ok ipc shell rescanPlugins
expect_poll "the layers fixture is discovered" True plugin_known acme.layers
expect "enabling the layers fixture is allowed" ok ipc shell setPluginEnabled acme.layers true
expect_poll "the layers fixture's service is built" True record_exists acme.layers
expect "no layer surface exists before a show" 0 layer_count vgs:layer
expect "the lending record lists no layer" '[]' lent_layers

expect "the fixture shows a layer" ok layered draw
expect_poll "the layer host maps one surface per screen" "$monitors" layer_count vgs:layer
expect "every layer surface is on the overlay layer" "$monitors" on_overlay
expect_poll "every copy of the content received its screen" "$(screen_names)" built_screens
screen_json="$(screen_names)"
expect "the lending record lists the layer under its plugin and screens" "[{\"plugin\": \"acme.layers\", \"screens\": $screen_json}]" lent_layers
surfaces_want="$(python3 -c 'import json,sys; print(json.dumps([[n, True, True, True] for n in json.loads(sys.argv[1])]))' "$screen_json")"
expect "every surface takes no keyboard, sits on the overlay layer and clears reserved space" "$surfaces_want" respaced ipc smoke layerSurfaces acme.layers
read -r mon_w mon_h bar_reserved < <(monitor_size)
geometry expect_poll "the surface covers the screen below the bar's reserved space" "[[0, $bar_reserved, $mon_w, $((mon_h - bar_reserved))]]" layers_of vgs:layer

# Every reading counts press AND release on both the layer and a real xdg
# client below it. An unchanged layer counter cannot prove pass-through:
# an oversized mask with no handler below the point could swallow input.
# layer_input_begin RECEIVER X Y stores the expected change before clicking;
# layer_input_result is the same assertion for positive rows and controls.
# RECEIVER is left, right, layer (outside either pad under inputAll), client.
layer_input_sample() {
  local events down up
  events="$(read_layers events)" && down="$(other_events '^button 272 pressed$')" && up="$(other_events '^button 272 released$')" || return 1
  python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]) + [int(sys.argv[2]), int(sys.argv[3])]))' "$events" "$down" "$up"
}
layer_input_begin() {
  input_before="$(layer_input_sample)" || return 1
  input_want="$(python3 -c '
import json,sys
values = json.loads(sys.argv[1])
increments = {"left": [1,1,1,0,0,0], "right": [1,1,0,1,0,0], "layer": [1,1,0,0,0,0], "client": [0,0,0,0,1,1]}
print(json.dumps([v+d for v,d in zip(values, increments[sys.argv[2]])]))' "$input_before" "$1")" || return 1
  hover "$(($2 - 1))" "$3" && click "$2" "$3"
}
layer_input_result() {
  local got
  got="$(layer_input_sample)" || return 1
  [[ $got == "$input_want" ]] && echo ok || echo violation
}

left_x=40 right_x=200 gap_x=120 pad_y=$((bar_reserved + 20))
away_x=$((mon_w / 2)) away_y=$((mon_h / 2))
if ! open_other "$sandbox/toplevel-layers.log"; then fail "the client below the passive layer maps"; exit 1; fi
client_focused='["smoke.other", "Other window"]'
expect_poll "the client below the passive layer has keyboard focus" "$client_focused" active_window
for point in "left $left_x $pad_y" "right $right_x $pad_y" "client $gap_x $pad_y" "client $away_x $away_y"; do
  read -r receiver x y <<<"$point"
  layer_input_begin "$receiver" "$x" "$y" || { fail "the $receiver input check could not click"; exit 1; }
  expect_poll "the $receiver receives press and release at $x,$y, and the other receiver gets neither" ok layer_input_result
done
expect "pressing a passive layer leaves the keyboard on the client" "$client_focused" active_window

client_keys_before="$(other_events '^key [0-9]+ released$')" || fail "the client key count is unreadable"
type_keys z || fail "typing while the passive layer is mapped failed"
expect_poll "a passive layer leaves typed keys on the client" "$((client_keys_before + 1))" other_events '^key [0-9]+ released$'

expect "the content can take input on its whole surface" ok layered full 1
layer_input_begin layer "$gap_x" "$pad_y" || { fail "the full-layer gap click failed"; exit 1; }
expect_poll "inputAll catches press and release in the gap instead of the client" ok layer_input_result
expect "the content returns to its pads" ok layered full 0
expect "the content removes its input items" ok layered pads 0
layer_input_begin client "$left_x" "$pad_y" || { fail "the empty-list click failed"; exit 1; }
expect_poll "an empty input list passes press and release through a former pad" ok layer_input_result
expect "inputAll can override an empty list" ok layered full 1
layer_input_begin layer "$gap_x" "$pad_y" || { fail "the empty full-layer click failed"; exit 1; }
expect_poll "inputAll still catches input with an empty list" ok layer_input_result
expect "the empty surface returns to pass-through" ok layered full 0
expect "the content adds only the left pad" ok layered pads 1
layer_input_begin left "$left_x" "$pad_y" || { fail "the single-pad click failed"; exit 1; }
expect_poll "adding one input item gives its pad input" ok layer_input_result
layer_input_begin client "$right_x" "$pad_y" || { fail "the removed-pad click failed"; exit 1; }
expect_poll "the removed right pad passes press and release to the client" ok layer_input_result
expect "the content restores both pads" ok layered pads 2
layer_input_begin right "$right_x" "$pad_y" || { fail "the restored-pad click failed"; exit 1; }
expect_poll "adding the right item restores input to that pad" ok layer_input_result

# Remove the host's forwarding binding in its sandbox instance. The click
# must reach the client before the normal layer assertion is read as red.
expect "control: the probe removes the host's delivered input items" ok ipc smoke layerInputDrop acme.layers
layer_input_begin left "$left_x" "$pad_y" || { fail "the host forwarding control could not click"; exit 1; }
client_up="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[5]+1)' "$input_before")"
expect_poll "control: the missing host binding sends the pad click to the client" "$client_up" other_events '^button 272 released$'
expect "control: the missing host binding breaks the shared input assertion" violation layer_input_result
expect "a redraw restores the host's input binding" ok layered redraw
expect_poll "the redrawn layer maps again" "$monitors" layer_count vgs:layer
layer_input_begin left "$left_x" "$pad_y" || { fail "the restored host click failed"; exit 1; }
expect_poll "the restored host binding passes the shared input assertion" ok layer_input_result

# The harness prepares the mask copies before shell startup, so Qt's
# directory cache sees every file. Each mutant removes a mask behavior,
# not the test or its fixture. The real layer is released after the copy
# maps; it cannot catch a click a mutant wrongly lets through.
expect "the original registration is released before mask controls" ok layered undraw
expect_poll "the original layer is gone before mask controls" 0 layer_count vgs:layer
python3 - "$repo/scripts/smoke/toplevel/toplevel.c" "$sandbox/toplevel-silent.c" <<'PY'
from pathlib import Path
import sys
helper, silent = map(Path, sys.argv[1:])
text = helper.read_text()
old = 'printf("button %u %s\\n", button, state == WL_POINTER_BUTTON_STATE_PRESSED ? "pressed" : "released");'
assert text.count(old) == 1, "button observer mutation must match once"
changed = text.replace(old, old.replace('"button ', '"unobserved-button '))
assert changed != text
silent.write_text(changed)
PY
for control in "NoLeft left $left_x client" "NoRight right $right_x client" "NoMask client $gap_x layer"; do
  read -r name wanted x actual <<<"$control"
  expect "control: the fixture registers content for $name" ok layered draw
  expect_poll "control: the original content is built before $name" "$screen_json" built_screens
  expect "control: the probe loads $name with the real layer content" ok ipc smoke layerSurfaceLoad "$name" "$repo/shell/Hosts/OverlaySurface$name.qml" acme.layers
  expect_poll "control: the $name surface maps" 1 layer_count vgs:layer-control
  expect "control: the original layer is released beside $name" ok layered undraw
  expect_poll "control: no original layer can catch input beside $name" 0 layer_count vgs:layer
  layer_input_begin "$wanted" "$x" "$pad_y" || { fail "the $name control could not click"; exit 1; }
  if [[ $actual == client ]]; then
    client_up="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[5]+1)' "$input_before")"
    expect_poll "control: $name sends the pad's release to the client" "$client_up" other_events '^button 272 released$'
  else
    layer_up="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[1]+1)' "$input_before")"
    expect_poll "control: $name catches the gap's release on the layer" "$layer_up" read_layers releases
  fi
  expect "control: $name breaks the shared input assertion" violation layer_input_result
  expect "control: the probe drops $name" ok ipc smoke popupDrop "$name"
  expect_poll "control: the $name surface is destroyed" 0 layer_count vgs:layer-control
done
expect "the fixture shows the original layer after mask controls" ok layered draw
expect_poll "the original layer maps after mask controls" "$monitors" layer_count vgs:layer

# The receiver is also controlled: a copy that hides button events cannot
# pass the same client assertion. A key round trip proves the client has
# processed input before testing its absent button record.
close_other "the pointer-observing client exits after the mask controls"
cp "$sandbox/toplevel" "$sandbox/toplevel-observing"
build_helper toplevel toplevel "$sandbox/toplevel-silent.c" "$repo/scripts/smoke/toplevel/xdg-shell.xml"
if ! open_other "$sandbox/toplevel-layers-silent.log"; then fail "the silent client maps"; exit 1; fi
expect_poll "the silent client has keyboard focus" "$client_focused" active_window
layer_input_begin client "$gap_x" "$pad_y" || { fail "the silent receiver control could not click"; exit 1; }
type_keys x || { fail "the silent receiver control could not type its marker"; exit 1; }
expect_poll "control: the silent client processes the key after the gap click" 1 other_events '^key [0-9]+ released$'
expect "control: a receiver with no button record breaks the shared input assertion" violation layer_input_result
close_other "the silent receiver exits after its control"
mv "$sandbox/toplevel-observing" "$sandbox/toplevel"

# A screen that comes gains the layer; one that goes takes it along.
layer_output=SMOKE-LAYER
expect "the nested compositor adds a monitor for the layer rows" ok hypr output create headless "$layer_output"
expect_poll "the new monitor gets its own layer surface" "$((monitors + 1))" layer_count vgs:layer
expect_poll "the new screen's copy received its screen" "$(screen_names)" built_screens
expect "the nested compositor removes that monitor" ok hypr output remove "$layer_output"
expect_poll "the removed monitor's layer surface is gone" "$monitors" layer_count vgs:layer
expect_poll "the removed screen's copy was destroyed" "$screen_json" built_screens
expect_poll "the lending record forgot the removed screen" "[{\"plugin\": \"acme.layers\", \"screens\": $screen_json}]" lent_layers

# Refusals: something that is no component, and a content with no screen.
expect "showing something that is no component is refused" "refused: layers=not-a-component" layered bad
expected_errors+=('layers: acme\.layers content not built on [^:]+: .*screen')
expect "a content without a screen property is shown" ok layered bare
expect_log "the host logs the content it did not build" 1 'layers: acme\.layers content not built on [^:]+: .*screen'
expect "the refused content maps no surface" "$monitors" layer_count vgs:layer
expect "releasing the refused content is allowed" ok layered unbare

# A registration that ends as another begins, in one call, leaves the new
# one built on every screen and recorded there.
expect "the fixture releases and registers again at once" ok layered redraw
expect_poll "the new registration has one surface per screen" "$monitors" layer_count vgs:layer
expect_poll "every copy of the new registration received its screen" "$screen_json" built_screens
expect_poll "the lending record lists the new registration on every screen" "[{\"plugin\": \"acme.layers\", \"screens\": $screen_json}]" lent_layers

# The disposer and a disable release every surface.
expect "the fixture's disposer hides the layer" ok layered undraw
expect_poll "the disposer destroyed every layer surface" 0 layer_count vgs:layer
expect_poll "every content copy was destroyed" '[]' built_screens
expect "the lending record lists no layer after the disposer" '[]' lent_layers
expect "the fixture shows its layer again" ok layered draw
expect_poll "the layer is back on every screen" "$monitors" layer_count vgs:layer
expect "disabling the layers fixture is allowed" ok ipc shell setPluginEnabled acme.layers false
expect_poll "a disabled plugin's layer surfaces are gone" 0 layer_count vgs:layer
expect "a disabled plugin holds no layer" '[]' lent_layers
expect "a disabled plugin holds no layers capability" null lent holders.layers
