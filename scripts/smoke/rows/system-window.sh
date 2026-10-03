# The System window, vgs.system: the holder of the exclusive `panes`
# capability (D088), a Hyprland window titled System. Over four copies of
# the acme.pane fixture, three enabled in two groups and one left disabled,
# the row reads the sidebar listing exactly the enabled sections under
# their groups in the capability's order; `{}` opening the first section,
# then the one shown last; a deep link mounting its section with the rest
# of the payload; an unknown id opening with a notice; the plugin's own
# open and toggle IPC; an own-pane summon; each switch destroying the
# section before it in the window host's build records; a click on Show in
# bar placing and removing the fixture widget, offered only to a section
# with one; a section taller than the room scrolling in the page and a
# shorter one filling it; the selection staying on its section as another
# joins and leaves; a disabled section leaving the sidebar while the
# window is open; the window read as every application window is (app_window_rows,
# scripts/smoke/app-window.sh); its edges within one pixel; and a keyboard
# path from SUPER+COMMA to every step and back out. Shell & Plugins hands
# the Settings summon command (docs/architecture/settings-window.md) to a
# stand-in vgsh in the shell's own PATH directory, which records its argv
# and runs nothing.
#
# Controls: a copy of the window that keeps the list it read when it
# opened lists a section disabled while it is open, and a shell copy whose
# PaneHost hands the holder no pane height shows the tall section cut to
# the room. The row reads no latency. It starts with no other panes holder
# installed, and leaves the user file, vgs.system's enablement, the
# plugins directory and the shell's PATH directory as it found them.
set -euo pipefail

sys_file="$home/.config/vgs/shell.json"
sys_saved="$sandbox/shell-before-system.json"
sys_calls="$sandbox/system-vgsh.calls"
cp -- "$sys_file" "$sys_saved"
rm -f -- "$sys_calls"
if [[ -e $shim/vgsh ]]; then mv -- "$shim/vgsh" "$sandbox/system-vgsh.saved"; fi
cat >"$shim/vgsh" <<EOF
#!/usr/bin/env bash
python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "\$@" >>"$sys_calls"
EOF
chmod 755 "$shim/vgsh"

# The sidebar as drawn, top to bottom: its group headings, then its rows'
# titles. A Repeater adds its rows after the items declared beside it, so
# tree order is not drawing order.
sys_sidebar() { # [ID]
  ipc smoke descendantGeometry window "${1:-vgs.system}" | py_reply '
import json, sys
rows = json.load(sys.stdin)
def shown(j):
    while j != -1:
        if not rows[j]["visible"]: return False
        j = rows[j]["parent"]
    return True
def under(j, kind):
    while j != -1:
        if rows[j]["type"] == kind: return j
        j = rows[j]["parent"]
    return -1
heads = sorted((r["box"][1], r["text"]) for i, r in enumerate(rows) if r["type"] == "Label" and r.get("role") == "eyebrow" and under(i, "Sidebar") != -1 and shown(i))
items = sorted((r["box"][1], r["text"]) for i, r in enumerate(rows) if r["type"] == "ListItem" and under(i, "Sidebar") != -1 and shown(i))
print(json.dumps([[t for _, t in heads], [t for _, t in items]], separators=(",", ":")))'
}
sys_read() { ipc smoke readInstance window vgs.system "$1"; }
sys_current() { ipc smoke readDescendant window vgs.system Sidebar current; }
sys_search() { ipc smoke readDescendant window vgs.system TextField text; }
# The label of the item that holds the window's keyboard focus: a text
# field's text, or its placeholder while it is empty.
sys_focus() { ipc smoke focused window vgs.system | py_reply 'import json,sys; r=json.load(sys.stdin); print(r[1] if isinstance(r, list) else r)'; }
# Whether each Show in bar switch draws: its text shows only while it does.
sys_switch() { ipc smoke itemTexts window vgs.system Switch | py_reply 'import json,sys; print(json.dumps([t != [] for t in json.load(sys.stdin)]))'; }
sys_switch_checked() { ipc smoke readDescendant window vgs.system Switch checked; }
sys_payload() { ipc smoke readInstance window "$1" payload; }
# Every argv the stand-in vgsh received, one JSON list per call.
sys_calls_all() { [[ -s $sys_calls ]] && python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in open(sys.argv[1])]))' "$sys_calls" || echo '[]'; }
widget_placed() { bar_widget_ids | py_reply 'import json,sys; print(any(sys.argv[1] in ids for ids in json.load(sys.stdin)))' "$1"; }
sys_binds() { hypr -j binds | py_reply 'import json,sys; print(json.dumps(sorted([b["modmask"], b["key"]] for b in json.load(sys.stdin) if b["description"] == "vgs.system:toggle" and b.get("submap", "") in ("", "default"))))'; }
sys_lent() { ipc shell lent | py_reply 'import json,sys; d=json.load(sys.stdin); print("vgs.system:toggle" in d["shortcuts"] and "vgs.system" in d["ipcTargets"])'; }
press_system() { type_keys -M logo -k comma -m logo; }
# `fits` when the mounted section ID's box is its implicit height tall, or
# the detail's room when that is more; else both. The room is the page's
# ScrollArea height less the focus ring's room above and below it.
sys_pane_fits() { # ID
  local box implicit rows ring
  box="$(ipc smoke instanceGeometry window "$1")" && implicit="$(ipc smoke readInstance window "$1" implicitHeight)" && rows="$(ipc smoke descendantGeometry window vgs.system)" || return 1
  [[ $box == \[* && $rows == \[* ]] || { echo "pane=$box window=${rows:0:20}"; return; }
  ring="$(( $(ipc smoke themeValue focusRing.width) + $(ipc smoke themeValue focusRing.offset) ))" || return 1
  python3 - "$box" "$implicit" "$rows" "$ring" <<'PY'
import json, sys
box, implicit, rows, ring = json.loads(sys.argv[1]), float(sys.argv[2]), json.loads(sys.argv[3]), float(sys.argv[4])
side = [i for i, r in enumerate(rows) if r["type"] == "Sidebar"]
def inside(j, i):
    while j != -1:
        if j == i: return True
        j = rows[j]["parent"]
    return False
areas = [r for i, r in enumerate(rows) if r["type"] == "ScrollArea" and side and not inside(i, side[0]) and r["box"][0] < box[0] + 1 and r["box"][0] + r["box"][2] > box[0]]
if len(areas) < 1: print("areas=0"); sys.exit()
room = min(a["box"][3] for a in areas) - 2 * ring
want = max(room, implicit)
print("fits" if abs(box[3] - want) <= 1 else "height=%g want=%g implicit=%g room=%g" % (box[3], want, implicit, room))
PY
}

# Preconditions: no other holder of `panes` is installed, since panes is
# exclusive. vgs.system is enabled or not as the rows before left it, and
# the restore puts that back.
sys_was="$(plugin_enabled vgs.system)" || fail "vgs.system's enabled state is unreadable"
expect "no fixture panes holder is installed" absent plugin_enabled acme.panehost
# The sidebar lists the fixture sections alone: the shipped sections the
# default set enables stay disabled until the restore below.
expect "disabling vgs.displays, a shipped section, is allowed" ok ipc shell setPluginEnabled vgs.displays false

install_plugin_copy acme.pane acme.pane "Pane" 10
# Pane Alt sorts before Pane by order and after it by name.
install_plugin_copy acme.pane acme.pane-alt "Pane Alt" 5
install_plugin_copy acme.pane acme.pane-net "Pane Net" 10 Connectivity
install_plugin_copy acme.pane acme.pane-off "Pane Off" 1
# Pane Net has no bar widget and is taller than any room.
python3 - "$home/.config/vgs/plugins/acme.pane-net" <<'PY'
import json, os, sys
root = sys.argv[1]
path = os.path.join(root, "manifest.json")
doc = json.load(open(path))
doc["kinds"].remove("bar-widget")
del doc["entryPoints"]["bar-widget"]
del doc["defaultSection"]
json.dump(doc, open(path, "w"))
os.remove(os.path.join(root, "Widget.qml"))
qml = os.path.join(root, "Pane.qml")
text = open(qml).read()
old = "implicitHeight: Theme.size.control.lg * 3"
assert text.count(old) == 1, old
open(qml, "w").write(text.replace(old, "implicitHeight: Theme.size.control.lg * 60"))
PY
expect "rescan after adding the System fixtures answers ok" ok ipc shell rescanPlugins
expect_poll "the last System fixture is discovered disabled" False plugin_enabled acme.pane-off
for id in acme.pane acme.pane-alt acme.pane-net; do
  expect "enabling $id for the System window is allowed" ok ipc shell setPluginEnabled "$id" true
done
expect "enabling the System window is allowed" ok ipc shell setPluginEnabled vgs.system true
expect_poll "the System service registered its shortcut and IPC target" True sys_lent
expect_poll "the Hyprland layer binds SUPER+COMMA to the System shortcut" '[[64, "COMMA"]]' sys_binds

# `{}` with nothing remembered opens the first section, with the keyboard
# in the sidebar's search field.
expect "the IPC opens the System window" ok ipc shell summon window vgs.system '{}'
expect_poll "the sidebar lists exactly the enabled sections under their groups in order" '[["Connectivity","Fixtures"],["Pane Net","Pane Alt","Pane","Shell & Plugins"]]' sys_sidebar
expect_poll "{} with nothing remembered mounts the first section" '["acme.pane-net"]' window_panes
expect "the first section receives an empty payload" '"{}"' sys_payload acme.pane-net
expect_poll "{} opens with the keyboard in the search field" "Search sections" sys_focus
expect "a section with no bar widget offers no Show in bar" '[false]' sys_switch
geometry expect_poll "a section taller than the room grows the page, which scrolls it" fits sys_pane_fits acme.pane-net
app_window_rows System vgs.system

# Deep links: the section named, with the rest of the payload; an id no
# section has, which opens the last section with a notice; and payloads
# open() refuses.
expect "a deep link opens the System window" ok ipc shell summon window vgs.system '{"pane":"acme.pane-alt","from":"link"}'
expect_poll "the deep link mounts its section alone" '["acme.pane-alt"]' window_panes
expect "the deep-linked section receives the payload without pane" '"{\"from\":\"link\"}"' sys_payload acme.pane-alt
expect_poll "the deep link puts the keyboard in the section" "Pane edit" sys_focus
expect "the sidebar selects the deep-linked section" 1 sys_current
expect "an unknown id answers ok" ok ipc shell summon window vgs.system '{"pane":"acme.nope"}'
expect_poll "an unknown id shows a plain notice" '"That section is not available."' sys_read notice
expect "an unknown id keeps the section shown last" '["acme.pane-alt"]' window_panes

# The plugin's own IPC: open shows a section and keeps an open window
# open; toggle closes it, then opens it on the section shown last.
expect "the plugin's IPC opens a section" ok ipc vgs.system invoke open '{"pane":"acme.pane-net"}'
expect_poll "the plugin's IPC open mounts its section" '["acme.pane-net"]' window_panes
expect "the plugin's IPC open again answers ok" ok ipc vgs.system invoke open '{"pane":"acme.pane-net"}'
expect "a second open keeps the System window open" 1 window_count System
expect "the plugin's IPC toggle answers ok" ok ipc vgs.system invoke toggle ''
expect_poll "toggle closes the open System window" 0 window_count System
expect "the plugin's IPC toggle again answers ok" ok ipc vgs.system invoke toggle ''
expect_poll "toggle opens the System window again" 1 window_count System
expect_poll "toggle opens on the section shown last" '["acme.pane-net"]' window_panes

# Switching destroys the section before it.
expect "showing Pane through the window is allowed" ok ipc smoke invokeInstance window vgs.system enterPane acme.pane
expect_poll "switching to Pane destroys Pane Alt's build record" '["acme.pane"]' window_panes
expect_poll "the shown section clears the notice" '""' sys_read notice
geometry expect_poll "a section shorter than the room fills the room" fits sys_pane_fits acme.pane

# The selection follows its section: a section that sorts before the
# selected one joins the list while the window is open, and the selection
# stays on Pane.
expect "Pane is selected before another section joins" 2 sys_current
expect "enabling Pane Off while the window is open is allowed" ok ipc shell setPluginEnabled acme.pane-off true
expect_poll "Pane Off joins the sidebar before Pane Alt" '[["Connectivity","Fixtures"],["Pane Net","Pane Off","Pane Alt","Pane","Shell & Plugins"]]' sys_sidebar
expect_poll "the selection stays on Pane as Pane Off joins" 3 sys_current
expect "disabling Pane Off again is allowed" ok ipc shell setPluginEnabled acme.pane-off false
expect_poll "the selection stays on Pane as Pane Off leaves" 2 sys_current

# Show in bar: offered to a section with a widget, a click on the drawn
# switch places and removes that widget through panes.setPlaced.
expect_poll "a section with a bar widget offers Show in bar" '[true]' sys_switch
expect_poll "the fixture widget starts in the bar" True widget_placed acme.pane
expect "Show in bar reads the widget placed" true sys_switch_checked
click_in window:System window vgs.system Switch "Show in bar" || fail "the click on Show in bar failed"
expect_poll "the fixture widget leaves the bar" False widget_placed acme.pane
expect_poll "Show in bar follows the removal" false sys_switch_checked
expect "the fixture stays enabled once unplaced" True plugin_enabled acme.pane
click_in window:System window vgs.system Switch "Show in bar" || fail "the second click on Show in bar failed"
expect_poll "the fixture widget returns to the bar" True widget_placed acme.pane
expect_poll "Show in bar follows the placement" true sys_switch_checked

# Edges: the sidebar's search field, headings and rows share its content
# edges, the rule stands between the columns, and the section's icon, its
# Show in bar switch and the mounted section share the detail's.
sys_edges() {
  local rows inset pane
  rows="$(ipc smoke descendantGeometry window vgs.system)" && inset="$(ipc smoke themeValue inset.window)" && pane="$(ipc smoke instanceGeometry window acme.pane)" || return 1
  [[ $rows == \[* && $pane == \[* ]] || { echo "window=${rows:0:20} pane=$pane"; return; }
  python3 - "$rows" "$inset" "$pane" <<'PY'
import json, sys
rows, inset, pane = (json.loads(a) for a in sys.argv[1:])
out = []
def inside(j, i):
    while j != -1:
        if j == i: return True
        j = rows[j]["parent"]
    return False
def shown(j):
    while j != -1:
        if not rows[j]["visible"]: return False
        j = rows[j]["parent"]
    return True
def right(r): return r["box"][0] + r["box"][2]
def check(name, got, want):
    if abs(got - want) > 1: out.append("%s=%.2f want=%.2f" % (name, got, want))
side = [i for i, r in enumerate(rows) if r["type"] == "Sidebar"]
rules = [i for i, r in enumerate(rows) if r["type"] == "Divider" and shown(i)]
if len(side) != 1 or len(rules) != 1: print(json.dumps(["sidebars=%d rules=%d" % (len(side), len(rules))])); sys.exit()
sb, rule, win = rows[side[0]], rows[rules[0]], rows[0]
under = lambda kind: [i for i, r in enumerate(rows) if r["type"] == kind and inside(i, side[0]) and shown(i)]
search, items = under("TextField"), under("ListItem")
eyebrows = [i for i in under("Label") if rows[i].get("role") == "eyebrow"]
if len(search) != 1 or len(items) < 2 or not eyebrows: print(json.dumps(["search=%d items=%d eyebrows=%d" % (len(search), len(items), len(eyebrows))])); sys.exit()
edge_l, edge_r = rows[search[0]]["box"][0], right(rows[search[0]])
check("sidebar.leftInset", edge_l - sb["box"][0], inset)
check("sidebar.rightInset", right(sb) - edge_r, inset)
icon_x = None
for n, i in enumerate(items):
    check("item%d.left" % n, rows[i]["box"][0], edge_l)
    check("item%d.right" % n, right(rows[i]), edge_r)
    icons = [j for j, r in enumerate(rows) if r["type"] == "Icon" and rows[r["parent"]]["parent"] == i]
    if len(icons) != 1: out.append("item%d icons=%d" % (n, len(icons))); continue
    if icon_x is None: icon_x = rows[icons[0]]["box"][0]
    check("item%d.icon.x" % n, rows[icons[0]]["box"][0], icon_x)
for n, i in enumerate(eyebrows):
    check("heading%d.x" % n, rows[i]["box"][0], icon_x)
check("rule.x", rule["box"][0], right(sb))
check("rule.height", rule["box"][3], win["box"][3])
panes = [i for i, r in enumerate(rows) if r["type"] == "Pane" and not inside(i, side[0]) and r["box"][0] >= right(rule) - 1]
if not panes: print(json.dumps(out + ["detail=absent"])); sys.exit()
dp = max(panes, key=lambda i: rows[i]["box"][2])
check("detail.x", rows[dp]["box"][0], right(rule))
check("detail.right", right(rows[dp]), right(win))
head = [i for i, r in enumerate(rows) if r["type"] == "Icon" and inside(i, dp) and shown(i)]
switch = [i for i, r in enumerate(rows) if r["type"] == "Switch" and inside(i, dp) and shown(i)]
if len(head) < 1 or len(switch) != 1: print(json.dumps(out + ["head=%d switch=%d" % (len(head), len(switch))])); sys.exit()
left, end = rows[dp]["box"][0] + inset, right(rows[dp]) - inset
check("head.icon.x", rows[head[0]]["box"][0], left)
check("head.switch.right", right(rows[switch[0]]), end)
check("pane.left", pane[0], left)
check("pane.right", pane[0] + pane[2], end)
print(json.dumps(out))
PY
}
geometry expect_poll "the sidebar, the rule and the detail share their edges within one pixel" '[]' sys_edges

# A section disabled while the window is open leaves the sidebar, and its
# mount goes with it.
expect "showing Pane Alt before it is disabled is allowed" ok ipc smoke invokeInstance window vgs.system enterPane acme.pane-alt
expect_poll "Pane Alt is mounted before it is disabled" '["acme.pane-alt"]' window_panes
expect "disabling the shown section is allowed" ok ipc shell setPluginEnabled acme.pane-alt false
expect_poll "the sidebar lists exactly the sections still enabled" '[["Connectivity","Fixtures"],["Pane Net","Pane","Shell & Plugins"]]' sys_sidebar
expect_poll "disabling the shown section drops its mount" '[]' window_panes
expect_poll "the window names the section that left" '"Pane Alt is no longer enabled."' sys_read notice
expect "enabling Pane Alt again is allowed" ok ipc shell setPluginEnabled acme.pane-alt true
expect_poll "Pane Alt returns to the sidebar" '[["Connectivity","Fixtures"],["Pane Net","Pane Alt","Pane","Shell & Plugins"]]' sys_sidebar

# A payload open() refuses closes the window.
expect "a payload that is no object is refused" "refused: open-failed=vgs.system" ipc shell summon window vgs.system '[1]'
expect "a payload key without pane is refused" "refused: open-failed=vgs.system" ipc shell summon window vgs.system '{"from":"x"}'
expect "a pane that is no string is refused" "refused: open-failed=vgs.system" ipc shell summon window vgs.system '{"pane":5}'
expect_poll "a refused payload leaves no System window" 0 window_count System

# Own-pane summon: a section's own Settings link opens the window on it.
expect_poll "the System window is closed" 0 window_count System
expect "a section's own-pane summon answers ok" ok ipc smoke invokeInstance service acme.pane summonPane ''
expect_poll "the own-pane summon mounts the caller's section" '["acme.pane"]' window_panes
expect "the caller's section receives its payload without pane" '"{\"from\":\"service\"}"' sys_payload acme.pane
expect "hiding the System window after the own-pane summon is allowed" ok ipc shell hide window vgs.system
expect_poll "hiding the System window drops the mounted section" '[]' window_panes

# Keyboard alone: SUPER+COMMA opens the section shown last with the keys
# in the search field; Up and Down move the selection and mount nothing;
# Return enters and mounts; Escape leaves the section for the search
# field; typed text filters, and Down from its reset selects a middle
# match; Right at the end of the query enters; Ctrl+End and Return on
# Shell & Plugins open Settings, which Right never does; Escape clears a
# query, then closes the window.
# wtype types with keycodes of its own, which a bind resolves only by
# keysym (docs/architecture/runtime-hyprland.md), so the row turns that on
# after the layer's line and puts hyprland.lua back after the path.
hypr_lua_save system-window
printf '%s\n' 'hl.config({ input = { resolve_binds_by_sym = true } })' >>"$home/.config/hypr/hyprland.lua"
expect "the nested instance reloads with binds resolved by keysym" ok hypr reload config-only
rest_pointer || fail "moving the pointer off the System window failed"
press_system || fail "typing SUPER+COMMA failed"
expect_poll "SUPER+COMMA opens the System window" 1 window_count System
expect_poll "SUPER+COMMA opens the section shown last" '["acme.pane"]' window_panes
expect_poll "the keyboard starts in the search field" "Search sections" sys_focus
expect "the selection starts on the shown section" 2 sys_current
type_keys -k Up || fail "typing Up in the System search failed"
expect_poll "Up moves the selection to Pane Alt" 1 sys_current
expect "Up mounts nothing" '["acme.pane"]' window_panes
type_keys -k Return || fail "typing Return in the System search failed"
expect_poll "Return mounts the selected section in place of the shown one" '["acme.pane-alt"]' window_panes
expect_poll "Return puts the keyboard in the section" "Pane edit" sys_focus
type_keys -k Escape || fail "typing Escape in the section failed"
expect_poll "Escape in the section returns the keyboard to the search field" "Search sections" sys_focus
expect "Escape in the section keeps it mounted" '["acme.pane-alt"]' window_panes
type_keys net || fail "typing a query into the System search failed"
expect_poll "typing filters the sections" '[["Connectivity"],["Pane Net","Shell & Plugins"]]' sys_sidebar
type_keys -k BackSpace -k BackSpace -k BackSpace pane || fail "typing a wider query failed"
expect_poll "a query every section matches lists them all" '[["Connectivity","Fixtures"],["Pane Net","Pane Alt","Pane","Shell & Plugins"]]' sys_sidebar
expect_poll "a new query selects its first match" 0 sys_current
type_keys -k Down -k Down || fail "typing Down in the System search failed"
expect_poll "Down from the first match selects a middle row" 2 sys_current
type_keys -k Return || fail "typing Return on the searched row failed"
expect_poll "Return in the search field enters the selected match" '["acme.pane"]' window_panes
expect_poll "Return in the search field puts the keyboard in the section" "Pane edit" sys_focus
type_keys -k Escape || fail "typing Escape in the searched section failed"
expect_poll "Escape returns the keyboard to the search field, which holds the query" "pane" sys_focus
expect "the query stays after the section is left" '"pane"' sys_search
type_keys -k Up || fail "typing Up after the search failed"
expect_poll "Up selects Pane Alt again" 1 sys_current
type_keys -k Right || fail "typing Right at the end of the query failed"
expect_poll "Right at the end of the query enters the selected section" '["acme.pane-alt"]' window_panes
type_keys -k Escape || fail "typing Escape in the right-entered section failed"
expect_poll "Escape returns the keyboard to the search field again" "pane" sys_focus
type_keys -M ctrl -k End -m ctrl || fail "typing Ctrl+End in the System search failed"
expect_poll "Ctrl+End selects Shell & Plugins" 3 sys_current
type_keys -k Right -k Return || fail "typing Right and Return on Shell & Plugins failed"
expect_poll "Return on Shell & Plugins alone hands vgsh the Settings summon, Right before it none" '[["ipc", "call", "shell", "summon", "window", "vgs.settings", "{}"]]' sys_calls_all
type_keys zz || fail "typing into the System search failed"
expect_poll "typing filters every section out" '[[],["Shell & Plugins"]]' sys_sidebar
type_keys -k Escape || fail "typing Escape in the System search failed"
expect_poll "Escape with a query clears it" '""' sys_search
expect "Escape with a query keeps the window open" 1 window_count System
type_keys -k Escape || fail "typing Escape in the empty System search failed"
expect_poll "Escape with no query closes the System window" 0 window_count System
expect_poll "closing the window drops its section" '[]' window_panes
expect "vgsh still holds that one call once the window closed" '[["ipc", "call", "shell", "summon", "window", "vgs.settings", "{}"]]' sys_calls_all
press_system || fail "typing SUPER+COMMA again failed"
expect_poll "SUPER+COMMA reopens on the section shown last" '["acme.pane-alt"]' window_panes
expect_poll "the reopened window starts with an empty query" '""' sys_search
press_system || fail "typing SUPER+COMMA to close failed"
expect_poll "SUPER+COMMA closes the open System window" 0 window_count System
hypr_lua_restore system-window || fail "hyprland.lua is put back after the System keyboard path"
expect "the nested instance reloads hyprland.lua as the row found it" ok hypr reload config-only

# Control: a copy of the window that keeps the list it read when it
# opened. A section disabled while it is open stays listed, and the
# sidebar reading names it.
stale_dir="$home/.config/vgs/plugins/acme.system-stale"
rm -rf -- "${stale_dir:?}"
cp -R -- "$repo/shell/plugins/vgs.system" "$stale_dir"
python3 - "$stale_dir" <<'PY'
import json, os, sys
root = sys.argv[1]
path = os.path.join(root, "manifest.json")
doc = json.load(open(path))
doc["id"], doc["name"] = "acme.system-stale", "System Copy"
del doc["hyprland"]
json.dump(doc, open(path, "w"))
qml = os.path.join(root, "Window.qml")
text = open(qml).read()
old = "readonly property var panes: shell === null ? [] : shell.panes.list"
assert text.count(old) == 1, old
changed = text.replace(old, "property var panes: []\n    onShellChanged: if (shell !== null && panes.length === 0) panes = shell.panes.list")
assert changed != text
open(qml, "w").write(changed)
PY
expect "disabling vgs.system for the stale-list control is allowed" ok ipc shell setPluginEnabled vgs.system false
expect "rescan after adding the stale-list copy answers ok" ok ipc shell rescanPlugins
expect_poll "the stale-list copy is discovered" False plugin_enabled acme.system-stale
expect "enabling the stale-list copy is allowed" ok ipc shell setPluginEnabled acme.system-stale true
expect "the stale-list copy opens" ok ipc shell summon window acme.system-stale '{}'
expect_poll "the stale-list copy lists the enabled sections when it opens" '[["Connectivity","Fixtures"],["Pane Net","Pane Alt","Pane","Shell & Plugins"]]' sys_sidebar acme.system-stale
expect "disabling Pane Alt under the stale-list copy is allowed" ok ipc shell setPluginEnabled acme.pane-alt false
expect_poll "control: a sidebar that keeps its first list still lists the disabled section" '[["Connectivity","Fixtures"],["Pane Net","Pane Alt","Pane","Shell & Plugins"]]' sys_sidebar acme.system-stale
expect "hiding the stale-list copy is allowed" ok ipc shell hide window acme.system-stale
expect "disabling the stale-list copy is allowed" ok ipc shell setPluginEnabled acme.system-stale false
rm -rf -- "${stale_dir:?}"
expect "rescan after removing the stale-list copy answers ok" ok ipc shell rescanPlugins
expect_poll "the stale-list copy is gone" absent plugin_enabled acme.system-stale
expect "enabling Pane Alt after the stale-list control is allowed" ok ipc shell setPluginEnabled acme.pane-alt true
expect "enabling vgs.system after the stale-list control is allowed" ok ipc shell setPluginEnabled vgs.system true

# Control: a shell copy whose PaneHost takes no implicit height from the
# pane, so the holder's container keeps the room alone and the tall
# section is cut to it.
if copy_tree system-pane-height && edit_tree system-pane-height shell/Hosts/PaneHost.qml 'implicitHeight: slot.instance === null ? 0 : slot.instance.implicitHeight' 'implicitHeight: 0'; then
  stop_shell
  start_shell "$sandbox/tree-system-pane-height" "$sandbox/qs-system-pane-height.log" || fail "the pane-height control shell starts"
  expect_poll "control: the pane-height shell knows vgs.system" True plugin_enabled vgs.system
  expect "control: the pane-height shell opens Pane Net" ok ipc shell summon window vgs.system '{"pane":"acme.pane-net"}'
  expect_poll "control: the pane-height shell mounts Pane Net" '["acme.pane-net"]' window_panes
  control_fit="$(sys_pane_fits acme.pane-net)" || control_fit="unreadable"
  expect "control: a holder handed no pane height cuts the tall section to the room" True python3 -c 'import sys; print(sys.argv[1].startswith("height="))' "$control_fit"
  stop_shell
  start_shell "$repo" "$sandbox/qs-restored-system.log" || fail "the shell starts again after the pane-height control"
fi
expect_poll "the restored shell knows vgs.system" True plugin_enabled vgs.system
expect "the restored shell opens Pane Net" ok ipc shell summon window vgs.system '{"pane":"acme.pane-net"}'
geometry expect_poll "the restored shell grows the page to the tall section" fits sys_pane_fits acme.pane-net
expect "hiding the System window after the controls is allowed" ok ipc shell hide window vgs.system
expect_poll "the System window is gone after the controls" 0 window_count System

cp -- "$sys_saved" "$sys_file.tmp" && mv -T -- "$sys_file.tmp" "$sys_file"
rm -rf -- "${home:?}/.config/vgs/plugins/acme.pane" "${home:?}/.config/vgs/plugins/acme.pane-alt" "${home:?}/.config/vgs/plugins/acme.pane-net" "${home:?}/.config/vgs/plugins/acme.pane-off"
rm -f -- "$shim/vgsh"
if [[ -e $sandbox/system-vgsh.saved ]]; then mv -- "$sandbox/system-vgsh.saved" "$shim/vgsh"; fi
expect "rescan after removing the System fixtures answers ok" ok ipc shell rescanPlugins
expect_poll "the System fixtures are gone after restore" absent plugin_enabled acme.pane
expect_poll "vgs.system is enabled again as the row found it" "$sys_was" plugin_enabled vgs.system
