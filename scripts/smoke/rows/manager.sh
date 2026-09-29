# The Settings plugin, vgs.settings, the plugin manager's user interface.
# Enabled here, it places its gear in every bar and binds SUPER+M; the gear
# opens a window centred on its monitor, half the monitor tall and
# `size.window.width` wide or clamped on a narrower monitor, which takes the
# keyboard. The window lists every plugin, itself included, and opens a page
# per plugin whose settings, keys and enablement it writes through the
# manager capability; the title's menu jumps between pages, the back button
# and Escape return, a deep link opens one page, and the page's scroll bar
# drags. rows/settings.sh continues with the same window and disables the
# plugin again.
set -euo pipefail
read -r mon_w mon_h bar_reserved < <(monitor_size)

settings_rows() { ipc smoke readInstance panel vgs.settings plugins; }
settings_page() { ipc smoke readInstance panel vgs.settings page; }
settings_open() { [[ $(ipc smoke instanceGeometry panel vgs.settings) != absent ]] && echo open || echo closed; }
settings_layer() { one_layer vgs:panel; }
settings_click() { click_in vgs:panel panel vgs.settings "$1" "$2"; }
user_file="$home/.config/vgs/shell.json"
# The key the user file gives vgs.settings' shortcut: its value as JSON, or
# `absent` when the row holds no entry.
user_key() { python3 -c 'import json,sys; rows=[r for r in json.load(open(sys.argv[1])).get("plugins", []) if r["id"] == "vgs.settings"]; k=rows[0].get("keys", {}) if rows else {}; print(json.dumps(k["toggle"]) if "toggle" in k else "absent")' "$user_file"; }
# The binds Hyprland holds for the Settings shortcut, as [modmask, key].
settings_binds() { hypr -j binds | python3 -c 'import json,sys; print(json.dumps(sorted([b["modmask"], b["key"]] for b in json.load(sys.stdin) if b["description"] == "vgs.settings:toggle")))'; }
# window_fits MONITOR: [] when the Settings layer on MONITOR is
# min(size.window.width, width - 2 * size.window.gutter) wide,
# size.window.heightShare of the height tall and centred on the whole
# monitor, bar included, within one pixel; else the misfits.
window_fits() {
  local width share gutter
  width="$(ipc smoke themeValue size.window.width)" || return
  share="$(ipc smoke themeValue size.window.heightShare)" || return
  gutter="$(ipc smoke themeValue size.window.gutter)" || return
  { hypr -j monitors; hypr -j layers; } | python3 -c '
import json, math, sys
text = sys.stdin.read()
monitors, at = json.JSONDecoder().raw_decode(text)
layers = json.loads(text[at:])
name, width, share, gutter = sys.argv[1], *(json.loads(a) for a in sys.argv[2:])
mon = [m for m in monitors if m["name"] == name]
if len(mon) != 1:
    print(json.dumps(["monitor=%s absent" % name])); sys.exit()
m = mon[0]
mw, mh = m["width"] / m["scale"], m["height"] / m["scale"]
boxes = [[l["x"], l["y"], l["w"], l["h"]] for lv in layers.get(name, {"levels": {}})["levels"].values() for l in lv if l["namespace"] == "vgs:panel" and l["pid"] != -1]
if len(boxes) != 1:
    print(json.dumps(["panels=%d" % len(boxes)])); sys.exit()
x, y, w, h = boxes[0]
want_w, want_h = math.floor(min(width, mw - 2 * gutter)), math.floor(share * mh)
out = []
for key, got, want in (("w", w, want_w), ("h", h, want_h), ("x", x, m["x"] + (mw - want_w) / 2), ("y", y, m["y"] + (mh - want_h) / 2)):
    if abs(got - want) > 1: out.append("%s=%s want=%s" % (key, got, want))
print(json.dumps(out))' "$1" "$width" "$share" "$gutter"
}
first_monitor() { hypr -j monitors | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["name"])'; }

# Enable: the gear joins every bar's right section, the service registers
# its shortcut and IPC target, and the Hyprland layer binds SUPER+M.
expect "enabling the Settings plugin is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect_poll "listPlugins reads the Settings plugin enabled" True plugin_enabled vgs.settings
gear_placed() { bar_widget_ids | python3 -c 'import json,sys; b=json.load(sys.stdin); print(len(b) > 0 and all(ids[-1:] == ["vgs.settings"] for ids in b))'; }
expect_poll "enabling places the gear last in every bar" True gear_placed
settings_lent() { ipc shell lent | python3 -c 'import json,sys; d=json.load(sys.stdin); print("vgs.settings:toggle" in d["shortcuts"] and "vgs.settings" in d["ipcTargets"])'; }
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

# The gear opens the window on its bar's monitor, centred on the whole
# monitor, and the window takes the keyboard: typed letters reach its
# search field.
click_centre "$(bar_key)" vgs.settings || fail "the click on the gear failed"
expect_poll "the gear opens the Settings window" open settings_open
expect_poll "the Settings window maps one layer" 1 layer_count vgs:panel
main_monitor="$(first_monitor)" || fail "the first monitor's name is unreadable"
geometry expect_poll "the window is the token width, half the monitor tall and centred within one pixel" '[]' window_fits "$main_monitor"
expect_poll "the window takes the keyboard when it opens" true ipc smoke activeFocusIn panel vgs.settings
listed_names() { ipc smoke itemTexts panel vgs.settings ListItem | python3 -c 'import json,sys; print(json.dumps([t[0] for t in json.load(sys.stdin)]))'; }
type_keys probe || fail "typing into the Settings search failed"
expect_poll "typing filters the list to the matching plugin" '["Probe"]' listed_names
type_keys -k BackSpace -k BackSpace -k BackSpace -k BackSpace -k BackSpace || fail "clearing the Settings search failed"
list_complete() { { ipc shell listPlugins; listed_names; } | python3 -c '
import json, sys
text = sys.stdin.read()
listing, at = json.JSONDecoder().raw_decode(text)
names = json.loads(text[at:])
print(len(names) == len(listing["plugins"]))'; }
expect_poll "the cleared search lists every plugin again" True list_complete

# The list: one row per discovered plugin, the Settings plugin itself
# included, with its icon, source, capabilities, keys and errors.
rows_match() { { ipc shell listPlugins; settings_rows; } | python3 -c '
import json, sys
text = sys.stdin.read()
listing, at = json.JSONDecoder().raw_decode(text)
rows = json.loads(text[at:])
print(sorted(p["id"] for p in listing["plugins"]) == [r["id"] for r in rows] and all(r["enabled"] == p["enabled"] for r in rows for p in listing["plugins"] if p["id"] == r["id"]))'; }
expect "the window lists every plugin listPlugins lists, with its state" True rows_match
row_of() { settings_rows | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin) if r["id"] == sys.argv[1]][0]; print(json.dumps([r[k] for k in sys.argv[2:]]))' "$@"; }
expect "the Settings plugin lists itself, bundled, with its icon, capabilities and key" '["Settings", "settings", "bundled", ["ipc", "manager", "screens", "shortcut", "surfaces"], [{"shortcut": "toggle", "key": "SUPER+M", "default": "SUPER+M", "description": "Open or close Settings"}], []]' row_of vgs.settings name icon source capabilities binds errors
expect "an installed fixture is listed as installed with its manifest icon" '["Probe", "flask-conical", "installed", "acme"]' row_of acme.probe name icon source author
expect "a plugin without a manifest icon is listed with the package icon" '["package"]' row_of acme.bare icon

# A page: a click on a row opens it, drawn from the manifest alone; its
# schema's groups are its sections, in manifest order after the entries
# without one, and a bounded number is a slider.
settings_click ListItem Probe || fail "the click on the fixture's row failed"
expect_poll "a click on a row opens that plugin's page" '"acme.probe"' settings_page
section_names() { ipc smoke itemTexts panel vgs.settings SectionHeader | python3 -c 'import json,sys; print(json.dumps([t[0] for t in json.load(sys.stdin) if t]))'; }
expect_poll "the page draws one section per schema group, ungrouped first" '["Settings", "Layout", "Behaviour", "Look"]' section_names
page_fields() { ipc smoke drawnFields panel vgs.settings | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([d["acme.probe"], sum(v for k, v in d.items() if k != "acme.probe")]))'; }
expect_poll "the page draws one field per schema entry and no other plugin's" '[9, 0]' page_fields
sliders() { ipc smoke descendantGeometry panel vgs.settings | python3 -c 'import json,sys; print(sum(1 for r in json.load(sys.stdin) if r["type"] == "Slider"))'; }
expect "the two bounded numbers draw sliders" 2 sliders
# Every field's inline label starts `row.paddingX` in from the page's
# column and every control `field.labelWidth` plus `field.labelGap` past
# that, within one pixel; `[]` is the pass.
page_alignment() {
  local rows pad label_w label_gap
  rows="$(ipc smoke descendantGeometry panel vgs.settings)" || return
  pad="$(ipc smoke themeValue row.paddingX)" || return
  label_w="$(ipc smoke themeValue field.labelWidth)" || return
  label_gap="$(ipc smoke themeValue field.labelGap)" || return
  python3 - "$rows" "$pad" "$label_w" "$label_gap" <<'PY'
import json, sys
rows, pad, label_w, label_gap = (json.loads(a) for a in sys.argv[1:])
out = []
fields = [i for i, r in enumerate(rows) if r["type"] == "SettingField"]
if len(fields) != 9: out.append("fields=%d" % len(fields))
def inside(j, i):
    while j != -1:
        if j == i: return True
        j = rows[j]["parent"]
    return False
for n, i in enumerate(fields):
    left = rows[i]["box"][0]
    labels = [j for j, r in enumerate(rows) if r["type"] == "Label" and r.get("role") == "label" and rows[r["parent"]]["type"] == "QQuickRow" and rows[r["parent"]]["parent"] == i]
    controls = [j for j, r in enumerate(rows) if r["type"] in ("TextField", "Select", "Switch", "Slider") and inside(j, i)]
    if len(labels) != 1 or len(controls) != 1: out.append("field%d labels=%d controls=%d" % (n, len(labels), len(controls)))
    for j in labels:
        if abs(rows[j]["box"][0] - (left + pad)) > 1: out.append("field%d.label.x=%.2f want=%.2f" % (n, rows[j]["box"][0], left + pad))
    for j in controls:
        want = left + pad + label_w + label_gap
        got = rows[j]["box"][0]
        if abs(got - want) > 1: out.append("field%d.%s.x=%.2f want=%.2f" % (n, rows[j]["type"], got, want))
print(json.dumps(out))
PY
}
geometry expect_poll "the page's fields share one label edge and one control edge" '[]' page_alignment

# The page scrolls under its bar: a drag on the thumb moves the content
# with it, and a press on the track under the thumb pages one view down.
page_scroll() { ipc smoke scrollAreas panel vgs.settings | python3 -c 'import json,sys; a=json.load(sys.stdin); print(json.dumps(a[0]) if len(a) == 1 else "areas=%d" % len(a))'; }
scroll_value() { page_scroll | python3 -c 'import json,sys; t=sys.stdin.read(); a=json.loads(t) if t.startswith("{") else None; print(json.dumps([a[k] for k in sys.argv[1:]]) if a else t.strip())' "$@"; }
overflowing() { page_scroll | python3 -c 'import json,sys; a=json.loads(sys.stdin.read()); print(json.dumps([a["contentHeight"] > a["height"], a["barVisible"], a["contentWidth"] < a["width"]]))'; }
expect_poll "the fixture's page overflows, shows its bar and leaves it a gutter" '[true, true, true]' overflowing
if area="$(page_scroll)" && [[ $area == \{* ]]; then
  read -r tx ty < <(at_centre vgs:panel "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["thumb"]))' "$area")")
  thumb_top_before="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["thumb"][1])' "$area")"
  drag "$tx" "$ty" "$tx" "$((ty + 40))" || fail "the drag on the page's thumb failed"
  dragged() { page_scroll | python3 -c 'import json,sys; a=json.loads(sys.stdin.read()); moved=a["thumb"][1]-float(sys.argv[1]); travel=a["bar"][3]-a["thumb"][3]; want=moved/travel*(a["contentHeight"]-a["height"]) if travel > 0 else -1; print(a["contentY"] > 0 and abs(moved - 40) <= 2 and abs(a["contentY"] - want) <= 2)' "$thumb_top_before"; }
  geometry expect_poll "a drag on the thumb moves it and scrolls the content with it" True dragged
  y_before="$(scroll_value contentY | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')"
  # A 2 px box on the track just under the thumb.
  area="$(page_scroll)"
  read -r bx by < <(at_centre vgs:panel "$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); b=a["bar"]; t=a["thumb"]; print(json.dumps([b[0], t[1] + t[3] + 2, b[2], 2]))' "$area")")
  click "$bx" "$by" || fail "the press on the page's track failed"
  paged() { page_scroll | python3 -c 'import json,sys; a=json.loads(sys.stdin.read()); y=float(sys.argv[1]); print(abs(a["contentY"] - min(y + a["height"], a["contentHeight"] - a["height"])) <= 1)' "$y_before"; }
  geometry expect_poll "a press on the track under the thumb pages one view down" True paged
else
  fail "the fixture's page scroll area is unreadable: ${area:-}"
fi

# The title's menu lists every plugin with the current one checked, scrolls
# past its maximum height under its own bar, and typed letters then Enter
# jump to another plugin's page.
title_menu() { ipc smoke menus panel vgs.settings | python3 -c 'import json,sys; m=json.load(sys.stdin); print(json.dumps([m[0][k] for k in sys.argv[1:]]) if len(m) == 1 else "menus=%d" % len(m))' "$@"; }
settings_click TitleButton Probe || fail "the click on the page's title failed"
expect_poll "a click on the title opens its menu on the current plugin" '[true, ["Probe"], "Probe"]' title_menu opened checked current
menu_lists_all() { { settings_rows; title_menu entries; } | python3 -c '
import json, sys
text = sys.stdin.read()
rows, at = json.JSONDecoder().raw_decode(text)
print(json.loads(text[at:])[0] == [r["name"] for r in rows])'; }
expect "the title's menu lists every plugin by name" True menu_lists_all
expect "the long menu scrolls under its own bar" '[true, true]' title_menu overflowing barVisible
type_keys set || fail "typing into the title's menu failed"
expect_poll "typed letters highlight the plugin whose name starts with them" '["Settings"]' title_menu current
type_keys -k Return || fail "sending Return to the title's menu failed"
expect_poll "Enter jumps to that plugin's page" '"vgs.settings"' settings_page
expect_poll "the jump closes the menu" '[false]' title_menu opened

# Keys: the Settings plugin's own page edits its shortcut's key. A key
# rebinds, an emptied field unbinds, the reset button returns to the
# manifest's key, each written to its shell.json keys and reaching the
# Hyprland layer; a malformed key is refused and shown on the page.
expect "a key typed in the Keys row is applied" applied ipc smoke invokeInstance panel vgs.settings applyKey '{"id":"vgs.settings","shortcut":"toggle","key":"shift+super+m"}'
expect_poll "the rebind reaches shell.json keys, normalised" '"SUPER+SHIFT+M"' user_key
expect_poll "the rebind reaches the Hyprland layer" '[[65, "M"]]' settings_binds
expect_poll "the page's Keys row shows the key in effect beside its default" '[[{"shortcut": "toggle", "key": "SUPER+SHIFT+M", "default": "SUPER+M", "description": "Open or close Settings"}]]' row_of vgs.settings binds
expect "an emptied key unbinds the shortcut" applied ipc smoke invokeInstance panel vgs.settings applyKey '{"id":"vgs.settings","shortcut":"toggle","key":null}'
expect_poll "the unbind reaches shell.json keys as null" null user_key
expect_poll "the unbind leaves Hyprland no Settings bind" '[]' settings_binds
expect "the reset button returns the shortcut to the manifest's key" applied ipc smoke invokeInstance panel vgs.settings applyKey '{"id":"vgs.settings","shortcut":"toggle"}'
expect_poll "the reset removes the shell.json entry" absent user_key
expect_poll "the reset binds SUPER+M again" '[[64, "M"]]' settings_binds
expected_errors+=('settings: vgs\.settings refused: key=toggle has an empty part')
expect "a malformed key typed in the Keys row is sent" applied ipc smoke invokeInstance panel vgs.settings applyKey '{"id":"vgs.settings","shortcut":"toggle","key":"SUPER+"}'
expect "the page shows the key's refusal" '{"vgs.settings":"refused: key=toggle has an empty part: \"SUPER+\""}' ipc smoke readInstance panel vgs.settings replies
expect "the refused key left shell.json alone" absent user_key
expect "a reset after the refusal is applied" applied ipc smoke invokeInstance panel vgs.settings applyKey '{"id":"vgs.settings","shortcut":"toggle"}'
expect "the accepted key clears the page's refusal" '{}' ipc smoke readInstance panel vgs.settings replies
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
listed_problem() { ipc shell listPlugins | python3 -c 'import json,sys; print(json.dumps([e["error"] for e in json.load(sys.stdin)["errors"] if "vgs.settings" in e["error"]]))'; }
settings_badge() { ipc smoke itemTexts panel vgs.settings ListItem | python3 -c 'import json,sys; print(json.dumps([t for t in json.load(sys.stdin) if t[0] == "Settings"]))'; }
settings_keys_row '{"nope": "SUPER+F9"}'
expect_poll "a keys name no bind declares is among the plugin's errors" '[["hyprland: shell.json keys.nope names no bind of vgs.settings"]]' row_of vgs.settings errors
expect "listPlugins reads the same problem" '["hyprland: shell.json keys.nope names no bind of vgs.settings"]' listed_problem
expect_poll "the list's row carries a badge counting the error" '[["Settings", "0.1.0  Bundled", "1"]]' settings_badge
settings_keys_row '{}'
expect_poll "the plugin's errors clear with the problem" '[[]]' row_of vgs.settings errors

# Back: the back button and Escape pop the page; Escape on the list hides
# the window.
settings_click IconButton "Back to the plugin list" || fail "the click on the back button failed"
expect_poll "the back button returns to the list" '""' settings_page
expect "a row opens its page by name" ok ipc smoke invokeInstance panel vgs.settings openPlugin acme.probe
expect_poll "the page is open again" '"acme.probe"' settings_page
type_keys -k Escape || fail "sending Escape to the page failed"
expect_poll "Escape pops the page" '""' settings_page
type_keys -k Escape || fail "sending Escape to the list failed"
expect_poll "Escape on the list hides the window" 0 layer_count vgs:panel

# Deep links: a summon's payload opens one plugin's page, an unknown id
# opens the list with a notice naming it, and any other key refuses the
# summon. The shortcut and the plugin's IPC open it too.
expect "a deep link summons the Settings window" ok ipc shell summon panel vgs.settings '{"plugin":"acme.probe"}'
expect_poll "the deep link opens that plugin's page" '"acme.probe"' settings_page
expect "a deep link to an id no plugin has is accepted" ok ipc shell summon panel vgs.settings '{"plugin":"acme.nowhere"}'
expect_poll "an unknown id opens the list" '""' settings_page
notice_names() { ipc smoke readInstance panel vgs.settings notice | python3 -c 'import json,sys; print("acme.nowhere" in json.load(sys.stdin))'; }
expect "the list's notice names the unknown id" True notice_names
expected_errors+=('summon host: vgs\.settings open\(\) failed: payload key "page" unknown')
expect "a payload key other than plugin refuses the summon" "refused: open-failed=vgs.settings" ipc shell summon panel vgs.settings '{"page":"x"}'
expect_poll "the refused summon leaves no window" 0 layer_count vgs:panel
expect "the plugin's IPC opens a page" ok ipc vgs.settings invoke open '{"plugin":"vgs.bar"}'
expect_poll "the IPC deep link opens that page" '"vgs.bar"' settings_page
expect "the compositor's shortcut toggles the window closed" ok hypr dispatch 'hl.dsp.global("vgs.settings:toggle")'
expect_poll "the shortcut closed the window" 0 layer_count vgs:panel
expect "the compositor's shortcut toggles the window open" ok hypr dispatch 'hl.dsp.global("vgs.settings:toggle")'
expect_poll "the shortcut opened the window" open settings_open
geometry expect_poll "the shortcut's window fits the focused monitor" '[]' window_fits "$main_monitor"
expect "the shortcut toggles it closed again" ok hypr dispatch 'hl.dsp.global("vgs.settings:toggle")'
expect_poll "the window is gone after the shortcut" 0 layer_count vgs:panel

# A monitor narrower than the window's width token: the window keeps
# `size.window.gutter` a side and half the monitor's height, centred. A
# headless output the rows could add has no size in the sandbox, whose
# headless buffers fail to allocate (the GBM line qml-smoke.sh's header
# names), so the row makes the monitor the narrower one: a theme sets the
# token past the monitor's width, which meets the same clamp,
# min(size.window.width, width - 2 * size.window.gutter).
theme_file="$home/.config/vgs/theme.json"
theme_saved="$sandbox/theme.json.before-clamp"
[[ ! -e $theme_file ]] || cp -p -- "$theme_file" "$theme_saved"
printf '{ "schemaVersion": 1, "name": "wide-window", "tokens": { "size": { "window": { "width": 4096 } } } }\n' >"$theme_file.tmp" && mv -T -- "$theme_file.tmp" "$theme_file"
expect_poll "a theme sets the window width past the monitor's" 4096 ipc smoke themeValue size.window.width
click_centre "$(bar_key)" vgs.settings || fail "the click on the gear for the clamp failed"
expect_poll "the gear opens the window for the clamp" open settings_open
geometry expect_poll "a monitor narrower than the width token keeps the gutters, half its height, centred" '[]' window_fits "$main_monitor"
clamped_width() { settings_layer | python3 -c 'import json,sys; print(json.load(sys.stdin)[2])'; }
gutter="$(ipc smoke themeValue size.window.gutter)" || fail "the gutter token is unreadable"
geometry expect "the clamped window is the monitor's width less two gutters" "$((mon_w - 2 * gutter))" clamped_width
expect "the gear closes the clamped window" ok ipc smoke invokeInstance "$(bar_key)" vgs.settings toggle ''
expect_poll "the clamped window is gone" 0 layer_count vgs:panel
if [[ -e $theme_saved ]]; then
  mv -T -- "$theme_saved" "$theme_file"
else
  unlink -- "$theme_file"
fi
expect_poll "the theme's window width is the default again" 600 ipc smoke themeValue size.window.width

# Enable and disable, and a setting, through the page.
expect "the deep link reopens the fixture's page" ok ipc shell summon panel vgs.settings '{"plugin":"acme.probe"}'
expect_poll "the fixture's page is open" '"acme.probe"' settings_page
manager_rows() { settings_rows | python3 -c 'import json,sys; rows=json.load(sys.stdin); print(json.dumps({r["id"]: r["enabled"] for r in rows if r["id"] in ("acme.probe", "acme.bare", "vgs.bar")}, sort_keys=True))'; }
expect "the window toggles the fixture off" ok ipc smoke invokeInstance panel vgs.settings toggle acme.probe
expect_poll "listPlugins reads the fixture disabled" False plugin_enabled acme.probe
expect_poll "the window shows the fixture disabled" '{"acme.bare": true, "acme.probe": false, "vgs.bar": true}' manager_rows
# The window logs each refusal it shows on a page.
expected_errors+=('settings: acme\.probe refused: disabled=acme\.probe' 'settings: acme\.probe refused: setting=tags undeclared' 'settings: acme\.probe refused: setting=size want=at-most:40')
expect "the window refuses a setting for a disabled plugin" "refused: disabled=acme.probe" ipc smoke invokeInstance panel vgs.settings applySetting '{"id":"acme.probe","key":"label","value":"x"}'
expect "the page shows the refusal" '{"acme.probe":"refused: disabled=acme.probe"}' ipc smoke readInstance panel vgs.settings replies
expect "the window toggles the fixture back on" ok ipc smoke invokeInstance panel vgs.settings toggle acme.probe
expect_poll "listPlugins reads the fixture enabled" True plugin_enabled acme.probe
expect "the window writes the fixture's setting" ok ipc smoke invokeInstance panel vgs.settings applySetting '{"id":"acme.probe","key":"label","value":"via-manager"}'
expect "a successful write clears the page's refusal" '{}' ipc smoke readInstance panel vgs.settings replies
expect_poll "the running service received the window's setting" '"via-manager"' read_service label
expect_poll "the running widget received the window's setting" '"via-manager"' read_widget label
manager_label() { settings_rows | python3 -c 'import json,sys; print(json.dumps([r["settings"]["label"] for r in json.load(sys.stdin) if r["id"]=="acme.probe"][0]))'; }
expect "the fixture's drawn label field applies an edit" applied ipc smoke invokeInstance panel vgs.settings applyField '{"id":"acme.probe","key":"label","value":"via-field"}'
expect_poll "the window reads back the setting the field wrote" '"via-field"' manager_label
manager_size() { settings_rows | python3 -c 'import json,sys; print(json.dumps([r["settings"]["size"] for r in json.load(sys.stdin) if r["id"]=="acme.probe"][0]))'; }
expect "the fixture's drawn slider applies a value" applied ipc smoke invokeInstance panel vgs.settings applyField '{"id":"acme.probe","key":"size","value":20}'
expect_poll "the window reads back the slider's value" 20 manager_size
expect "a number past its max is refused" "refused: setting=size want=at-most:40" ipc smoke invokeInstance panel vgs.settings applySetting '{"id":"acme.probe","key":"size","value":41}'
expect "the window refuses a setting outside the schema" "refused: setting=tags undeclared" ipc smoke invokeInstance panel vgs.settings applySetting '{"id":"acme.probe","key":"tags","value":"x"}'
expect "a later write clears the refusal" ok ipc smoke invokeInstance panel vgs.settings applySetting '{"id":"acme.probe","key":"size","value":12}'

# The Settings plugin disabled from its own page closes its window and
# takes its gear away; setPluginEnabled brings both back.
expect "the window opens its own page" ok ipc smoke invokeInstance panel vgs.settings openPlugin vgs.settings
expect "the window disables its own plugin" ok ipc smoke invokeInstance panel vgs.settings toggle vgs.settings
expect_poll "listPlugins reads the Settings plugin disabled" False plugin_enabled vgs.settings
expect_poll "the disabled plugin's window is gone" 0 layer_count vgs:panel
gear_gone() { bar_widget_ids | python3 -c 'import json,sys; print(all("vgs.settings" not in ids for ids in json.load(sys.stdin)))'; }
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
  ipc shell built | python3 -c 'import json,sys; d=json.load(sys.stdin); bars=[rows for key,rows in d.items() if key.startswith("bar:")]; print(len(bars)==int(sys.argv[1]) and all(len([r for r in rows if r["id"]=="vgs.bar"])==1 and all(r["pendingCleanups"]==len(r["capabilities"])+sum(b["origin"]=="plugin" for b in rows) for r in rows if r["id"]=="vgs.bar") for rows in bars))' "$monitors"
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
