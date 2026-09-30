# Hosts: a fixture of every summonable kind plus a background and a bar
# widget. Each summonable kind opens on demand, in its own layer surface
# without an anchor or as a popup of its anchor's window with one, and is
# destroyed on hide; a window is a Hyprland window with or without an
# anchor. The background is drawn on every screen while enabled. Layer
# geometry is read from the compositor's layer list, window geometry from
# its client list, popup geometry from the built instance.
set -euo pipefail
surf="$home/.config/vgs/plugins/acme.surfaces"
mkdir -p "$surf"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.surfaces/." "$surf/"
expect "rescan after adding the hosts fixture answers ok" ok ipc shell rescanPlugins
expect_poll "the hosts fixture is discovered" True plugin_known acme.surfaces
expect_poll "enabling the hosts fixture is allowed" ok ipc shell setPluginEnabled acme.surfaces true

screen_name="$(bar_key | sed 's/^bar://')"

expect_poll "the background host draws one surface per screen" "$monitors" layer_count vgs:background
expect "the background sits on the bottom layer" True py_reply 'import json,subprocess,sys; print(any(l["namespace"]=="vgs:background" and l["pid"]!=-1 for m in json.loads(sys.stdin.read()).values() for l in m["levels"]["0"]))' < <(hypr -j layers)
expect "the background receives its screen" "\"$screen_name\"" ipc smoke readInstance "background:$screen_name" acme.surfaces screenName

expect "a panel summons over IPC" ok ipc shell summon panel acme.surfaces '{"n":1}'
expect "the panel received its payload" '"{\"n\":1}"' ipc smoke readInstance panel acme.surfaces lastPayload
expect_poll "the panel host maps one surface" 1 layer_count vgs:panel
geometry expect_poll "the panel takes its top-right placement below the bar" "[[$((mon_w - 8 - 200)), $((bar_reserved + 8)), 200, 120]]" layers_of vgs:panel
if before="$(builds)"; then
  expect "summoning an open panel is allowed" ok ipc shell summon panel acme.surfaces '{"n":2}'
  expect "the open panel received the new payload" 2 ipc smoke readInstance panel acme.surfaces opened
  expect "summoning an open panel builds nothing" "$before" builds
else
  fail "buildCount unreadable before the summon rows"
fi
expect "summoning with a close marker is allowed" ok ipc shell summon panel acme.surfaces "{\"closeMarker\":\"$sandbox/closed-by-hide\"}"
expect "hiding the panel is allowed" ok ipc shell hide panel acme.surfaces
marker() { [[ -f $1 ]] && echo yes || echo no; }
expect_poll "hide called the panel's close()" yes marker "$sandbox/closed-by-hide"
expect "the hidden panel leaves the build records" absent ipc smoke readInstance panel acme.surfaces opened
expect_poll "the panel host destroyed its surface" 0 layer_count vgs:panel
expect "toggle opens a closed panel" ok ipc shell toggle panel acme.surfaces '{}'
expect_poll "the toggled panel is mapped" 1 layer_count vgs:panel
expect "toggle closes an open panel" ok ipc shell toggle panel acme.surfaces '{}'
expect_poll "the toggled panel is gone" 0 layer_count vgs:panel

expect "an overlay summons over IPC" ok ipc shell summon overlay acme.surfaces '{}'
geometry expect_poll "the overlay covers its screen" "[[0, 0, $mon_w, $mon_h]]" layers_of vgs:overlay
expect "hiding the overlay is allowed" ok ipc shell hide overlay acme.surfaces
expect_poll "the overlay host destroyed its surface" 0 layer_count vgs:overlay
expected_errors+=('summon host: acme\.surfaces open\(\) failed: probe open refused')
expect "an open() that throws refuses the summon" "refused: open-failed=acme.surfaces" ipc shell summon menu acme.surfaces '{"fail":true}'
expect_poll "the refused summon leaves no surface" 0 layer_count vgs:menu
expect "a menu summons over IPC" ok ipc shell summon menu acme.surfaces '{}'
expect_poll "the menu host maps one surface" 1 layer_count vgs:menu
expect "hiding the menu is allowed" ok ipc shell hide menu acme.surfaces
expect_poll "the menu host destroyed its surface" 0 layer_count vgs:menu

# An application window: a client of the shell's class titled with the
# plugin's name, at the size the instance asks, whatever the plugin's
# placement setting. Summoning an open one hands it the new payload and
# builds nothing; hide and a close through Hyprland each call close() and
# destroy it; an anchored summon builds a window all the same.
window_size() { window_of Surfaces size; }
expect "a window summons over IPC" ok ipc shell summon window acme.surfaces '{"n":1}'
expect "the window received its payload" '"{\"n\":1}"' ipc smoke readInstance window acme.surfaces lastPayload
expect_poll "the window host maps one window titled with the plugin's name" 1 window_count Surfaces
geometry expect_poll "the window asks for the instance's size, whatever its placement setting" '[[200, 120]]' window_size
expect "the window host maps no layer surface" 0 layer_count vgs:window
if before="$(builds)"; then
  expect "summoning an open window is allowed" ok ipc shell summon window acme.surfaces '{"n":2}'
  expect "the open window received the new payload" 2 ipc smoke readInstance window acme.surfaces opened
  expect "summoning an open window builds nothing" "$before" builds
else
  fail "buildCount unreadable before the window rows"
fi
expect "summoning the window with a close marker is allowed" ok ipc shell summon window acme.surfaces "{\"closeMarker\":\"$sandbox/window-closed-by-hide\"}"
expect "hiding the window is allowed" ok ipc shell hide window acme.surfaces
expect_poll "hide called the window's close()" yes marker "$sandbox/window-closed-by-hide"
expect_poll "the window host destroyed the window" 0 window_count Surfaces
expect "toggle opens a closed window" ok ipc shell toggle window acme.surfaces '{}'
expect_poll "the toggled window is mapped" 1 window_count Surfaces
expect "toggle closes an open window" ok ipc shell toggle window acme.surfaces '{}'
expect_poll "the toggled window is gone" 0 window_count Surfaces
expect "the widget summons its window with itself as the anchor" ok ipc smoke invokeInstance "bar:$screen_name" acme.surfaces windowHere "{\"closeMarker\":\"$sandbox/window-closed-by-hyprland\"}"
expect_poll "an anchored window summon maps a window" 1 window_count Surfaces
expect "an anchored window summon maps no popup panel" absent ipc smoke readInstance panel acme.surfaces opened
if surfaces_address="$(window_of Surfaces address)" && [[ $surfaces_address == \[\"0x* ]]; then
  surfaces_address="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0])' "$surfaces_address")"
  expect "a close dispatch aimed at the window answers ok" ok hypr dispatch "hl.dsp.window.close({ window = \"address:$surfaces_address\" })"
  expect_poll "a close through Hyprland called the window's close()" yes marker "$sandbox/window-closed-by-hyprland"
  expect_poll "a close through Hyprland removed the window from the build records" absent ipc smoke readInstance window acme.surfaces opened
  expect_poll "a close through Hyprland left no window" 0 window_count Surfaces
else
  fail "the fixture window's address is unreadable: ${surfaces_address:-}"
fi

# Popup geometry is read from the instance through Item.mapToGlobal, which
# answers in the coordinates of the window the popup was anchored in, after
# the compositor's configure event; the anchor is read the same way, from
# the same window. A bar's window starts at the screen's top-left corner;
# a layer panel's origin is read from the compositor's layer list. A popup
# sits flush under its anchor, centred on it when that fits the screen;
# one that would not fit is the compositor's to slide, and the row asserts
# only that it stays on the screen and under its anchor.
popup_geometry() { ipc smoke invokeInstance "$1" acme.surfaces geometry ''; }
placed_below() { # POPUP_KIND ANCHOR_HOST ANCHOR_FUNCTION [WINDOW_X WINDOW_Y]
  local actual anchor
  actual="$(popup_geometry "$1")" || return
  anchor="$(ipc smoke invokeInstance "$2" acme.surfaces "$3" '')" || return
  # Answers `placed`, or the geometry read, so a failure names it.
  python3 - "$actual" "$anchor" "$mon_w" "${4:-0}" "${5:-0}" <<'PY'
import json, sys
x, y, w, h = json.loads(sys.argv[1])
ax, ay, aw, ah = json.loads(sys.argv[2])
mw, wx, wy = (int(v) for v in sys.argv[3:6])
centred = round(ax + aw / 2 - w / 2)
fits = 0 <= centred + wx and centred + wx + 200 <= mw
placed = (w, h, y) == (200, 120, ay + ah) and ((x == centred) if fits else (0 <= x + wx and x + wx + w <= mw and x < ax + aw and x + w > ax))
print("placed" if placed else "popup=%s anchor=%s centred=%s fits=%s" % (sys.argv[1], sys.argv[2], centred, fits))
PY
}
panel_origin() { layers_of vgs:panel | py_reply 'import json,sys; l=json.load(sys.stdin)[0]; print(l[0], l[1])'; }
expect "the widget summons its panel under itself" ok ipc smoke invokeInstance "bar:$screen_name" acme.surfaces summonHere ''
geometry expect_poll "the popup panel sits under its widget" placed placed_below panel "bar:$screen_name" geometry
expect "the anchored panel received the widget's payload" '"{\"from\":\"widget\"}"' ipc smoke readInstance panel acme.surfaces lastPayload
expect "the anchored panel uses no layer surface" 0 layer_count vgs:panel
expect "hiding the anchored panel is allowed" ok ipc shell hide panel acme.surfaces

expect "the unanchored panel opens for a nested menu" ok ipc shell summon panel acme.surfaces '{}'
expect_poll "the parent panel is mapped" 1 layer_count vgs:panel
read -r panel_x panel_y < <(panel_origin)
expect "the panel summons a menu from its own item" ok ipc smoke invokeInstance panel acme.surfaces menuHere '{}'
geometry expect_poll "the nested menu uses its parent's window coordinates" placed placed_below menu panel anchorGeometry "$panel_x" "$panel_y"
anchor_updates="$(log_lines 'summon popup: anchor updated for acme\.surfaces')" || fail "instance log unreadable: $instance_log"
expect "moving an anchor ancestor is allowed" ok ipc smoke invokeInstance panel acme.surfaces moveAnchor ''
expect_log "the host updates the popup's anchor for the moved ancestor" "$((anchor_updates + 1))" 'summon popup: anchor updated for acme\.surfaces'
render expect_poll "the popup follows its moving anchor ancestor" placed placed_below menu panel anchorGeometry "$panel_x" "$panel_y"
expect "hiding an anchor ancestor is allowed" ok ipc smoke invokeInstance panel acme.surfaces hideAnchor ''
expect_poll "hiding an anchor closes its popup" absent ipc smoke readInstance menu acme.surfaces opened
expect "hiding the parent panel is allowed" ok ipc shell hide panel acme.surfaces

expect "the rightmost widget opens a menu" ok ipc smoke invokeInstance "bar:$screen_name" acme.surfaces menuHere '{}'
geometry expect_poll "the menu at the screen edge stays fully on screen" placed placed_below menu "bar:$screen_name" geometry
expect "hiding the edge menu is allowed" ok ipc shell hide menu acme.surfaces

# An anchored surface takes a focus grab, so a click outside it closes it
# and calls the plugin's close(). The clicks go through the nested
# compositor's virtual pointer. The first click lands on the widget itself,
# as a user's would before its menu opens.
#
# Control: a SummonPopup copy without the grab, written beside the shipped
# file and built under the same widget as the host builds an anchored
# panel, stays open through the click that closes the menu. The shell
# reads both popups' events on one connection in order, so once the menu
# has closed the copy has had any dismissal the same click brought.
summon_copy="$repo/shell/Hosts/SummonPopupNoGrab.qml"
python3 - "$repo/shell/Hosts/SummonPopup.qml" "$summon_copy" <<'PYEDIT'
import pathlib, sys
source, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = source.read_text()
assert text.count("    grabFocus: true\n") == 1, "the SummonPopup grab must occur once"
target.write_text(text.replace("    grabFocus: true\n", "    grabFocus: false\n"))
PYEDIT
click_centre "bar:$screen_name" acme.surfaces || fail "the click on the widget failed"
expect "the probe builds the SummonPopup copy without the grab" ok ipc smoke popupLoad summon-nograb "$summon_copy" "bar:$screen_name" acme.surfaces '{"pluginId":"acme.surfaces","kind":"panel","request":{"anchor":"@instance","anchored":true,"payloadJson":"{}"}}'
expect_poll "the grabless copy has built its panel" 0 ipc smoke readInstance panel acme.surfaces opened
expect "the grabless copy's panel takes a payload" '' ipc smoke invokeInstance panel acme.surfaces open '{}'
expect_poll "the grabless copy is shown" true ipc smoke popupRead summon-nograb visible
expect "the widget opens a menu with a close marker" ok ipc smoke invokeInstance "bar:$screen_name" acme.surfaces menuHere "{\"closeMarker\":\"$sandbox/closed-by-click\"}"
expect_poll "the menu is open before the outside click" 1 ipc smoke readInstance menu acme.surfaces opened
click "$((mon_w / 2))" "$((mon_h / 2))" || fail "the click outside the menu failed"
expect_poll "the outside click called the menu's close()" yes marker "$sandbox/closed-by-click"
expect "the outside click leaves the grabless copy shown" true ipc smoke popupRead summon-nograb visible
expect "the probe drops the grabless copy" ok ipc smoke popupDrop summon-nograb
expect_poll "the grabless copy's panel leaves the build records" absent ipc smoke readInstance panel acme.surfaces opened
expect_poll "the outside click removed the menu from the build records" absent ipc smoke readInstance menu acme.surfaces opened
expect "the widget opens an anchored panel" ok ipc smoke invokeInstance "bar:$screen_name" acme.surfaces summonHere ''
expect_poll "the panel is open before the outside click" 1 ipc smoke readInstance panel acme.surfaces opened
click "$((mon_w / 2))" "$((mon_h / 2))" || fail "the click outside the panel failed"
expect_poll "the outside click closes an anchored panel too" absent ipc smoke readInstance panel acme.surfaces opened

# Replacing an open plugin runs open() on the replacement. A refusal must
# remove its surface just as a refusal during the first summon does.
expect "the panel opens before its source changes" ok ipc shell summon panel acme.surfaces '{}'
cp -- "$home/.config/vgs/plugins/acme.surfaces/Summoned.qml" "$sandbox/Summoned.good"
python3 - "$home/.config/vgs/plugins/acme.surfaces/Summoned.qml" <<'PYEDIT'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = 'if (JSON.parse(payloadJson).fail === true)'
assert s.count(old) == 1
p.write_text(s.replace(old, 'if (true)'))
PYEDIT
expect "the changed open plugin is rescanned" ok ipc shell rescanPlugins
expect_poll "a replacement whose open throws is removed" absent ipc smoke readInstance panel acme.surfaces opened
expect_poll "the refused replacement leaves no panel surface" 0 layer_count vgs:panel
mv -T -- "$sandbox/Summoned.good" "$home/.config/vgs/plugins/acme.surfaces/Summoned.qml"
scans_before_repair="$(scans_done)"
expect "the repaired surface plugin is rescanned" ok ipc shell rescanPlugins
expect_log "the repaired surface revision is available" "$((scans_before_repair + 1))" 'plugins: scan complete '

expect "the panel opens again for the disable check" ok ipc smoke invokeInstance "bar:$screen_name" acme.surfaces summonHere ''

expect "a background is not summonable" "refused: not-summonable=background" ipc shell summon background acme.surfaces '{}'
expect "a plugin without the kind is refused" "refused: kind=panel id=acme.tick" ipc shell summon panel acme.tick '{}'
expect "an unknown plugin is refused" "unknown: acme.nope" ipc shell summon panel acme.nope '{}'
expect "re-summoning with a close marker is allowed" ok ipc shell summon panel acme.surfaces "{\"closeMarker\":\"$sandbox/closed-by-disable\"}"
expect "disabling the hosts fixture is allowed" ok ipc shell setPluginEnabled acme.surfaces false
expect_poll "disabling closes its open panel" 0 layer_count vgs:panel
expect_poll "disabling called the panel's close()" yes marker "$sandbox/closed-by-disable"
expect_poll "disabling removes the background surface" 0 layer_count vgs:background
expect "a disabled plugin is not summoned" "refused: disabled=acme.surfaces" ipc shell summon panel acme.surfaces '{}'
