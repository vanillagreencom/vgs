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
respaced() { "$@" | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)))'; }
surface_focused() { respaced ipc smoke focused "$1" acme.surfaces | py_reply 'import json,sys; row=json.load(sys.stdin); row[0]="Control"; print(json.dumps(row))'; }
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
# summon_box KIND: the plugin's box on the output, [x, y, w, h]: the layer's
# origin plus the instance's box in the layer, which covers the free area.
summon_box() {
  local layer item
  layer="$(surface_box "vgs:$1")" || return 1
  item="$(ipc smoke instanceGeometry "$1" acme.surfaces)" || return 1
  python3 -c 'import json,sys; l=json.loads(sys.argv[1]); r=json.loads(sys.argv[2]); print(json.dumps([l[0] + r[0], l[1] + r[1], r[2], r[3]]))' "$layer" "$item"
}
geometry expect_poll "the panel's layer covers the free area below the bar" "[[0, $bar_reserved, $mon_w, $((mon_h - bar_reserved))]]" layers_of vgs:panel
geometry expect_poll "the panel takes its top-right placement below the bar" "[$((mon_w - 8 - 200)), $((bar_reserved + 8)), 200, 120]" summon_box panel
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

expect "a panel summons over IPC for keyboard focus" ok ipc shell summon panel acme.surfaces '{}'
expect_poll "the IPC panel gives its initialFocus visual focus" '["Control", "Initial focus", true, true, true]' surface_focused panel
type_keys -k Escape || fail "sending Escape to the IPC panel failed"
expect_poll "Escape closes an IPC panel the plugin leaves unaccepted" 0 layer_count vgs:panel

slot_now="$repo/shell/Hosts/PluginSlotFocusNow.qml"
slot_now_panel="$repo/shell/Hosts/PluginSlotFocusNowPanel.qml"
slot_mouse="$repo/shell/Hosts/PluginSlotMouseReason.qml"
slot_mouse_panel="$repo/shell/Hosts/PluginSlotMouseReasonPanel.qml"
summon_noescape="$repo/shell/Hosts/SummonPopupNoEscape.qml"
summon_copy="$repo/shell/Hosts/SummonPopupNoGrab.qml"
layer_copy="$repo/shell/Hosts/SummonLayerNoCatch.qml"
focus_control="$home/.config/vgs/plugins/acme.focus-control"
python3 - "$repo/shell/Hosts/PluginSlot.qml" "$slot_now" <<'PYEDIT'
import pathlib, sys
source, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = source.read_text()
start = text.index("    function focusInitial(reason) {\n")
end = text.index("\n\n    Connections {", start)
new = """    function focusInitial(reason) {
        clearPendingFocus();
        focusTarget().forceActiveFocus(reason);
    }"""
target.write_text(text[:start] + new + text[end:])
assert target.read_text().count(new) == 1
PYEDIT
python3 - "$repo/shell/Hosts/PluginSlot.qml" "$slot_mouse" <<'PYEDIT'
import pathlib, sys
source, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = source.read_text()
old = "target.forceActiveFocus(reason);"
assert text.count(old) == 2, "the PluginSlot focus call must occur twice"
target.write_text(text.replace(old, "target.forceActiveFocus(Qt.MouseFocusReason);"))
PYEDIT
python3 - "$repo/shell/Hosts/SummonPopup.qml" "$summon_noescape" <<'PYEDIT'
import pathlib, sys
source, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = source.read_text()
old = "        Keys.onEscapePressed: popup.dismissed()\n"
assert text.count(old) == 1, "the SummonPopup Escape handler must occur once"
target.write_text(text.replace(old, ""))
PYEDIT
python3 - "$repo/shell/Hosts/SummonPopup.qml" "$summon_copy" <<'PYEDIT'
import pathlib, sys
source, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = source.read_text()
assert text.count("    grabFocus: true\n") == 1, "the SummonPopup grab must occur once"
target.write_text(text.replace("    grabFocus: true\n", "    grabFocus: false\n"))
PYEDIT
python3 - "$repo/shell/Hosts/SummonLayer.qml" "$layer_copy" <<'PYEDIT'
import pathlib, sys
source, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = source.read_text()
old = "        enabled: win.catches\n"
assert text.count(old) == 1, "the SummonLayer catcher must occur once"
target.write_text(text.replace(old, "        enabled: false\n"))
PYEDIT
cat >"$slot_now_panel" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons

PanelWindow {
    id: win

    required property string pluginId
    property var screen: null
    readonly property var place: PluginLogic.surfacePlacement("panel", {}, Theme.space.md)

    anchors { top: place.anchors.top; bottom: place.anchors.bottom; left: place.anchors.left; right: place.anchors.right }
    margins { top: place.margins.top; bottom: place.margins.bottom; left: place.margins.left; right: place.margins.right }
    exclusionMode: place.exclusion === "ignore" ? ExclusionMode.Ignore : ExclusionMode.Normal
    exclusiveZone: 0
    implicitWidth: slot.instance ? Math.max(1, slot.instance.implicitWidth) : 1
    implicitHeight: slot.instance ? Math.max(1, slot.instance.implicitHeight) : 1
    color: "transparent"
    WlrLayershell.namespace: "vgs:slot-focus-control"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: PluginLogic.layerKeyboardFocus("panel", false) === "exclusive" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

    PluginSlotFocusNow {
        id: slot
        kind: "panel"
        pluginId: win.pluginId
        hostKey: "slot-control"
        screen: win.screen
        closeOnUnload: true
        anchors.fill: parent
        focus: true
        onBuilt: instance => {
            instance.open("{}");
            slot.focusInitial(Qt.ShortcutFocusReason);
            slot.forceActiveFocus(Qt.ActiveWindowFocusReason);
            slot.focusTarget().forceActiveFocus(Qt.ActiveWindowFocusReason);
        }
        onBuildFailed: key => win.destroy()
    }
}
QML
cat >"$slot_mouse_panel" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons

PanelWindow {
    id: win

    required property string pluginId
    property var screen: null
    readonly property var place: PluginLogic.surfacePlacement("panel", {}, Theme.space.md)

    anchors { top: place.anchors.top; bottom: place.anchors.bottom; left: place.anchors.left; right: place.anchors.right }
    margins { top: place.margins.top; bottom: place.margins.bottom; left: place.margins.left; right: place.margins.right }
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0
    implicitWidth: slot.instance ? Math.max(1, slot.instance.implicitWidth) : 1
    implicitHeight: slot.instance ? Math.max(1, slot.instance.implicitHeight) : 1
    color: "transparent"
    WlrLayershell.namespace: "vgs:slot-mouse-reason-control"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    PluginSlotMouseReason {
        id: slot
        kind: "panel"
        pluginId: win.pluginId
        hostKey: "slot-mouse-reason"
        screen: win.screen
        closeOnUnload: true
        anchors.fill: parent
        focus: true
        onBuilt: instance => {
            instance.open("{}");
            slot.focusInitial(Qt.ShortcutFocusReason);
            slot.forceActiveFocus(Qt.ActiveWindowFocusReason);
        }
        onBuildFailed: key => win.destroy()
    }
}
QML
mkdir -p "$focus_control"
cat >"$focus_control/manifest.json" <<'JSON'
{ "schemaVersion": 1, "id": "acme.focus-control", "name": "Focus control", "version": "0.1.0", "author": "acme", "description": "smoke fixture for host focus controls", "kinds": ["panel"], "entryPoints": { "panel": "Summoned.qml" } }
JSON
cat >"$focus_control/Summoned.qml" <<'QML'
import QtQuick
import QtQuick.Templates as T
import qs.Ui

Item {
    property var shell: null
    property alias initialFocus: focusTarget
    implicitWidth: 200
    implicitHeight: 120
    function open(payloadJson) {}
    function close() {}
    T.Control {
        id: focusTarget
        property string text: "Initial focus"
        width: 120
        height: 40
        anchors.centerIn: parent
        focusPolicy: Qt.StrongFocus
        background: Item { FocusRing { target: focusTarget } }
    }
}
QML
expect "the focus control fixture is scanned" ok ipc shell rescanPlugins
expect_poll "the focus control fixture is discovered" True plugin_known acme.focus-control
expect "enabling the focus control fixture is allowed" ok ipc shell setPluginEnabled acme.focus-control true
expect "control: the probe builds a slot copy that focuses before activation" ok ipc smoke panelHostLoad slot-focus-now "$slot_now_panel" acme.focus-control
focus_control_focused() { respaced ipc smoke focused slot-control acme.focus-control | py_reply 'import json,sys; row=json.load(sys.stdin); row[0]="Control"; print(json.dumps(row))'; }
expect_poll "control: focusing before activation loses visual focus" '["Control", "Initial focus", false, false, true]' focus_control_focused
expect "control: the probe drops the immediate-focus slot copy" ok ipc smoke popupDrop slot-focus-now
expect_poll "control: the immediate-focus slot copy leaves the build records" absent ipc smoke readInstance slot-control acme.focus-control opened
expect "control: the probe builds a slot copy that forces MouseFocusReason" ok ipc smoke panelHostLoad slot-mouse-reason "$slot_mouse_panel" acme.focus-control
mouse_reason_focused() { respaced ipc smoke focused slot-mouse-reason acme.focus-control | py_reply 'import json,sys; row=json.load(sys.stdin); row[0]="Control"; print(json.dumps(row))'; }
expect_poll "control: MouseFocusReason loses the unanchored summon ring" '["Control", "Initial focus", false, false, true]' mouse_reason_focused
expect "control: the probe drops the mouse-reason slot copy" ok ipc smoke popupDrop slot-mouse-reason
expect_poll "control: the mouse-reason slot copy leaves the build records" absent ipc smoke readInstance slot-mouse-reason acme.focus-control opened
expect "disabling the focus control fixture is allowed" ok ipc shell setPluginEnabled acme.focus-control false
rm -rf -- "$focus_control"
scans_before_focus_remove="$(scans_done)"
expect "the focus control fixture removal is scanned" ok ipc shell rescanPlugins
expect_log "the focus control fixture removal is complete" "$((scans_before_focus_remove + 1))" 'plugins: scan complete '

cp -- "$home/.config/vgs/plugins/acme.surfaces/Summoned.qml" "$sandbox/Summoned.initial-focus"
python3 - "$home/.config/vgs/plugins/acme.surfaces/Summoned.qml" <<'PYEDIT'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "    property alias initialFocus: focusTarget\n"
assert s.count(old) == 1
p.write_text(s.replace(old, ""))
PYEDIT
scans_before_initial="$(scans_done)"
expect "the fixture without initialFocus is rescanned" ok ipc shell rescanPlugins
expect_log "the fixture without initialFocus is available" "$((scans_before_initial + 1))" 'plugins: scan complete '
expect "the panel without initialFocus opens" ok ipc shell summon panel acme.surfaces '{}'
expect_poll "without initialFocus the plugin has no visual focus" no-focus ipc smoke focused panel acme.surfaces
type_keys -k Escape || fail "sending Escape to the no-initialFocus panel failed"
expect_poll "the slot still closes a panel without initialFocus on Escape" 0 layer_count vgs:panel
mv -T -- "$sandbox/Summoned.initial-focus" "$home/.config/vgs/plugins/acme.surfaces/Summoned.qml"
scans_before_initial_restore="$(scans_done)"
expect "the fixture with initialFocus is restored" ok ipc shell rescanPlugins
expect_log "the fixture with initialFocus is available again" "$((scans_before_initial_restore + 1))" 'plugins: scan complete '

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

# An unanchored panel or menu covers its screen and catches a press beside
# it (SummonLayer), so a press outside the plugin closes it through the hide
# path, over a client window or on the empty desktop, and a press inside it
# does not. The fixture sits at the top right; the desktop point is the
# bottom left, and the other window tiles the screen, so its point is left
# of the panel and above the desktop point's row. A layer takes a press
# only once it has drawn at its size, so each press beside a summon that
# has just mapped waits for that (summon_drawn).
layer_desktop_point="40 $((mon_h - 40))"
layer_window_point="$((mon_w / 4)) $((mon_h / 2))"
# layer_press LABEL POINT: one press at POINT, `x y`.
layer_press() {
  local x y
  read -r x y <<<"$2"
  click "$x" "$y" || fail "$1: the press failed"
}
# layer_copy_state NAME: the dismissals the probe counted for SummonLayer
# copy NAME and the panel layers mapped, as `<dismissals> <layers>`.
layer_copy_state() { printf '%s %s\n' "$(ipc smoke summonLayerDismissals "$1")" "$(layer_count vgs:panel)"; }
expect "a panel summons for the outside press on the desktop" ok ipc shell summon panel acme.surfaces "{\"closeMarker\":\"$sandbox/closed-by-desktop-press\"}"
expect_poll "the panel is mapped before the inside press" 1 layer_count vgs:panel
summon_drawn panel acme.surfaces || fail "the panel never drew before the inside press"
# The inside point is 6 px into the fixture's top-left corner, clear of its
# centred control, so no item of the plugin takes the press and the catcher
# under it must leave it.
if panel_inside="$(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); print(int(b[0] + 6), int(b[1] + 6))' "$(summon_box panel)")"; then
  layer_press "the press inside the panel" "$panel_inside"
  sleep 0.5 # a press outside closes the panel well within this; nothing else marks a press that closed nothing
  expect "a press inside the panel leaves it open" 1 layer_count vgs:panel
else
  fail "the panel's box is unreadable"
fi
layer_press "the press on the desktop" "$layer_desktop_point"
expect_poll "a press on the desktop called the panel's close()" yes marker "$sandbox/closed-by-desktop-press"
expect_poll "a press on the desktop closes an unanchored panel" 0 layer_count vgs:panel
expect "a menu summons for the outside press" ok ipc shell summon menu acme.surfaces '{}'
expect_poll "the menu is mapped before the outside press" 1 layer_count vgs:menu
summon_drawn menu acme.surfaces || fail "the menu never drew before the outside press"
layer_press "the press beside the menu" "$layer_desktop_point"
expect_poll "a press on the desktop closes an unanchored menu" 0 layer_count vgs:menu
expect_poll "the closed menu leaves the build records" absent ipc smoke readInstance menu acme.surfaces opened
if open_other "$sandbox/toplevel-surfaces-outside-press.log"; then
  expect "a panel summons over the other window" ok ipc shell summon panel acme.surfaces '{}'
  expect_poll "the panel is mapped over the other window" 1 layer_count vgs:panel
  summon_drawn panel acme.surfaces || fail "the panel over the other window never drew"
  layer_press "the press on the other window" "$layer_window_point"
  expect_poll "a press on a client window closes an unanchored panel" 0 layer_count vgs:panel
  expect "the press beside the panel never reached the other window" 0 other_events "^button 272 pressed$"
  expect_poll "the panel closed by the window press leaves the build records" absent ipc smoke readInstance panel acme.surfaces opened

  # Control: the SummonLayer copy whose catcher takes no press, written at
  # the top of the row, stays open under the same presses, over the window
  # and on the desktop. The probe counts the copy's dismissals.
  expect "the probe builds the SummonLayer copy without the catcher" ok ipc smoke summonLayerLoad layer-nocatch "$layer_copy" acme.surfaces panel
  ipc smoke invokeInstance panel acme.surfaces open '{}' >/dev/null || fail "the catchless layer copy's open() could not be called"
  expect_poll "the catchless layer copy has opened its panel" 1 ipc smoke readInstance panel acme.surfaces opened
  expect_poll "the catchless layer copy is mapped" "0 1" layer_copy_state layer-nocatch
  summon_drawn panel acme.surfaces || fail "the catchless layer copy never drew"
  layer_press "the press on the other window beside the catchless copy" "$layer_window_point"
  sleep 0.5 # the shipped layer closed on the same press within this time
  expect "control: a press on a client window leaves the catchless copy open" "0 1" layer_copy_state layer-nocatch
  layer_press "the press on the desktop beside the catchless copy" "$layer_desktop_point"
  sleep 0.5 # as above
  expect "control: a press on the desktop leaves the catchless copy open" "0 1" layer_copy_state layer-nocatch
  expect "the probe drops the catchless layer copy" ok ipc smoke popupDrop layer-nocatch
  expect_poll "the catchless layer copy leaves the build records" absent ipc smoke readInstance panel acme.surfaces opened
  expect_poll "the catchless layer copy's surface is gone" 0 layer_count vgs:panel
  close_other "the outside-press window's helper exits 0 on SIGTERM"
else
  fail "the other window for the outside press did not map"
fi

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
expect_poll "the anchored panel focuses initialFocus without a ring" '["Control", "Initial focus", false, false, true]' surface_focused panel
type_keys -k Escape || fail "sending Escape to the anchored panel failed"
expect_poll "Escape closes an anchored panel the plugin leaves unaccepted" absent ipc smoke readInstance panel acme.surfaces opened

expect "the unanchored panel opens for a nested menu" ok ipc shell summon panel acme.surfaces '{}'
expect_poll "the parent panel is mapped" 1 layer_count vgs:panel
read -r panel_x panel_y < <(panel_origin)
expect "the panel summons a menu from its own item" ok ipc smoke invokeInstance panel acme.surfaces menuHere '{}'
geometry expect_poll "the nested menu uses its parent's window coordinates" placed placed_below menu panel anchorGeometry "$panel_x" "$panel_y"
type_keys -k Escape || fail "sending Escape to the nested menu failed"
expect_poll "Escape closes the nested menu" absent ipc smoke readInstance menu acme.surfaces opened
expect_poll "closing a popup returns focus to the parent panel" '["Control", "Initial focus", false, false, true]' surface_focused panel
expect "the panel summons a menu from its own item again" ok ipc smoke invokeInstance panel acme.surfaces menuHere '{}'
geometry expect_poll "the nested menu still uses its parent's window coordinates" placed placed_below menu panel anchorGeometry "$panel_x" "$panel_y"
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
expect "the probe builds the SummonPopup copy without Escape" ok ipc smoke popupLoad summon-noescape "$summon_noescape" "bar:$screen_name" acme.surfaces '{"pluginId":"acme.surfaces","kind":"panel","request":{"anchor":"@instance","anchored":true,"payloadJson":"{}"}}'
expect "the no-Escape copy's panel takes a payload" '' ipc smoke invokeInstance panel acme.surfaces open '{}'
expect_poll "the no-Escape copy is shown before Escape" true ipc smoke popupRead summon-noescape visible
type_keys -k Escape || fail "sending Escape to the no-Escape copy failed"
expect_poll "control: the no-Escape copy stays open" true ipc smoke popupRead summon-noescape visible
expect "the probe drops the no-Escape copy" ok ipc smoke popupDrop summon-noescape
expect_poll "the no-Escape copy's panel leaves the build records" absent ipc smoke readInstance panel acme.surfaces opened

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
old = 'if (payload.fail === true)'
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
