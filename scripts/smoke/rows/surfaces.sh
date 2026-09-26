# Hosts: a fixture of every summonable kind plus a background and a bar
# widget. Each summonable kind opens on demand, in its own layer surface
# without an anchor or as a popup of its anchor's window with one, and is
# destroyed on hide; the background is drawn on every screen while
# enabled. Layer geometry is read from the compositor's layer list, popup
# geometry from the built instance.
set -euo pipefail
surf="$home/.config/vgs/plugins/acme.surfaces"
mkdir -p "$surf"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.surfaces/." "$surf/"
expect "rescan after adding the hosts fixture answers ok" ok ipc shell rescanPlugins
surfaces_known() { ipc shell listPlugins | python3 -c 'import json,sys; print(any(p["id"]=="acme.surfaces" for p in json.load(sys.stdin)["plugins"]))'; }
expect_poll "the hosts fixture is discovered" True surfaces_known
expect_poll "enabling the hosts fixture is allowed" ok ipc shell setPluginEnabled acme.surfaces true

screen_name="$(bar_key | sed 's/^bar://')"

expect_poll "the background host draws one surface per screen" "$monitors" layer_count vgs:background
expect "the background sits on the bottom layer" True python3 -c 'import json,subprocess,sys; print(any(l["namespace"]=="vgs:background" and l["pid"]!=-1 for m in json.loads(sys.stdin.read()).values() for l in m["levels"]["0"]))' < <(hypr -j layers)
expect "the background receives its screen" "\"$screen_name\"" ipc shell readInstance "background:$screen_name" acme.surfaces screenName

expect "a panel summons over IPC" ok ipc shell summon panel acme.surfaces '{"n":1}'
expect "the panel received its payload" '"{\"n\":1}"' ipc shell readInstance panel acme.surfaces lastPayload
expect_poll "the panel host maps one surface" 1 layer_count vgs:panel
geometry expect_poll "the panel takes its top-right placement below the bar" "[[$((mon_w - 8 - 200)), $((bar_reserved + 8)), 200, 120]]" layers_of vgs:panel
if before="$(builds)"; then
  expect "summoning an open panel is allowed" ok ipc shell summon panel acme.surfaces '{"n":2}'
  expect "the open panel received the new payload" 2 ipc shell readInstance panel acme.surfaces opened
  expect "summoning an open panel builds nothing" "$before" builds
else
  fail "buildCount unreadable before the summon rows"
fi
expect "summoning with a close marker is allowed" ok ipc shell summon panel acme.surfaces "{\"closeMarker\":\"$sandbox/closed-by-hide\"}"
expect "hiding the panel is allowed" ok ipc shell hide panel acme.surfaces
marker() { [[ -f $1 ]] && echo yes || echo no; }
expect_poll "hide called the panel's close()" yes marker "$sandbox/closed-by-hide"
expect "the hidden panel leaves the build records" absent ipc shell readInstance panel acme.surfaces opened
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

# Popup geometry is read from the instance through Item.mapToGlobal, which
# answers in the coordinates of the window the popup was anchored in, after
# the compositor's configure event; the anchor is read the same way, from
# the same window. A bar's window starts at the screen's top-left corner;
# a layer panel's origin is read from the compositor's layer list. A popup
# sits flush under its anchor, centred on it when that fits the screen;
# one that would not fit is the compositor's to slide, and the row asserts
# only that it stays on the screen and under its anchor.
popup_geometry() { ipc shell invokeInstance "$1" acme.surfaces geometry ''; }
placed_below() { # POPUP_KIND ANCHOR_HOST ANCHOR_FUNCTION [WINDOW_X WINDOW_Y]
  local actual anchor
  actual="$(popup_geometry "$1")" || return
  anchor="$(ipc shell invokeInstance "$2" acme.surfaces "$3" '')" || return
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
panel_origin() { layers_of vgs:panel | python3 -c 'import json,sys; l=json.load(sys.stdin)[0]; print(l[0], l[1])'; }
expect "the widget summons its panel under itself" ok ipc shell invokeInstance "bar:$screen_name" acme.surfaces summonHere ''
geometry expect_poll "the popup panel sits under its widget" placed placed_below panel "bar:$screen_name" geometry
expect "the anchored panel received the widget's payload" '"{\"from\":\"widget\"}"' ipc shell readInstance panel acme.surfaces lastPayload
expect "the anchored panel uses no layer surface" 0 layer_count vgs:panel
expect "hiding the anchored panel is allowed" ok ipc shell hide panel acme.surfaces

expect "the unanchored panel opens for a nested menu" ok ipc shell summon panel acme.surfaces '{}'
expect_poll "the parent panel is mapped" 1 layer_count vgs:panel
read -r panel_x panel_y < <(panel_origin)
expect "the panel summons a menu from its own item" ok ipc shell invokeInstance panel acme.surfaces menuHere '{}'
geometry expect_poll "the nested menu uses its parent's window coordinates" placed placed_below menu panel anchorGeometry "$panel_x" "$panel_y"
anchor_updates="$(log_lines 'summon popup: anchor updated for acme\.surfaces')" || fail "instance log unreadable: $instance_log"
expect "moving an anchor ancestor is allowed" ok ipc shell invokeInstance panel acme.surfaces moveAnchor ''
expect_log "the host updates the popup's anchor for the moved ancestor" "$((anchor_updates + 1))" 'summon popup: anchor updated for acme\.surfaces'
render expect_poll "the popup follows its moving anchor ancestor" placed placed_below menu panel anchorGeometry "$panel_x" "$panel_y"
expect "hiding an anchor ancestor is allowed" ok ipc shell invokeInstance panel acme.surfaces hideAnchor ''
expect_poll "hiding an anchor closes its popup" absent ipc shell readInstance menu acme.surfaces opened
expect "hiding the parent panel is allowed" ok ipc shell hide panel acme.surfaces

expect "the rightmost widget opens a menu" ok ipc shell invokeInstance "bar:$screen_name" acme.surfaces menuHere '{}'
geometry expect_poll "the menu at the screen edge stays fully on screen" placed placed_below menu "bar:$screen_name" geometry
expect "hiding the edge menu is allowed" ok ipc shell hide menu acme.surfaces

# A menu takes a focus grab, so a click outside it closes it and calls the
# plugin's close(); a panel takes none and stays. The clicks go through the
# nested compositor's virtual pointer. The first click lands on the widget
# itself, as a user's would before its menu opens.
read -r widget_x widget_y widget_w widget_h < <(ipc shell invokeInstance "bar:$screen_name" acme.surfaces geometry '' | python3 -c 'import json,sys; print(*json.load(sys.stdin))')
expect "a click lands on the widget" "clicked $((widget_x + widget_w / 2)) $((widget_y + widget_h / 2))" click "$((widget_x + widget_w / 2))" "$((widget_y + widget_h / 2))"
expect "the widget opens a menu with a close marker" ok ipc shell invokeInstance "bar:$screen_name" acme.surfaces menuHere "{\"closeMarker\":\"$sandbox/closed-by-click\"}"
expect_poll "the menu is open before the outside click" 1 ipc shell readInstance menu acme.surfaces opened
expect "a click lands outside the menu" "clicked $((mon_w / 2)) $((mon_h / 2))" click "$((mon_w / 2))" "$((mon_h / 2))"
expect_poll "the outside click called the menu's close()" yes marker "$sandbox/closed-by-click"
expect_poll "the outside click removed the menu from the build records" absent ipc shell readInstance menu acme.surfaces opened
expect "the widget opens a panel with a close marker" ok ipc shell invokeInstance "bar:$screen_name" acme.surfaces summonHere ''
expect_poll "the panel is open before the outside click" 1 ipc shell readInstance panel acme.surfaces opened
expect "a click lands outside the panel" "clicked $((mon_w / 2)) $((mon_h / 2))" click "$((mon_w / 2))" "$((mon_h / 2))"
expect "the shell answers after the click" ok ipc shell ping
expect "a panel takes no grab, so the outside click leaves it open" 1 ipc shell readInstance panel acme.surfaces opened
expect "hiding the anchored panel after the click is allowed" ok ipc shell hide panel acme.surfaces

expect "the panel opens again for the disable check" ok ipc shell invokeInstance "bar:$screen_name" acme.surfaces summonHere ''

expect "a background is not summonable" "refused: not-summonable=background" ipc shell summon background acme.surfaces '{}'
expect "a plugin without the kind is refused" "refused: kind=panel id=acme.tick" ipc shell summon panel acme.tick '{}'
expect "an unknown plugin is refused" "unknown: acme.nope" ipc shell summon panel acme.nope '{}'
expect "re-summoning with a close marker is allowed" ok ipc shell summon panel acme.surfaces "{\"closeMarker\":\"$sandbox/closed-by-disable\"}"
expect "disabling the hosts fixture is allowed" ok ipc shell setPluginEnabled acme.surfaces false
expect_poll "disabling closes its open panel" 0 layer_count vgs:panel
expect_poll "disabling called the panel's close()" yes marker "$sandbox/closed-by-disable"
expect_poll "disabling removes the background surface" 0 layer_count vgs:background
expect "a disabled plugin is not summoned" "refused: disabled=acme.surfaces" ipc shell summon panel acme.surfaces '{}'
