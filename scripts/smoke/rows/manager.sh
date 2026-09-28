# The plugin manager: the bar's manager button opens the bar's own panel
# under it, which lists every plugin, toggles one through the core's
# setPluginEnabled path and writes a setting through its form.
set -euo pipefail
read -r mon_w mon_h bar_reserved < <(monitor_size)
expect "the manager button opens the manager panel" ok ipc smoke invokeInstance "$(bar_key)" vgs.bar/right-manager toggle ''
# The manager panel is a popup under its button, read back from the
# instance; its window position is relative to the bar's, which starts at
# the screen's top-left corner.
panel_top() { ipc smoke instanceGeometry panel vgs.bar | python3 -c 'import json,sys; print(json.load(sys.stdin)[1])'; }
geometry expect_poll "the manager panel sits under the bar" "$bar_reserved" panel_top
manager_rows() { ipc smoke readInstance panel vgs.bar plugins | python3 -c 'import json,sys; rows=json.load(sys.stdin); print(json.dumps({r["id"]: r["enabled"] for r in rows if r["id"] in ("acme.probe", "acme.bare", "vgs.bar")}, sort_keys=True))'; }
expect "the manager panel lists every plugin with its state" '{"acme.bare": true, "acme.probe": true, "vgs.bar": true}' manager_rows
# The panel draws one field per key of each row's schema; the rows it holds
# carry the schema keys the fields come from, and drawnFields counts the
# fields each form's Repeater drew.
manager_fields() { ipc smoke readInstance panel vgs.bar plugins | python3 -c 'import json,sys; by={r["id"]: sorted(r["schema"]) for r in json.load(sys.stdin)}; print(json.dumps([by["acme.probe"], by["vgs.bar"], by["acme.bare"]]))'; }
expect "the manager panel holds the schema keys its form draws" '[["label"], ["clockFormat"], []]' manager_fields
manager_drawn() { ipc smoke drawnFields panel vgs.bar | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([d.get("acme.probe"), d.get("vgs.bar"), d.get("acme.bare")]))'; }
expect_poll "the manager panel draws one field per schema key" '[1, 1, 0]' manager_drawn
expect "the manager toggles the fixture off" ok ipc smoke invokeInstance panel vgs.bar toggle acme.probe
expect_poll "listPlugins reads the fixture disabled" False plugin_enabled acme.probe
expect_poll "the manager panel shows the fixture disabled" '{"acme.bare": true, "acme.probe": false, "vgs.bar": true}' manager_rows
# The panel logs each refusal it shows on a row.
expected_errors+=('manager panel: acme\.probe refused: disabled=acme\.probe' 'manager panel: acme\.probe refused: setting=tags undeclared')
expect "the manager refuses a setting for a disabled plugin" "refused: disabled=acme.probe" ipc smoke invokeInstance panel vgs.bar applySetting '{"id":"acme.probe","key":"label","value":"x"}'
expect "the manager panel shows the refusal on the plugin's row" '{"acme.probe":"refused: disabled=acme.probe"}' ipc smoke readInstance panel vgs.bar replies
# Every row of the panel starts on one left edge, `row.paddingX` in from
# the list: the heading's lines, each list item's icon, each reply (one is
# shown now; the rest hold their place empty) and each field's inline
# label. Every field control
# starts `field.labelWidth` plus `field.labelGap` past that edge, and each
# list item's switch and each full-width field control end `row.paddingX`
# in from the list's right. The list's edges are the list items' boxes,
# which span it. Answers the misplaced items, so `[]` is the pass, within
# one pixel.
manager_alignment() {
  local rows pad label_w label_gap
  rows="$(ipc smoke descendantGeometry panel vgs.bar)" || return
  pad="$(ipc smoke themeValue row.paddingX)" || return
  label_w="$(ipc smoke themeValue field.labelWidth)" || return
  label_gap="$(ipc smoke themeValue field.labelGap)" || return
  python3 - "$rows" "$pad" "$label_w" "$label_gap" <<'PY'
import json, sys
rows, pad, label_w, label_gap = (json.loads(a) for a in sys.argv[1:])
out = []
def near(a, b): return abs(a - b) <= 1
def check(name, got, want):
    if not near(got, want): out.append("%s=%.2f want=%.2f" % (name, got, want))
def left(r): return r["box"][0]
def right(r): return r["box"][0] + r["box"][2]
def ancestor(i, kind):
    i = rows[i]["parent"]
    while i != -1:
        if rows[i]["type"] == kind: return i
        i = rows[i]["parent"]
    return None
def of(kind): return [i for i, r in enumerate(rows) if r["type"] == kind]
def labels(parent, role): return [j for j, r in enumerate(rows) if r["type"] == "Label" and r.get("role") == role and r["parent"] == parent]
items, fields, headers = of("ListItem"), of("SettingField"), of("SectionHeader")
if len(items) < 3: out.append("list items=%d" % len(items))
if len(fields) < 2: out.append("fields=%d" % len(fields))
if len(headers) != 1: out.append("headers=%d" % len(headers))
if out:
    print(json.dumps(out))
    sys.exit()
edge_l, edge_r = left(rows[items[0]]), right(rows[items[0]])
start, end = edge_l + pad, edge_r - pad
for n, i in enumerate(items):
    check("item%d.left" % n, left(rows[i]), edge_l)
    check("item%d.right" % n, right(rows[i]), edge_r)
    icons = [j for j in of("Icon") if ancestor(j, "ListItem") == i]
    switches = [j for j in of("Switch") if ancestor(j, "ListItem") == i]
    if len(icons) != 1 or len(switches) != 1: out.append("item%d icons=%d switches=%d" % (n, len(icons), len(switches)))
    for j in icons: check("item%d.icon.x" % n, left(rows[j]), start)
    for j in switches: check("item%d.switch.right" % n, right(rows[j]), end)
for i in headers:
    lines = labels(i, "eyebrow") + labels(i, "hint")
    if len(lines) != 2: out.append("header lines=%d" % len(lines))
    for j in lines: check("header.%s.x" % rows[j]["role"], left(rows[j]), start)
for n, i in enumerate(fields):
    inline = [j for j, r in enumerate(rows) if r["type"] == "Label" and r.get("role") == "label" and r["parent"] != -1 and rows[r["parent"]]["type"] == "QQuickRow" and rows[r["parent"]]["parent"] == i]
    controls = [j for j, r in enumerate(rows) if r["type"] in ("TextField", "Select", "Switch") and r["parent"] != -1 and rows[r["parent"]]["type"] == "QQuickLoader" and ancestor(j, "SettingField") == i]
    if len(inline) != 1 or len(controls) != 1: out.append("field%d labels=%d controls=%d" % (n, len(inline), len(controls)))
    for j in inline: check("field%d.label.x" % n, left(rows[j]), start)
    for j in controls:
        check("field%d.%s.x" % (n, rows[j]["type"]), left(rows[j]), start + label_w + label_gap)
        if rows[j]["type"] != "Switch": check("field%d.%s.right" % (n, rows[j]["type"]), right(rows[j]), end)
replies = [j for j, r in enumerate(rows) if r["type"] == "Label" and r.get("role") == "hint" and any(rows[k]["parent"] == r["parent"] for k in items)]
if len(replies) != len(items): out.append("replies=%d items=%d" % (len(replies), len(items)))
for n, j in enumerate(replies):
    check("reply%d.x" % n, left(rows[j]), start)
    check("reply%d.right" % n, right(rows[j]), end)
print(json.dumps(out))
PY
}
geometry expect_poll "the manager panel's rows share one left edge" '[]' manager_alignment
expect "the manager toggles the fixture back on" ok ipc smoke invokeInstance panel vgs.bar toggle acme.probe
expect_poll "listPlugins reads the fixture enabled" True plugin_enabled acme.probe
expect "the manager form writes the fixture's setting" ok ipc smoke invokeInstance panel vgs.bar applySetting '{"id":"acme.probe","key":"label","value":"via-manager"}'
expect "a successful write clears the row's refusal" '{}' ipc smoke readInstance panel vgs.bar replies
expect_poll "the running service received the manager's setting" '"via-manager"' read_service label
expect_poll "the running widget received the manager's setting" '"via-manager"' read_widget label
# A drawn field's apply, as an edit in the form emits it, writes through
# writeSetting; the manager's rows read the setting back.
manager_label() { ipc smoke readInstance panel vgs.bar plugins | python3 -c 'import json,sys; print(json.dumps([r["settings"]["label"] for r in json.load(sys.stdin) if r["id"]=="acme.probe"][0]))'; }
expect "the fixture's drawn label field applies an edit" applied ipc smoke invokeInstance panel vgs.bar applyField '{"id":"acme.probe","key":"label","value":"via-field"}'
expect_poll "the manager reads back the setting the field wrote" '"via-field"' manager_label
expect "the manager refuses a setting outside the schema" "refused: setting=tags undeclared" ipc smoke invokeInstance panel vgs.bar applySetting '{"id":"acme.probe","key":"tags","value":"x"}'
expect "the manager button closes the manager panel" ok ipc smoke invokeInstance "$(bar_key)" vgs.bar/right-manager toggle ''
expect_poll "the manager panel is gone" 0 layer_count vgs:panel
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
bar_row '[]'
expect_builtins "hiding the manager in the bar's settings removes it from every screen" '["vgs.bar/center-clock","vgs.bar/left-workspaces"]'
bar_row '["manager"]'
expect_builtins "listing the manager again brings it back on every screen" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
bar_row left '["clock","workspaces"]'
expect_builtins "the same built-in in two sections registers in both" '["vgs.bar/center-clock","vgs.bar/left-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
bar_row center '[]'
expect_builtins "moving and reordering built-ins keeps every one registered" '["vgs.bar/left-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
read_moved_clock() { ipc smoke readInstance "$(bar_key)" vgs.bar/left-clock format; }
expect "the moved clock is the registered one" '"HH:mm:ss"' read_moved_clock
bar_row left '["workspaces"]'
bar_row center '["clock"]'
expect_builtins "the built-ins return to their sections" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
# A name listed twice in one section is drawn once and the repeat logged by
# every bar; the logged line proves the bar read the setting.
expected_errors+=('vgs\.bar: setting left lists a built-in twice, drawn once: ')
bar_row left '["workspaces","workspaces"]'
expect_log "a built-in listed twice in one section is logged by every bar" "$monitors" 'vgs\.bar: setting left lists a built-in twice, drawn once: '
expect_builtins "a built-in listed twice in one section registers once" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
bar_row left '["workspaces"]'

# Each bar stays alive while its built-ins change. The pending callbacks
# must describe only its current capability holds and live built-ins.
bar_cleanup_balanced() {
  ipc shell built | python3 -c 'import json,sys; d=json.load(sys.stdin); bars=[rows for key,rows in d.items() if key.startswith("bar:")]; print(len(bars)==int(sys.argv[1]) and all(len([r for r in rows if r["id"]=="vgs.bar"])==1 and all(r["pendingCleanups"]==len(r["capabilities"])+sum(b["origin"]=="plugin" for b in rows) for r in rows if r["id"]=="vgs.bar") for rows in bars))' "$monitors"
}
builtin_builds_before="$(builds)"
for builtin_cycle in {1..12}; do
  bar_row '[]'
  expect_builtins "built-in cleanup cycle $builtin_cycle removes the manager" '["vgs.bar/center-clock","vgs.bar/left-workspaces"]'
  expect_poll "built-in cleanup cycle $builtin_cycle forgets released callbacks" True bar_cleanup_balanced
  bar_row '["manager"]'
  expect_builtins "built-in cleanup cycle $builtin_cycle restores the manager" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
  expect_poll "built-in cleanup cycle $builtin_cycle keeps only live callbacks" True bar_cleanup_balanced
  expect "built-in cleanup cycle $builtin_cycle preserves the bar lifetime" "$builtin_builds_before" builds
done
