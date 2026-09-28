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
layered() { ipc acme.layers invoke "$1" "${2:-}"; }
read_layers() { ipc smoke readInstance service acme.layers "$1"; }
# JSON the shell answers, respaced as python prints it, so a row compares values.
respaced() { "$@" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))'; }
built_screens() { respaced read_layers built; }
lent_layers() { ipc shell lent | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["layers"]))'; }
on_overlay() { hypr -j layers | python3 -c 'import json,sys; print(sum(1 for m in json.load(sys.stdin).values() for l in m["levels"].get("3", []) if l["namespace"]=="vgs:layer" and l["pid"]!=-1))'; }
screen_names() { hypr -j monitors | python3 -c 'import json,sys; print(json.dumps(sorted(m["name"] for m in json.load(sys.stdin))))'; }

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

# The content's pad is its input: a press there reaches it, a press
# elsewhere passes through; with `inputAll` the whole surface takes it.
pad_x=40 pad_y=$((bar_reserved + 20)) away_x=$((mon_w / 2)) away_y=$((mon_h / 2))
presses="$(read_layers presses)"
click "$pad_x" "$pad_y" || fail "the click on the layer's pad failed"
expect_poll "a press on the input item reaches the content" "$((presses + 1))" read_layers presses
click "$away_x" "$away_y" || fail "the click beside the layer's pad failed"
# A press that passes through leaves nothing to wait for; the next press on
# the pad is the marker that the earlier one has been delivered.
click "$pad_x" "$pad_y" || fail "the second click on the layer's pad failed"
expect_poll "a press outside the input item passes through the surface" "$((presses + 2))" read_layers presses
expect "the content can take input on its whole surface" ok layered full 1
click "$away_x" "$away_y" || fail "the click on the full surface failed"
expect_poll "with inputAll a press anywhere reaches the content" "$((presses + 3))" read_layers presses
expect "the content returns to its pad" ok layered full 0

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
