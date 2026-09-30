# The Settings plugin, vgs.settings, the plugin manager's user interface.
# Enabled here, it places its gear in every bar and binds SUPER+M; the gear
# opens a Hyprland window centred on its monitor's work area, half the
# monitor tall and `size.window.width` wide or clamped on a narrower
# monitor, which takes the keyboard. The pointer shows the hand over the
# list's controls, the I-beam over its search field and the arrow over its
# heading. The window lists every plugin, itself included, and opens a page
# per plugin whose settings, keys and enablement it writes through the
# manager capability; the title's menu jumps between pages, the back button
# and Escape return, a deep link opens one page, and the page's scroll bar
# drags. An installed plugin's Update and Remove buttons, the list's Add
# plugin button and a missing requirement's Install button each open the
# manager's core floating TUI for that plugin, read back from the stand-in
# terminal's recorded argv, which runs none of them, and the window stays
# open behind the terminal, which Hyprland focuses; a bundled plugin's
# page draws neither button, and each requirement row reads back with its
# state and purpose. rows/settings.sh continues with the same window and
# disables the plugin again.
set -euo pipefail
read -r mon_w mon_h bar_reserved < <(monitor_size)

settings_rows() { ipc smoke readInstance window vgs.settings plugins; }
settings_page() { ipc smoke readInstance window vgs.settings page; }
settings_open() { [[ $(ipc smoke instanceGeometry window vgs.settings) != absent ]] && echo open || echo closed; }
settings_layer() { one_window Settings; }
settings_click() { click_in window:Settings window vgs.settings "$1" "$2"; }
user_file="$home/.config/vgs/shell.json"
# The key the user file gives vgs.settings' shortcut: its value as JSON, or
# `absent` when the row holds no entry.
user_key() { python3 -c 'import json,sys; rows=[r for r in json.load(open(sys.argv[1])).get("plugins", []) if r["id"] == "vgs.settings"]; k=rows[0].get("keys", {}) if rows else {}; print(json.dumps(k["toggle"]) if "toggle" in k else "absent")' "$user_file"; }
# The binds Hyprland holds for the Settings shortcut, as [modmask, key].
settings_binds() { hypr -j binds | py_reply 'import json,sys; print(json.dumps(sorted([b["modmask"], b["key"]] for b in json.load(sys.stdin) if b["description"] == "vgs.settings:toggle" and b.get("submap", "") in ("", "default"))))'; }
# window_fits MONITOR [MODE]: [] when the Settings window on MONITOR is
# min(size.window.width, width - 2 * size.window.gutter) wide,
# size.window.heightShare of the height tall and centred on the monitor's
# work area, its box less the space the bar reserves and general:float_gaps,
# where Hyprland centres a floating window
# (docs/architecture/runtime-hyprland.md), within one pixel; else the
# misfits. The monitor, the clients and the gaps come from one batched
# request, which the compositor answers from one state. Given MODE, the
# mode a row holds, a monitor at another mode reads
# ["mode=<WxH> want=<MODE>"] and no window is measured against it.
window_fits() {
  local width share gutter
  width="$(ipc smoke themeValue size.window.width)" || return
  share="$(ipc smoke themeValue size.window.heightShare)" || return
  gutter="$(ipc smoke themeValue size.window.gutter)" || return
  hypr --batch 'j/monitors; j/clients; j/getoption general:float_gaps' | py_reply '
import json, math, sys
text = sys.stdin.read()
decoder, at, parts = json.JSONDecoder(), 0, []
while len(parts) < 3:
    while text[at].isspace(): at += 1
    part, at = decoder.raw_decode(text, at)
    parts.append(part)
monitors, clients, gaps = parts
name, held, klass, (width, share, gutter) = sys.argv[1], sys.argv[2], sys.argv[3], (json.loads(a) for a in sys.argv[4:])
mon = [m for m in monitors if m["name"] == name]
if len(mon) != 1:
    print(json.dumps(["monitor=%s absent" % name])); sys.exit()
m = mon[0]
mode = "%dx%d" % (m["width"], m["height"])
if held and mode != held:
    print(json.dumps(["mode=%s want=%s" % (mode, held)])); sys.exit()
mw, mh = m["width"] / m["scale"], m["height"] / m["scale"]
boxes = [c["at"] + c["size"] for c in clients if c["class"] == klass and c["title"] == "Settings" and c["mapped"] and c["monitor"] == m["id"]]
if len(boxes) != 1:
    print(json.dumps(["windows=%d" % len(boxes)])); sys.exit()
x, y, w, h = boxes[0]
top, right, bottom, left = (int(v) for v in gaps["css"].split())
rl, rt, rr, rb = m["reserved"]
area_x, area_y = m["x"] + rl + left, m["y"] + rt + top
area_w, area_h = mw - rl - rr - left - right, mh - rt - rb - top - bottom
want_w, want_h = math.floor(min(width, mw - 2 * gutter)), math.floor(share * mh)
out = []
for key, got, want in (("w", w, want_w), ("h", h, want_h), ("x", x, area_x + (area_w - want_w) / 2), ("y", y, area_y + (area_h - want_h) / 2)):
    if abs(got - want) > 1: out.append("%s=%s want=%s" % (key, got, want))
print(json.dumps(out))' "$1" "${2:-}" "$shell_class" "$width" "$share" "$gutter"
}
first_monitor() { hypr -j monitors | py_reply 'import json,sys; print(json.load(sys.stdin)[0]["name"])'; }

# Enable: the gear joins every bar's right section, the service registers
# its shortcut and IPC target, and the Hyprland layer binds SUPER+M.
expect "enabling the Settings plugin is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect_poll "listPlugins reads the Settings plugin enabled" True plugin_enabled vgs.settings
gear_placed() { bar_widget_ids | py_reply 'import json,sys; b=json.load(sys.stdin); print(len(b) > 0 and all(ids[-1:] == ["vgs.settings"] for ids in b))'; }
expect_poll "enabling places the gear last in every bar" True gear_placed
settings_lent() { ipc shell lent | py_reply 'import json,sys; d=json.load(sys.stdin); print("vgs.settings:toggle" in d["shortcuts"] and "vgs.settings" in d["ipcTargets"])'; }
expect_poll "the Settings service registered its shortcut and IPC target" True settings_lent
expect_poll "the Hyprland layer binds SUPER+M to the Settings shortcut" '[[64, "M"]]' settings_binds
# The gear draws like the other bar icons: its button and its icon on the
# bar's vertical centre, within one pixel.
gear_centred() {
  local key bar_box gear
  key="$(bar_key)" || return
  bar_box="$(ipc smoke instanceGeometry "$key" vgs.bar)" || return
  gear="$(ipc smoke descendantGeometry "$key" vgs.settings)" || return
  python3 - "$bar_box" "$gear" <<'PY'
import json, sys
bar, rows = (json.loads(a) for a in sys.argv[1:])
centre = bar[1] + bar[3] / 2
out = []
for kind in ("IconButton", "Icon"):
    found = [r for r in rows if r["type"] == kind]
    if len(found) != 1: out.append("%s=%d" % (kind, len(found)))
    for r in found:
        mid = r["box"][1] + r["box"][3] / 2
        if abs(mid - centre) > 1: out.append("%s.y=%.2f want=%.2f" % (kind, mid, centre))
print(json.dumps(out))
PY
}
geometry expect_poll "the gear and its icon sit on the bar's vertical centre" '[]' gear_centred

# The gear opens the window on its bar's monitor, the focused one, centred
# on its work area, and the window takes the keyboard: typed letters reach
# its search field.
click_centre "$(bar_key)" vgs.settings || fail "the click on the gear failed"
expect_poll "the gear opens the Settings window" open settings_open
expect_poll "the Settings window is one window" 1 window_count Settings
main_monitor="$(first_monitor)" || fail "the first monitor's name is unreadable"
geometry expect_poll "the window is the token width, half the monitor tall and centred on the work area within one pixel" '[]' window_fits "$main_monitor"
expect_poll "the window takes the keyboard when it opens" true ipc smoke activeFocusIn window vgs.settings
listed_names() { ipc smoke itemTexts window vgs.settings ListItem | py_reply 'import json,sys; print(json.dumps([t[0] for t in json.load(sys.stdin)]))'; }
type_keys probe || fail "typing into the Settings search failed"
expect_poll "typing filters the list to the matching plugin" '["Probe"]' listed_names
type_keys -k BackSpace -k BackSpace -k BackSpace -k BackSpace -k BackSpace || fail "clearing the Settings search failed"
list_complete() {
  local plugins
  plugins="$(ipc shell listPlugins | py_reply 'import json,sys; print(len(json.load(sys.stdin)["plugins"]))')" && [[ $plugins =~ ^[0-9]+$ ]] || { echo "$plugins"; return 1; }
  listed_names | py_reply 'import json,sys; print(len(json.load(sys.stdin)) == int(sys.argv[1]))' "$plugins"
}
expect_poll "the cleared search lists every plugin again" True list_complete
# The list page: the content box's left and right insets match
# `inset.window`; the search field, every row and the heading span that
# content box; the scroll bar is in the right inset; the placeholder and
# typed text are vertically centred; and each row's lines centre on its
# icon. Unit mutations in tst_pane, tst_scroll, tst_textfield and
# tst_layout are the controls for these geometry rules. `[]` is the pass.
list_alignment() {
  local rows pad inset
  rows="$(ipc smoke descendantGeometry window vgs.settings)" || return
  pad="$(ipc smoke themeValue row.paddingX)" || return
  inset="$(ipc smoke themeValue inset.window)" || return
  python3 - "$rows" "$pad" "$inset" <<'PY'
import json, sys
rows, pad, inset = (json.loads(a) for a in sys.argv[1:])
out = []
def inside(j, i):
    while j != -1:
        if j == i: return True
        j = rows[j]["parent"]
    return False
def right(r): return r["box"][0] + r["box"][2]
def mid_y(r): return r["box"][1] + r["box"][3] / 2
def check(name, got, want):
    if abs(got - want) > 1: out.append("%s=%.2f want=%.2f" % (name, got, want))
page = [i for i, r in enumerate(rows) if r["type"] == "ListPage"]
if len(page) != 1: print(json.dumps(["pages=%d" % len(page)])); sys.exit()
under = lambda kind: [i for i, r in enumerate(rows) if r["type"] == kind and inside(i, page[0])]
search, areas, items = under("TextField"), under("ScrollArea"), under("ListItem")
heading = [i for i in under("Label") if rows[i].get("role") == "h2"]
if len(search) != 1 or len(areas) != 1 or len(heading) != 1 or len(items) < 3:
    print(json.dumps(["search=%d areas=%d heading=%d items=%d" % (len(search), len(areas), len(heading), len(items))])); sys.exit()
edge_l, edge_r = rows[search[0]]["box"][0], right(rows[search[0]])
check("content.leftInset", edge_l - rows[page[0]]["box"][0], inset)
check("content.rightInset", right(rows[page[0]]) - edge_r, inset)
check("search.right", edge_r, right(rows[areas[0]]) - inset)
check("heading.x", rows[heading[0]]["box"][0], edge_l)
placeholders = [j for j, r in enumerate(rows) if r["type"] == "Label" and r.get("text") == "Search plugins" and inside(j, search[0])]
if len(placeholders) != 1: out.append("placeholder=%d" % len(placeholders))
else: check("search.placeholder.y", mid_y(rows[placeholders[0]]), mid_y(rows[search[0]]))
for n, i in enumerate(items):
    item = rows[i]
    check("item%d.left" % n, item["box"][0], edge_l)
    check("item%d.right" % n, right(item), edge_r)
    icons = [j for j, r in enumerate(rows) if r["type"] == "Icon" and inside(j, i) and rows[r["parent"]]["parent"] == i]
    lines = [j for j, r in enumerate(rows) if r["type"] == "Label" and r.get("role") in ("item", "itemHint") and inside(j, i) and r["box"][3] > 0]
    if len(icons) != 1 or not lines: out.append("item%d icons=%d lines=%d" % (n, len(icons), len(lines))); continue
    icon = rows[icons[0]]
    check("item%d.icon.x" % n, icon["box"][0], edge_l + pad)
    check("item%d.icon.y" % n, mid_y(icon), mid_y(item))
    top = min(rows[j]["box"][1] for j in lines)
    bottom = max(rows[j]["box"][1] + rows[j]["box"][3] for j in lines)
    check("item%d.lines.y" % n, (top + bottom) / 2, mid_y(icon))
print(json.dumps(out))
PY
}
geometry expect_poll "the list's heading, search field and rows share its edges, each row's lines on its icon" '[]' list_alignment
page_header_height() {
  local rows
  rows="$(ipc smoke descendantGeometry window vgs.settings)" || return
  python3 - "$rows" "$1" <<'PY'
import json, sys
rows, page_type = json.loads(sys.argv[1]), sys.argv[2]
def inside(j, i):
    while j != -1:
        if j == i: return True
        j = rows[j]["parent"]
    return False
pages = [i for i, r in enumerate(rows) if r["type"] == page_type and r["box"][2] > 0 and r["box"][3] > 0]
if len(pages) != 1:
    print("pages=%d" % len(pages)); sys.exit()
headers = [rows[i] for i, r in enumerate(rows) if r["type"] == "PageHeader" and inside(i, pages[0]) and r["box"][2] > 0 and r["box"][3] > 0]
print(json.dumps(headers[0]["box"][3]) if len(headers) == 1 else "headers=%d" % len(headers))
PY
}
list_header_height="$(page_header_height ListPage)" || fail "the list page header row is unreadable"
[[ $list_header_height != *=* ]] || fail "the list page header row is unreadable: $list_header_height"
# The keyboard reaches the shown page alone: twelve steps of Tab and of
# Shift+Tab from the focused item stay on it, and a real Tab moves focus on
# it; the page slid out is hidden, not merely offscreen.
focus_pages() { ipc smoke focusChain window vgs.settings "$1" | py_reply 'import json,sys; t=sys.stdin.read(); print(json.dumps(sorted(set(json.loads(t)))) if t.startswith("[") else t.strip())'; }
expect_poll "Tab from the search field stays on the list" '["ListPage"]' focus_pages 12
expect_poll "Shift+Tab from the search field stays on the list" '["ListPage"]' focus_pages -12

# The list: one row per discovered plugin, the Settings plugin itself
# included, with its icon, source, capabilities, keys and errors.
rows_match() {
  local enabled
  enabled="$(ipc shell listPlugins | py_reply 'import json,sys; print(json.dumps({p["id"]: p["enabled"] for p in json.load(sys.stdin)["plugins"]}))')" && [[ $enabled == \{* ]] || { echo "$enabled"; return 1; }
  settings_rows | py_reply 'import json,sys; enabled, rows = json.loads(sys.argv[1]), json.load(sys.stdin); print(sorted(enabled) == [r["id"] for r in rows] and all(r["enabled"] == enabled[r["id"]] for r in rows))' "$enabled"
}
expect "the window lists every plugin listPlugins lists, with its state" True rows_match
row_of() { settings_rows | py_reply 'import json,sys; r=[r for r in json.load(sys.stdin) if r["id"] == sys.argv[1]][0]; print(json.dumps([r[k] for k in sys.argv[2:]]))' "$@"; }
expect "the Settings plugin lists itself, bundled, with its icon, capabilities and key" '["Settings", "settings", "bundled", ["ipc", "manager", "screens", "shortcut", "surfaces"], [{"shortcut": "toggle", "key": "SUPER+M", "default": "SUPER+M", "description": "Open or close Settings"}], []]' row_of vgs.settings name icon source capabilities binds errors
expect "an installed fixture is listed as installed with its manifest icon" '["Probe", "flask-conical", "installed", "acme"]' row_of acme.probe name icon source author
expect "a plugin without a manifest icon is listed with the package icon" '["package"]' row_of acme.bare icon
expect "a manager row carries each requirement with its state" '[[{"command": "sh", "packages": {"pacman": "bash"}, "optional": false, "purpose": "A command every sandbox has", "state": "present"}, {"command": "vgs-smoke-absent", "packages": {}, "optional": true, "purpose": "A command no sandbox has", "state": "missing"}]]' row_of acme.bare requirements

# The cursor over the list: the hand over each control that takes a click,
# the Add plugin button, a row, the switch in it and its chevron, which
# the row's click owns; the I-beam over the search field and the arrow over
# the heading, the controls that read no hand. Each shape differs from the
# reading before it, so each is a request the shell sent.
settings_box() { ipc smoke windowGeometry window vgs.settings "$1" "$2"; }
probe_row_box() { ipc smoke scopedWindowGeometry window vgs.settings ListItem Probe "$1" "$2"; }
expect_cursor "the search field shows the I-beam" text window:Settings "$(settings_box TextField "")"
expect_cursor "Add plugin shows the hand" pointer window:Settings "$(settings_box Button "Add plugin")"
expect_cursor "the list's heading shows the arrow" default window:Settings "$(settings_box Label Settings)"
expect_cursor "a plugin's row shows the hand" pointer window:Settings "$(settings_box ListItem Probe)"
expect_cursor "the search field shows the I-beam again" text window:Settings "$(settings_box TextField "")"
expect_cursor "the row's switch shows the hand" pointer window:Settings "$(probe_row_box Switch "")"
expect_cursor "the heading shows the arrow again" default window:Settings "$(settings_box Label Settings)"
expect_cursor "the row's chevron shows the hand" pointer window:Settings "$(probe_row_box Icon chevron-right)"

# A page: a click on a row opens it, drawn from the manifest alone; its
# schema's groups are its sections, in manifest order after the entries
# without one, and a bounded number is a slider.
settings_click ListItem Probe || fail "the click on the fixture's row failed"
expect_poll "a click on a row opens that plugin's page" '"acme.probe"' settings_page
expect_poll "Tab from the pushed page stays on it" '["PluginPage"]' focus_pages 12
expect_poll "Shift+Tab from the pushed page stays on it" '["PluginPage"]' focus_pages -12
type_keys -k Tab || fail "sending Tab to the page failed"
expect_poll "a real Tab keeps the focus on the page" '["PluginPage"]' focus_pages 0
header_height_pair() {
  local page_height
  page_height="$(page_header_height PluginPage)" || return
  python3 - "$1" "$page_height" <<'PY'
import json, sys
print(json.dumps([json.loads(sys.argv[1]), json.loads(sys.argv[2])]))
PY
}
geometry expect_poll "the list page and plugin page header rows share one measured height" "[$list_header_height, $list_header_height]" header_height_pair "$list_header_height"
section_names() { ipc smoke itemTexts window vgs.settings SectionHeader | py_reply 'import json,sys; print(json.dumps([t[0] for t in json.load(sys.stdin) if t]))'; }
expect_poll "the page draws one section per schema group, ungrouped first" '["Settings", "Layout", "Behaviour", "Look"]' section_names
page_fields() { ipc smoke drawnFields window vgs.settings | py_reply 'import json,sys; d=json.load(sys.stdin); print(json.dumps([d["acme.probe"], sum(v for k, v in d.items() if k != "acme.probe")]))'; }
expect_poll "the page draws one field per schema entry and no other plugin's" '[9, 0]' page_fields
sliders() { ipc smoke descendantGeometry window vgs.settings | py_reply 'import json,sys; print(sum(1 for r in json.load(sys.stdin) if r["type"] == "Slider"))'; }
expect "the two bounded numbers draw sliders" 2 sliders
# page_alignment SETTINGS KEYS: [] when the shown page draws SETTINGS
# setting fields and KEYS key rows and every inline field, the details and
# commands included, leaves equal insets around the content box, starts a
# field label on the content edge and its control `field.labelWidth` plus
# `field.labelGap` past that, ends the control on the content edge, puts
# section headers on the same edge and leaves the scroll bar inside the
# right inset. Unit mutations in tst_pane, tst_scroll and tst_spacing are
# the controls for these geometry rules. `[]` is the pass.
page_alignment() {
  local rows label_w label_gap inset
  rows="$(ipc smoke descendantGeometry window vgs.settings)" || return
  label_w="$(ipc smoke themeValue field.labelWidth)" || return
  label_gap="$(ipc smoke themeValue field.labelGap)" || return
  inset="$(ipc smoke themeValue inset.window)" || return
  python3 - "$rows" "$label_w" "$label_gap" "$inset" "$1" "$2" <<'PY'
import json, sys
rows, label_w, label_gap, inset, want_settings, want_keys = (json.loads(a) for a in sys.argv[1:])
out = []
def inside(j, i):
    while j != -1:
        if j == i: return True
        j = rows[j]["parent"]
    return False
def right(r): return r["box"][0] + r["box"][2]
def mid_y(r): return r["box"][1] + r["box"][3] / 2
def check(name, got, want):
    if abs(got - want) > 1: out.append("%s=%.2f want=%.2f" % (name, got, want))
page = [i for i, r in enumerate(rows) if r["type"] == "PluginPage"]
areas = [i for i, r in enumerate(rows) if r["type"] == "ScrollArea" and page and inside(i, page[0])]
if len(page) != 1 or len(areas) != 1:
    print(json.dumps(["pages=%d areas=%d" % (len(page), len(areas))])); sys.exit()
area = rows[areas[0]]
column_right = right(area) - inset
content_left = area["box"][0]
check("content.leftInset", content_left - rows[page[0]]["box"][0], inset)
check("content.rightInset", right(rows[page[0]]) - column_right, inset)
headers = [i for i, r in enumerate(rows) if r["type"] == "SectionHeader" and inside(i, page[0])]
for n, i in enumerate(headers):
    labels = [j for j, r in enumerate(rows) if r["type"] == "Label" and inside(j, i) and r.get("role") == "eyebrow"]
    if len(labels) != 1: out.append("section%d labels=%d" % (n, len(labels))); continue
    check("section%d.x" % n, rows[labels[0]]["box"][0], content_left)
fields = [i for i, r in enumerate(rows) if r["type"] in ("SettingField", "KeyField", "Field") and inside(i, page[0])]
counts = [sum(1 for i in fields if rows[i]["type"] == kind) for kind in ("SettingField", "KeyField")]
if counts != [want_settings, want_keys]: out.append("settings,keys=%s want=%s" % (counts, [want_settings, want_keys]))
for n, i in enumerate(fields):
    name = "%s%d" % (rows[i]["type"], n)
    left = rows[i]["box"][0]
    lines = [j for j, r in enumerate(rows) if r["type"] == "QQuickRow" and r["parent"] == i]
    if len(lines) != 1: out.append("%s rows=%d" % (name, len(lines))); continue
    labels = [j for j, r in enumerate(rows) if r["parent"] == lines[0] and r["type"] == "Label" and r.get("role") == "label"]
    slots = [j for j, r in enumerate(rows) if r["parent"] == lines[0] and r["type"] != "Label"]
    if len(labels) != 1 or len(slots) != 1: out.append("%s labels=%d slots=%d" % (name, len(labels), len(slots))); continue
    label, slot = rows[labels[0]], rows[slots[0]]
    values = [r for r in rows if r["parent"] == slots[0]]
    if len(values) != 1: out.append("%s values=%d" % (name, len(values))); continue
    check(name + ".left", left, content_left)
    check(name + ".label.x", label["box"][0], content_left)
    check(name + ".control.x", slot["box"][0], content_left + label_w + label_gap)
    check(name + ".control.right", right(slot), column_right)
    check(name + ".label.y", mid_y(label), mid_y(values[0]))
    # A value drawn with leading below its glyphs is centred as a box and
    # not as text.
    for j, r in enumerate(rows):
        if r["type"] in ("TextField", "Select") and inside(j, i): check(name + "." + r["type"] + ".right", right(r), column_right)
print(json.dumps(out))
PY
}
geometry expect_poll "the page's fields share one label edge, one control edge and one right edge, each label on its control" '[]' page_alignment 9 0

# The page scrolls under its bar: a drag on the thumb moves the content
# with it, and a press on the track under the thumb pages one view down.
page_scroll() { ipc smoke scrollAreas window vgs.settings | py_reply 'import json,sys; a=json.load(sys.stdin); print(json.dumps(a[0]) if len(a) == 1 else "areas=%d" % len(a))'; }
scroll_value() { page_scroll | py_reply 'import json,sys; t=sys.stdin.read(); a=json.loads(t) if t.startswith("{") else None; print(json.dumps([a[k] for k in sys.argv[1:]]) if a else t.strip())' "$@"; }
overflowing() { page_scroll | py_reply 'import json,sys; a=json.loads(sys.stdin.read()); print(json.dumps([a["contentHeight"] > a["height"], a["barVisible"], a["contentWidth"] < a["width"]]))'; }
expect_poll "the fixture's page overflows, shows its bar and leaves it a gutter" '[true, true, true]' overflowing
if area="$(page_scroll)" && [[ $area == \{* ]]; then
  read -r tx ty < <(at_centre window:Settings "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["thumb"]))' "$area")")
  thumb_top_before="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["thumb"][1])' "$area")"
  drag "$tx" "$ty" "$tx" "$((ty + 40))" || fail "the drag on the page's thumb failed"
  dragged() { page_scroll | py_reply 'import json,sys; a=json.loads(sys.stdin.read()); moved=a["thumb"][1]-float(sys.argv[1]); travel=a["bar"][3]-a["thumb"][3]; want=moved/travel*(a["contentHeight"]-a["height"]) if travel > 0 else -1; print(a["contentY"] > 0 and abs(moved - 40) <= 2 and abs(a["contentY"] - want) <= 2)' "$thumb_top_before"; }
  geometry expect_poll "a drag on the thumb moves it and scrolls the content with it" True dragged
  y_before="$(scroll_value contentY | py_reply 'import json,sys; print(json.load(sys.stdin)[0])')"
  # A 2 px box on the track just under the thumb.
  area="$(page_scroll)"
  read -r bx by < <(at_centre window:Settings "$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); b=a["bar"]; t=a["thumb"]; print(json.dumps([b[0], t[1] + t[3] + 2, b[2], 2]))' "$area")")
  click "$bx" "$by" || fail "the press on the page's track failed"
  paged() { page_scroll | py_reply 'import json,sys; a=json.loads(sys.stdin.read()); y=float(sys.argv[1]); print(abs(a["contentY"] - min(y + a["height"], a["contentHeight"] - a["height"])) <= 1)' "$y_before"; }
  geometry expect_poll "a press on the track under the thumb pages one view down" True paged
else
  fail "the fixture's page scroll area is unreadable: ${area:-}"
fi

# Update and Remove: an installed plugin's buttons open the manager's core
# TUIs for its id, the update wide for its diff and with no --yes, so each
# question stays a question on the terminal. The terminal is a newer
# window, which Hyprland focuses and stacks over the Settings window, and
# the Settings window stays open behind it; a held run keeps the terminal
# mapped while the row reads that. The stand-in terminal records the argv
# and runs none of it, so the plugin stays installed.
terminal_stand_in
terminal_ready "Settings' TUIs"
# settings_button TEXT: whether the window draws a shown Button TEXT.
settings_button() { ipc smoke windowGeometry window vgs.settings Button "$1" | py_reply 'import sys; print("absent" if sys.stdin.read().strip() == "absent" else "drawn")'; }
# How many floating TUI windows the nested instance maps.
tui_windows() { hypr -j clients | py_reply 'import json,sys; print(sum(1 for c in json.load(sys.stdin) if c["class"].startswith("org.vgs.tui")))'; }
settings_focused="[\"$shell_class\", \"Settings\"]"
# settings_show PAGE: the Settings window open on PAGE, "" for the list,
# whose slide has ended once the list's Add plugin button is hidden. A
# closed window is opened by the gear on its bar's monitor, the one the
# pointer reaches: a summon over IPC would open it on the focused monitor,
# which a floating terminal can have moved.
settings_show() {
  if [[ $(window_count Settings) == 0 ]]; then
    click_centre "$(bar_key)" vgs.settings || fail "the click on the gear failed"
    expect_poll "the gear opens the window again for ${1:-the list}" 1 window_count Settings
  fi
  if [[ -z $1 ]]; then
    expect "the window shows its list" '' ipc smoke invokeInstance window vgs.settings showList ''
    expect_poll "the window shows the list" '""' settings_page
    return 0
  fi
  expect "a row opens the page of $1" ok ipc smoke invokeInstance window vgs.settings openPlugin "$1"
  expect_poll "the window shows $1 again" "\"$1\"" settings_page
  expect_poll "the page of $1 has slid in" absent settings_button "Add plugin"
}
# The rows above scrolled the page; a new window opens it at its top.
expect "the scrolled window hides" ok ipc shell hide window vgs.settings
expect_poll "the scrolled window is gone" 0 window_count Settings
settings_show acme.probe
forget_record
hold_core
settings_click Button Update || fail "the click on Update failed"
expect_poll "Update opens vgsh plugin update for the plugin in the wide floating TUI" \
  "$(core_words core/plugin-update "Update a plugin" org.vgs.tui.wide plugin update acme.probe)" recorded
expect_poll "the update's terminal is focused over the Settings window" '["org.vgs.tui.wide", "VGS · Update a plugin"]' active_window
expect "Update leaves the Settings window open behind the terminal" 1 window_count Settings
release_core
expect_run_end "the update's run ends" core/plugin-update
expect_poll "the update's terminal closes" 0 tui_windows
expect_poll "the Settings window takes the focus back" "$settings_focused" active_window
expect "the window still shows the plugin's page" '"acme.probe"' settings_page
forget_record
settings_click Button Remove || fail "the click on Remove failed"
expect_poll "Remove opens vgsh plugin remove for the plugin in the floating TUI" \
  "$(core_words core/plugin-remove "Remove a plugin" org.vgs.tui plugin remove acme.probe)" recorded
expect "Remove leaves the Settings window open" 1 window_count Settings
expect_run_end "the remove's run ends" core/plugin-remove
expect_poll "the remove's terminal closes" 0 tui_windows
expect "the stand-in's run left the plugin installed" True plugin_known acme.probe
expect_poll "the Settings window has the focus after the remove" "$settings_focused" active_window

# A plugin that leaves the rows while its page is shown, as a removal's
# rescan takes it: the window returns to the list with a notice naming it.
# The plugin is a directory the row writes and removes; installed, it is
# listed and never enabled. Control: a change of the rows that keeps the
# plugin, another plugin's setting written and put back, keeps its page and
# shows no notice, so the return reads the plugin leaving and not a change
# of the rows.
gone_dir="$home/.config/vgs/plugins/acme.gone"
mkdir -p -- "$gone_dir"
printf '%s\n' '{ "schemaVersion": 1, "id": "acme.gone", "name": "Gone", "version": "0.1.0", "author": "acme", "description": "a plugin the Settings rows remove", "kinds": ["service"], "entryPoints": { "service": "Service.qml" } }' >"$gone_dir/manifest.json"
printf '%s\n' 'import QtQuick' 'Item { property var shell: null }' >"$gone_dir/Service.qml"
settings_notice() { ipc smoke readInstance window vgs.settings notice; }
expect "a rescan finds the plugin the row adds" ok ipc shell rescanPlugins
expect_poll "the added plugin is listed" True plugin_known acme.gone
settings_lists() { settings_rows | py_reply 'import json,sys; print(any(r["id"] == sys.argv[1] for r in json.load(sys.stdin)))' "$1"; }
expect_poll "the window lists the added plugin" True settings_lists acme.gone
settings_show acme.gone
probe_label() { row_of acme.probe settings | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)[0]["label"]))'; }
label_before="$(probe_label)" || fail "the fixture's label is unreadable"
expect "control: writing another plugin's setting is allowed" ok ipc smoke invokeInstance window vgs.settings applySetting '{"id":"acme.probe","key":"label","value":"rows-change"}'
expect_poll "control: the window's rows show the other plugin's setting" '"rows-change"' probe_label
expect "control: a change of the rows that keeps the plugin keeps its page" '"acme.gone"' settings_page
expect "control: a change of the rows that keeps the plugin shows no notice" '""' settings_notice
expect "control: putting the setting back is allowed" ok ipc smoke invokeInstance window vgs.settings applySetting "{\"id\":\"acme.probe\",\"key\":\"label\",\"value\":$label_before}"
expect_poll "control: the window's rows show the setting put back" "$label_before" probe_label
rm -r -- "$gone_dir"
expect "a rescan after the plugin's directory goes is allowed" ok ipc shell rescanPlugins
expect_poll "the removed plugin leaves the rows" False plugin_known acme.gone
expect_poll "the window returns to the list when the shown plugin leaves" '""' settings_page
expect_poll "the list names the plugin that left" '"acme.gone is no longer listed."' settings_notice
settings_show acme.probe

# The title's menu lists every plugin with the current one checked, scrolls
# past its maximum height under its own bar, and typed letters then Enter
# jump to another plugin's page.
title_menu() { ipc smoke menus window vgs.settings | py_reply 'import json,sys; m=json.load(sys.stdin); print(json.dumps([m[0][k] for k in sys.argv[1:]]) if len(m) == 1 else "menus=%d" % len(m))' "$@"; }
settings_click TitleButton Probe || fail "the click on the page's title failed"
expect_poll "a click on the title opens its menu on the current plugin" '[true, ["Probe"], "Probe"]' title_menu opened checked current
expect "the title's menu anchors to the title button" '["TitleButton"]' title_menu anchorType
menu_lists_all() {
  local names
  names="$(settings_rows | py_reply 'import json,sys; print(json.dumps([r["name"] for r in json.load(sys.stdin)]))')" && [[ $names == \[* ]] || { echo "$names"; return 1; }
  title_menu entries | py_reply 'import json,sys; print(json.load(sys.stdin)[0] == json.loads(sys.argv[1]))' "$names"
}
expect "the title's menu lists every plugin by name" True menu_lists_all
expect "the long menu scrolls under its own bar" '[true, true]' title_menu overflowing barVisible
type_keys set || fail "typing into the title's menu failed"
expect_poll "typed letters highlight the plugin whose name starts with them" '["Settings"]' title_menu current
type_keys -k Return || fail "sending Return to the title's menu failed"
expect_poll "Enter jumps to that plugin's page" '"vgs.settings"' settings_page
expect_poll "a bundled plugin's page draws no Update button" absent settings_button Update
expect "a bundled plugin's page draws no Remove button" absent settings_button Remove
geometry expect_poll "the Settings page's key row ends on the settings fields' right edge, its label on its field" '[]' page_alignment 0 1
expect_poll "the jump closes the menu" '[false]' title_menu opened

# Keys: the Settings plugin's own page edits its shortcut's key. A key
# rebinds, an emptied field unbinds, the reset button returns to the
# manifest's key, each written to its shell.json keys and reaching the
# Hyprland layer; a malformed key is refused and shown on the page.
expect "a key typed in the Keys row is applied" applied ipc smoke invokeInstance window vgs.settings applyKey '{"id":"vgs.settings","shortcut":"toggle","key":"shift+super+m"}'
expect_poll "the rebind reaches shell.json keys, normalised" '"SUPER+SHIFT+M"' user_key
expect_poll "the rebind reaches the Hyprland layer" '[[65, "M"]]' settings_binds
expect_poll "the page's Keys row shows the key in effect beside its default" '[[{"shortcut": "toggle", "key": "SUPER+SHIFT+M", "default": "SUPER+M", "description": "Open or close Settings"}]]' row_of vgs.settings binds
expect "an emptied key unbinds the shortcut" applied ipc smoke invokeInstance window vgs.settings applyKey '{"id":"vgs.settings","shortcut":"toggle","key":null}'
expect_poll "the unbind reaches shell.json keys as null" null user_key
expect_poll "the unbind leaves Hyprland no Settings bind" '[]' settings_binds
expect "the reset button returns the shortcut to the manifest's key" applied ipc smoke invokeInstance window vgs.settings applyKey '{"id":"vgs.settings","shortcut":"toggle"}'
expect_poll "the reset removes the shell.json entry" absent user_key
expect_poll "the reset binds SUPER+M again" '[[64, "M"]]' settings_binds
expected_errors+=('settings: vgs\.settings refused: key=toggle has an empty part')
expect "a malformed key typed in the Keys row is sent" applied ipc smoke invokeInstance window vgs.settings applyKey '{"id":"vgs.settings","shortcut":"toggle","key":"SUPER+"}'
expect "the page shows the key's refusal" '{"vgs.settings":"refused: key=toggle has an empty part: \"SUPER+\""}' ipc smoke readInstance window vgs.settings replies
expect "the refused key left shell.json alone" absent user_key
expect "a reset after the refusal is applied" applied ipc smoke invokeInstance window vgs.settings applyKey '{"id":"vgs.settings","shortcut":"toggle"}'
expect "the accepted key clears the page's refusal" '{}' ipc smoke readInstance window vgs.settings replies
# A problem the Hyprland layer reports for a plugin, a `keys` name its
# manifest binds nothing under, is among that plugin's errors on its row,
# as in listPlugins, and the list's badge counts it.
settings_keys_row() { # JSON object: the Settings row's keys, replaced whole
  python3 - "$user_file" "$1" <<'PY'
import json, os, sys
path, keys = sys.argv[1], json.loads(sys.argv[2])
doc = json.load(open(path))
rows = doc.setdefault("plugins", [])
row = [r for r in rows if r["id"] == "vgs.settings"]
if not row:
    rows.append({"id": "vgs.settings"})
    row = rows[-1:]
if keys: row[0]["keys"] = keys
else: row[0].pop("keys", None)
json.dump(doc, open(path + ".tmp", "w"), indent=2)
os.replace(path + ".tmp", path)
PY
}
listed_problem() { ipc shell listPlugins | py_reply 'import json,sys; print(json.dumps([e["error"] for e in json.load(sys.stdin)["errors"] if "vgs.settings" in e["error"]]))'; }
settings_badge() { ipc smoke itemTexts window vgs.settings ListItem | py_reply 'import json,sys; print(json.dumps([t for t in json.load(sys.stdin) if t[0] == "Settings"]))'; }
settings_keys_row '{"nope": "SUPER+F9"}'
expect_poll "a keys name no bind declares is among the plugin's errors" '[["hyprland: shell.json keys.nope names no bind of vgs.settings"]]' row_of vgs.settings errors
expect "listPlugins reads the same problem" '["hyprland: shell.json keys.nope names no bind of vgs.settings"]' listed_problem

# Back: the back button and Escape pop the page; Escape on the list hides
# the window.
settings_click IconButton "Back to the plugin list" || fail "the click on the back button failed"
expect_poll "the back button returns to the list" '""' settings_page
expect_poll "Tab after the pop stays on the list" '["ListPage"]' focus_pages 12
expect_poll "the list's row carries a badge counting the error" '[["Settings", "0.1.0  Bundled", "1"]]' settings_badge
settings_keys_row '{}'
expect_poll "the plugin's errors clear with the problem" '[[]]' row_of vgs.settings errors

# Add plugin: the list's button opens the core's plugin add, which asks for
# the git URL on the terminal. A held run leaves the key busy, and a second
# Add plugin from the focused Settings window focuses the live terminal
# through the shared shown answer. The terminal covers the window, so the
# second request is the window's own call, as its button makes it.
forget_record
hold_core
settings_click Button "Add plugin" || fail "the click on Add plugin failed"
expect_poll "Add plugin opens vgsh plugin add in the floating TUI" "$(core_words core/plugin-add "Add a plugin" org.vgs.tui plugin add)" recorded
expect_poll "the add's terminal is focused over the Settings window" '["org.vgs.tui", "VGS · Add a plugin"]' active_window
expect "Add plugin leaves the Settings window open" 1 window_count Settings
# The colour at the Settings window's centre: the stand-in terminal, the
# toplevel helper, fills its window with 336699.
settings_centre_pixel() {
  local box x y
  box="$(one_window Settings)" && [[ $box == \[* ]] || { echo "$box"; return; }
  read -r x y < <(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); print(b[0] + b[2] // 2, b[1] + b[3] // 2)' "$box")
  pixel "$x" "$y"
}
render expect_poll "the add's terminal draws over the Settings window" 336699 settings_centre_pixel
expect_poll "the add's run is live under the hold" busy key_idle core/plugin-add
if settings_address="$(window_of Settings address)" && [[ $settings_address == \[\"0x* ]]; then
  settings_address="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0])' "$settings_address")"
  expect "a focus dispatch gives the Settings window the focus over the live terminal" ok hypr dispatch "hl.dsp.focus({ window = \"address:$settings_address\" })"
  expect_poll "the Settings window is focused over the live terminal" "$settings_focused" active_window
else
  fail "the Settings window's address is unreadable: ${settings_address:-}"
fi
expect "busy Add plugin answers ok" ok ipc smoke invokeInstance window vgs.settings addPlugin ''
expect_poll "busy Add plugin focuses the live terminal" '["org.vgs.tui", "VGS · Add a plugin"]' active_window
expect "busy Add plugin leaves the Settings window open" 1 window_count Settings
expect_poll "the add's run stays live until release" busy key_idle core/plugin-add
release_core
expect_run_end "the add's run ends" core/plugin-add
expect_poll "the add's terminal closes" 0 tui_windows

# Requirements: one row per requirement with its state from the scan and
# its purpose, and Install, while one is missing, shows the core's
# requirement notice for the plugin with every missing command, the
# optional one included, over the window, which stays open; Escape closes
# the notice.
settings_show acme.bare
has_section() { ipc smoke itemTexts window vgs.settings SectionHeader | py_reply 'import json,sys; print(sys.argv[1] in [t[0] for t in json.load(sys.stdin) if t])' "$1"; }
expect_poll "the page draws a Requirements section" True has_section Requirements
requirement_texts() { ipc smoke itemTexts window vgs.settings RequirementRow | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)))'; }
expect_poll "each requirement reads back with its state and purpose" '[["sh", "Present", "A command every sandbox has"], ["vgs-smoke-absent", "Missing, optional", "A command no sandbox has"]]' requirement_texts
click_install() {
  local area bx by
  for _ in $(seq 1 6); do
    if install_visible; then settings_click Button Install && return 0; fi
    area="$(page_scroll)" || return 1
    [[ $area == \{* ]] || return 1
    [[ $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["barVisible"])' "$area") == True ]] || return 1
    read -r bx by < <(at_centre window:Settings "$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); b=a["bar"]; t=a["thumb"]; print(json.dumps([b[0], t[1] + t[3] + 2, b[2], 2]))' "$area")")
    click "$bx" "$by" || return 1
    sleep 0.2
  done
  return 1
}
install_visible() {
  local area rect
  area="$(page_scroll)" || return 1
  rect="$(ipc smoke windowGeometry window vgs.settings Button Install)" || return 1
  [[ $area == \{* && $rect == \[* ]] || return 1
  python3 -c 'import json,sys
a=json.loads(sys.argv[1]); x,y,w,h=json.loads(sys.argv[2]); top=a["bar"][1]; bottom=top+a["height"]; print(top <= y and y+h <= bottom)' "$area" "$rect" | grep -Fx True >/dev/null
}
click_install || fail "the click on Install failed"
expect_poll "Install shows the requirement notice with the optional command" '["acme.bare", ["vgs-smoke-absent"], ["vgs-smoke-absent"], false]' notice_shown
expect "Install leaves the Settings window open under the notice" 1 window_count Settings
expect_poll "the Settings request's notice holds the keyboard" true ipc smoke noticeFocused
type_keys -k Escape || fail "sending Escape to the notice failed"
expect_poll "Escape closes the Settings request's notice" null notice_shown
settings_show ""
expect "a row opens its page by name" ok ipc smoke invokeInstance window vgs.settings openPlugin acme.probe
expect_poll "the page is open again" '"acme.probe"' settings_page
type_keys -k Escape || fail "sending Escape to the page failed"
expect_poll "Escape pops the page" '""' settings_page
type_keys -k Escape || fail "sending Escape to the list failed"
expect_poll "Escape on the list hides the window" 0 window_count Settings

# Deep links: a summon's payload opens one plugin's page, an unknown id
# opens the list with a notice naming it, and any other key refuses the
# summon. The shortcut and the plugin's IPC open it too.
expect "a deep link summons the Settings window" ok ipc shell summon window vgs.settings '{"plugin":"acme.probe"}'
expect_poll "the deep link opens that plugin's page" '"acme.probe"' settings_page
expect "a deep link to an id no plugin has is accepted" ok ipc shell summon window vgs.settings '{"plugin":"acme.nowhere"}'
expect_poll "an unknown id opens the list" '""' settings_page
notice_names() { ipc smoke readInstance window vgs.settings notice | py_reply 'import json,sys; print("acme.nowhere" in json.load(sys.stdin))'; }
expect "the list's notice names the unknown id" True notice_names
expected_errors+=('summon host: vgs\.settings open\(\) failed: payload key "page" unknown')
expect "a payload key other than plugin refuses the summon" "refused: open-failed=vgs.settings" ipc shell summon window vgs.settings '{"page":"x"}'
expect_poll "the refused summon leaves no window" 0 window_count Settings
expect "the plugin's IPC opens a page" ok ipc vgs.settings invoke open '{"plugin":"vgs.bar"}'
expect_poll "the IPC deep link opens that page" '"vgs.bar"' settings_page
expect "the compositor's shortcut toggles the window closed" ok hypr dispatch 'hl.dsp.global("vgs.settings:toggle")'
expect_poll "the shortcut closed the window" 0 window_count Settings
expect "the compositor's shortcut toggles the window open" ok hypr dispatch 'hl.dsp.global("vgs.settings:toggle")'
expect_poll "the shortcut opened the window" open settings_open
geometry expect_poll "the shortcut's window fits the focused monitor" '[]' window_fits "$main_monitor"
expect "the shortcut toggles it closed again" ok hypr dispatch 'hl.dsp.global("vgs.settings:toggle")'
expect_poll "the window is gone after the shortcut" 0 window_count Settings

# A monitor narrower than the window's width token: the nested output
# holds a 480 by 720 mode, and the window keeps `size.window.gutter` a side
# and half the monitor's height, centred on it; the mode it had is then
# restored, so later rows meet the monitor they read at the start. The host
# can reset a held mode under the rows (held_mode_state in harness.sh): the
# window check reads the mode with the window and names a reset rather than
# measuring the window against it.
narrow_mode=480x720
main_mode="$(first_mode)" || fail "the monitor's mode is unreadable"
hold_mode "the nested compositor makes its monitor narrower than the window" "$main_monitor" "$narrow_mode"
expect_poll "the monitor is 480 logical pixels wide" 480 first_width
bar_width() { one_layer vgs:bar | py_reply 'import json,sys; print(json.load(sys.stdin)[2])'; }
expect_poll "the bar follows the narrow monitor" 480 bar_width
expect "the gear opens the window on the narrow monitor" ok ipc smoke invokeInstance "$(bar_key)" vgs.settings toggle ''
expect_poll "the window maps on the narrow monitor" 1 window_count Settings
geometry expect_poll "a monitor narrower than the width token keeps the gutters, half its height, centred" '[]' window_fits "$main_monitor" "$narrow_mode"
clamped_width() { settings_layer | py_reply 'import json,sys; print(json.load(sys.stdin)[2])'; }
gutter="$(ipc smoke themeValue size.window.gutter)" || fail "the gutter token is unreadable"
geometry expect "the clamped window is the monitor's width less two gutters" "$((480 - 2 * gutter))" clamped_width
# Control: the monitor's own mode comes back under the held row, as a host
# configure brings it. The window check names the reset instead of
# measuring the window against the monitor it now reads, and the hold reads
# reset, the state that excuses a failing row as not measured.
expect "the monitor's own mode comes back under the held row" ok output_mode "$main_monitor" "$main_mode"
expect_poll "the window check names the mode reset under the held row" "[\"mode=$main_mode want=$narrow_mode\"]" window_fits "$main_monitor" "$narrow_mode"
expect "the hold reads the reset" reset held_mode_state
release_mode "the nested compositor restores its monitor's mode" "$main_monitor" "$main_mode"
expect "the gear closes the window" ok ipc smoke invokeInstance "$(bar_key)" vgs.settings toggle ''
expect_poll "the window is gone" 0 window_count Settings
expect_poll "the monitor has its width back" "$mon_w" first_width
expect_poll "the bar follows the restored monitor" "$mon_w" bar_width

# Enable and disable, and a setting, through the page.
expect "the deep link reopens the fixture's page" ok ipc shell summon window vgs.settings '{"plugin":"acme.probe"}'
expect_poll "the fixture's page is open" '"acme.probe"' settings_page
manager_rows() { settings_rows | py_reply 'import json,sys; rows=json.load(sys.stdin); print(json.dumps({r["id"]: r["enabled"] for r in rows if r["id"] in ("acme.probe", "acme.bare", "vgs.bar")}, sort_keys=True))'; }
expect "the window toggles the fixture off" ok ipc smoke invokeInstance window vgs.settings toggle acme.probe
expect_poll "listPlugins reads the fixture disabled" False plugin_enabled acme.probe
expect_poll "the window shows the fixture disabled" '{"acme.bare": true, "acme.probe": false, "vgs.bar": true}' manager_rows
# The window logs each refusal it shows on a page.
expected_errors+=('settings: acme\.probe refused: disabled=acme\.probe' 'settings: acme\.probe refused: setting=tags undeclared' 'settings: acme\.probe refused: setting=size want=at-most:40')
expect "the window refuses a setting for a disabled plugin" "refused: disabled=acme.probe" ipc smoke invokeInstance window vgs.settings applySetting '{"id":"acme.probe","key":"label","value":"x"}'
expect "the page shows the refusal" '{"acme.probe":"refused: disabled=acme.probe"}' ipc smoke readInstance window vgs.settings replies
expect "the window toggles the fixture back on" ok ipc smoke invokeInstance window vgs.settings toggle acme.probe
expect_poll "listPlugins reads the fixture enabled" True plugin_enabled acme.probe
expect "the window writes the fixture's setting" ok ipc smoke invokeInstance window vgs.settings applySetting '{"id":"acme.probe","key":"label","value":"via-manager"}'
expect "a successful write clears the page's refusal" '{}' ipc smoke readInstance window vgs.settings replies
expect_poll "the running service received the window's setting" '"via-manager"' read_service label
expect_poll "the running widget received the window's setting" '"via-manager"' read_widget label
manager_label() { settings_rows | py_reply 'import json,sys; print(json.dumps([r["settings"]["label"] for r in json.load(sys.stdin) if r["id"]=="acme.probe"][0]))'; }
expect "the fixture's drawn label field applies an edit" applied ipc smoke invokeInstance window vgs.settings applyField '{"id":"acme.probe","key":"label","value":"via-field"}'
expect_poll "the window reads back the setting the field wrote" '"via-field"' manager_label
manager_size() { settings_rows | py_reply 'import json,sys; print(json.dumps([r["settings"]["size"] for r in json.load(sys.stdin) if r["id"]=="acme.probe"][0]))'; }
expect "the fixture's drawn slider applies a value" applied ipc smoke invokeInstance window vgs.settings applyField '{"id":"acme.probe","key":"size","value":20}'
expect_poll "the window reads back the slider's value" 20 manager_size
expect "a number past its max is refused" "refused: setting=size want=at-most:40" ipc smoke invokeInstance window vgs.settings applySetting '{"id":"acme.probe","key":"size","value":41}'
expect "the window refuses a setting outside the schema" "refused: setting=tags undeclared" ipc smoke invokeInstance window vgs.settings applySetting '{"id":"acme.probe","key":"tags","value":"x"}'
expect "a later write clears the refusal" ok ipc smoke invokeInstance window vgs.settings applySetting '{"id":"acme.probe","key":"size","value":12}'

# The Settings plugin disabled from its own page closes its window and
# takes its gear away; setPluginEnabled brings both back.
expect "the window opens its own page" ok ipc smoke invokeInstance window vgs.settings openPlugin vgs.settings
expect "the window disables its own plugin" ok ipc smoke invokeInstance window vgs.settings toggle vgs.settings
expect_poll "listPlugins reads the Settings plugin disabled" False plugin_enabled vgs.settings
expect_poll "the disabled plugin's window is gone" 0 window_count Settings
gear_gone() { bar_widget_ids | py_reply 'import json,sys; print(all("vgs.settings" not in ids for ids in json.load(sys.stdin)))'; }
expect_poll "the disabled plugin's gear left every bar" True gear_gone
expect "enabling the Settings plugin again is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect_poll "the gear is back in every bar" True gear_placed

# The bar's built-ins: the manager built-in is gone, and a user row still
# naming it draws nothing and is logged with the command that places the
# Settings gear.
bar_row() { # [SECTION] JSON list of built-ins for that section, right by default
  local section=right
  [[ $# -eq 2 ]] && { section="$1"; shift; }
  python3 - "$home/.config/vgs/shell.json" "$1" "$section" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
rows = d.setdefault("plugins", [])
row = [e for e in rows if e["id"] == "vgs.bar"]
if not row:
    rows.append({"id": "vgs.bar"})
    row = rows[-1:]
row[0][sys.argv[3]] = json.loads(sys.argv[2])
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
}
expected_errors+=('bar: no built-in widget named "manager": the plugin manager moved to the Settings plugin, vgs\.settings; `vgsh plugin enable vgs\.settings` places its gear in the bar')
bar_row '["manager"]'
expect_log "a user row naming the retired manager built-in is logged by every bar" "$monitors" 'the plugin manager moved to the Settings plugin, vgs\.settings; `vgsh plugin enable vgs\.settings` places its gear in the bar'
expect_builtins "the retired manager built-in draws nothing" '["vgs.bar/center-clock","vgs.bar/left-workspaces"]'
bar_row '["clock"]'
expect_builtins "a built-in listed in the right section registers there" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-clock"]'
bar_row left '["clock","workspaces"]'
expect_builtins "the same built-in in two sections registers in both" '["vgs.bar/center-clock","vgs.bar/left-clock","vgs.bar/left-workspaces","vgs.bar/right-clock"]'
bar_row center '[]'
expect_builtins "moving and reordering built-ins keeps every one registered" '["vgs.bar/left-clock","vgs.bar/left-workspaces","vgs.bar/right-clock"]'
read_moved_clock() { ipc smoke readInstance "$(bar_key)" vgs.bar/left-clock format; }
expect "the moved clock is the registered one" '"HH:mm:ss"' read_moved_clock
bar_row left '["workspaces"]'
bar_row center '["clock"]'
bar_row '[]'
expect_builtins "the built-ins return to their sections" '["vgs.bar/center-clock","vgs.bar/left-workspaces"]'
# A name listed twice in one section is drawn once and the repeat logged by
# every bar; the logged line proves the bar read the setting.
expected_errors+=('vgs\.bar: setting left lists a built-in twice, drawn once: ')
bar_row left '["workspaces","workspaces"]'
expect_log "a built-in listed twice in one section is logged by every bar" "$monitors" 'vgs\.bar: setting left lists a built-in twice, drawn once: '
expect_builtins "a built-in listed twice in one section registers once" '["vgs.bar/center-clock","vgs.bar/left-workspaces"]'
bar_row left '["workspaces"]'

# Each bar stays alive while its built-ins change. The pending callbacks
# must describe only its current capability holds and live built-ins.
bar_cleanup_balanced() {
  ipc shell built | py_reply 'import json,sys; d=json.load(sys.stdin); bars=[rows for key,rows in d.items() if key.startswith("bar:")]; print(len(bars)==int(sys.argv[1]) and all(len([r for r in rows if r["id"]=="vgs.bar"])==1 and all(r["pendingCleanups"]==len(r["capabilities"])+sum(b["origin"]=="plugin" for b in rows) for r in rows if r["id"]=="vgs.bar") for rows in bars))' "$monitors"
}
builtin_builds_before="$(builds)"
for builtin_cycle in {1..12}; do
  bar_row '["clock"]'
  expect_builtins "built-in cleanup cycle $builtin_cycle adds a right clock" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-clock"]'
  expect_poll "built-in cleanup cycle $builtin_cycle keeps only live callbacks" True bar_cleanup_balanced
  bar_row '[]'
  expect_builtins "built-in cleanup cycle $builtin_cycle removes the right clock" '["vgs.bar/center-clock","vgs.bar/left-workspaces"]'
  expect_poll "built-in cleanup cycle $builtin_cycle forgets released callbacks" True bar_cleanup_balanced
  expect "built-in cleanup cycle $builtin_cycle preserves the bar lifetime" "$builtin_builds_before" builds
done
