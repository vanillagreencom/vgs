set -euo pipefail
expect "instance guard accepts the runner's shell" true ipc shell guarded

# Plugins scan asynchronously; wait for the bundled bar and the placed widget.
plugins_json=""
for _ in $(seq 1 100); do
  if plugins_json="$(ipc shell listPlugins)" && python3 -c 'import json,sys; d=json.load(sys.stdin); ids={p["id"] for p in d["plugins"]}; sys.exit(0 if {"vgs.bar","acme.tick"} <= ids else 1)' <<<"$plugins_json"; then break; fi
  sleep 0.2
done
if python3 - "$plugins_json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
by = {p["id"]: p for p in d["plugins"]}
missing = [i for i in ("vgs.bar", "acme.tick") if i not in by]
disabled = [i for i in by if i.startswith("vgs.") and not by[i]["enabled"]]
if missing or disabled or d["errors"] or d["collisions"]:
    print("missing=%s disabled=%s errors=%s collisions=%s" % (missing, disabled, d["errors"], d["collisions"]))
    sys.exit(1)
PY
then ok "bundled plugins discovered, enabled and error-free"; else fail "bundled plugin state"; fi

bars=-1
for _ in $(seq 1 50); do
  if bars="$(bar_count)" && [[ $bars == "$monitors" ]]; then break; fi
  sleep 0.2
done
if [[ $bars == "$monitors" && $monitors != 0 && $monitors != -1 ]]; then ok "one bar surface per monitor ($bars of $monitors)"; else fail "bar surfaces: $bars for $monitors monitors"; fi

expect_widgets "every bar mounted the placed plugin widget" '["acme.tick"]'
expect_builtins "every bar registered its built-in workspaces, clock and plugin manager" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'

# The built-ins share one vertical centre, the bar's, and draw in the
# `text.bar` role alone. A workspace pill is its label plus
# `bar.item.paddingX` a side with `size.control.sm` as its floor, and its
# label's line height plus `space.xs` tall, with the label at its centre;
# pills stand `bar.item.gap` apart. The manager's icon and text sit on its
# button's centre. The sandbox keeps workspaces 1, 2 and 100, so three pills
# stand in a row and the last is wider than the floor. Read from the first
# bar's items, each within one pixel; the answer is the list of misplaced
# items, so `[]` is the pass.
bar_alignment() {
  local key bar_box ws clock manager pad gap floor xs
  key="$(bar_key)" || return
  bar_box="$(ipc smoke instanceGeometry "$key" vgs.bar)" || return
  ws="$(ipc smoke descendantGeometry "$key" vgs.bar/left-workspaces)" || return
  clock="$(ipc smoke descendantGeometry "$key" vgs.bar/center-clock)" || return
  manager="$(ipc smoke descendantGeometry "$key" vgs.bar/right-manager)" || return
  pad="$(ipc smoke themeValue bar.item.paddingX)" || return
  gap="$(ipc smoke themeValue bar.item.gap)" || return
  floor="$(ipc smoke themeValue size.control.sm)" || return
  xs="$(ipc smoke themeValue space.xs)" || return
  python3 - "$bar_box" "$ws" "$clock" "$manager" "$pad" "$gap" "$floor" "$xs" <<'PY'
import json, sys
bar, ws, clock, manager, pad, gap, floor, xs = (json.loads(a) for a in sys.argv[1:])
out = []
def near(a, b): return abs(a - b) <= 1
def mid_x(r): return r["box"][0] + r["box"][2] / 2
def mid_y(r): return r["box"][1] + r["box"][3] / 2
def check(name, got, want):
    if not near(got, want): out.append("%s=%.2f want=%.2f" % (name, got, want))
def children(rows, i, kind): return [c for c in rows if c["parent"] == i and c["type"] == kind]
centre = bar[1] + bar[3] / 2
for name, rows in (("workspaces", ws), ("clock", clock), ("manager", manager)):
    roles = sorted({str(r.get("role")) for r in rows if r["type"] == "Label"})
    if roles != ["bar"]: out.append("%s roles=%s" % (name, roles))
pills = sorted(((r, children(ws, i, "Label")) for i, r in enumerate(ws) if r["type"] == "QQuickRectangle" and children(ws, i, "Label")), key=lambda p: p[0]["box"][0])
if len(pills) != 3: out.append("workspaces pills=%d want=3" % len(pills))
if not any(pill["box"][2] > floor + 1 for pill, _ in pills): out.append("workspaces wide=0")
for n, (pill, (label,)) in enumerate(pills):
    check("pill%d.width" % n, pill["box"][2], max(floor, label["implicit"][0] + 2 * pad))
    check("pill%d.height" % n, pill["box"][3], label["implicit"][1] + xs)
    check("pill%d.label.x" % n, mid_x(label), mid_x(pill))
    check("pill%d.label.y" % n, mid_y(label), mid_y(pill))
    check("pill%d.y" % n, mid_y(pill), centre)
    if n: check("pill%d.gap" % n, pill["box"][0] - (pills[n - 1][0]["box"][0] + pills[n - 1][0]["box"][2]), gap)
clock_labels = [r for r in clock if r["type"] == "Label"]
if len(clock_labels) != 1: out.append("clock labels=%d" % len(clock_labels))
for label in clock_labels: check("clock.label.y", mid_y(label), centre)
buttons = [(i, r) for i, r in enumerate(manager) if r["type"] == "Button"]
if len(buttons) != 1: out.append("manager buttons=%d" % len(buttons))
for i, button in buttons:
    check("manager.button.y", mid_y(button), centre)
    inside = [r for j, r in enumerate(manager) if j > i and r["type"] in ("Icon", "Label")]
    if sorted(r["type"] for r in inside) != ["Icon", "Label"]: out.append("manager content=%s" % sorted(r["type"] for r in inside))
    for r in inside: check("manager.%s.y" % r["type"].lower(), mid_y(r), mid_y(button))
print(json.dumps(out))
PY
}
geometry expect_poll "the workspace pills, the clock and the manager share the bar's centre" '[]' bar_alignment
bar_font_family() { ipc smoke readInstance "$(bar_key)" vgs.bar fontFamily; }
expect "the bar API names the family of the bar role" '"JetBrains Mono"' bar_font_family
expect "the core built the bar and its placed widget per screen, and no built-in" "$((2 * monitors))" builds

# Disable only lists the id: the layout entry and its settings stay, so
# re-enabling restores the exact screen. The effective configuration is
# read back for the entry, the user file for what the manager wrote.
# Latency from a setPluginEnabled reply to `built` reflecting it, polled
# with qs ipc against the shell's pid; the reading carries one IPC round trip.
reconcile_ms=""
if disable_reply="$(ipc shell setPluginEnabled acme.tick false)"; then
  replied_ms="$(now_ms)"
  for _ in $(seq 1 500); do
    if built_now="$("${shell_env[@]}" qs ipc --pid "$shell_pid" call shell built 2>>"$sandbox/ipc.log" | tail -n 1)" && [[ -n $built_now && $built_now != *'"id":"acme.tick"'* ]]; then
      reconcile_ms=$(( $(now_ms) - replied_ms ))
      break
    fi
    sleep 0.005
  done
fi
if [[ $disable_reply == ok ]]; then ok "disabling a widget is allowed"; else fail "disabling a widget is allowed: got $disable_reply"; fi
tick_entry() { ipc shell listShellConfig | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([e for e in d["bar"]["layout"]["center"] if e["id"]=="acme.tick"]))'; }
user_keys() { python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])).keys())))' "$home/.config/vgs/shell.json"; }
expect_widgets "the bar dropped the disabled widget" '[]'
expect_builtins "the built-ins stay while a plugin widget leaves" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
expect "widget reads disabled after the user file changed" False plugin_enabled acme.tick
expect "the disabled widget keeps its layout entry and settings" '[{"id": "acme.tick", "format": "ddd d MMM  HH:mm"}]' tick_entry
expect "disable wrote only the disabled list" "bar,disabledPlugins,version" user_keys
expect "re-enabling the widget is allowed" ok ipc shell setPluginEnabled acme.tick true
expect_widgets "the bar rebuilt the re-enabled widget" '["acme.tick"]'
expect "re-enable wrote only the disabled list" "bar,disabledPlugins,version" user_keys

expect "disabling the bar names the widgets it hides" "ok hidden=acme.tick" ipc shell setPluginEnabled vgs.bar false
expect_widgets "the bar host unloaded the disabled bar" '[]'
expect_builtins "the disabled bar's built-ins left the build records" '[]'
bars_now=-1
for _ in $(seq 1 50); do
  if bars_now="$(bar_count)" && [[ $bars_now == 0 ]]; then break; fi
  sleep 0.2
done
if [[ $bars_now == 0 ]]; then ok "the bar host destroyed its surface with no bar"; else fail "bar surfaces with the bar disabled: $bars_now"; fi
expect "no bar reserves no screen space" 0 reserved_total
expect "re-enabling the bar is allowed" ok ipc shell setPluginEnabled vgs.bar true
expect_widgets "the bar host rebuilt the re-enabled bar" '["acme.tick"]'
monitor_size() { hypr -j monitors | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print(m["width"], m["height"], m["reserved"][1])'; }
expect_builtins "the re-enabled bar registered its built-ins again" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
for _ in $(seq 1 50); do
  if bars_now="$(bar_count)" && [[ $bars_now == "$monitors" ]]; then break; fi
  sleep 0.2
done
if [[ $bars_now == "$monitors" ]]; then ok "the bar host mapped its surface again"; else fail "bar surfaces after re-enable: $bars_now"; fi
reserved=0
for _ in $(seq 1 50); do
  if reserved="$(reserved_total)" && [[ $reserved -gt 0 ]]; then break; fi
  sleep 0.2
done
if [[ $reserved -gt 0 ]]; then ok "the re-enabled bar reserves screen space again"; else geometry fail "reserved space after re-enable: $reserved"; fi
if [[ -f "$home/.config/vgs/shell.json" ]]; then ok "manager wrote the user file"; else fail "user file missing"; fi

# An unrelated key in the user file builds nothing: the shell is seen to
# have read the write (the key is in the effective configuration) before
# the build count is compared. Every write the smoke makes to the user file
# is a rename, so the watching shell never reads half a file.
unrelated_key() { ipc shell listShellConfig | python3 -c 'import json,sys; print(json.load(sys.stdin).get("unrelated"))'; }
if before="$(builds)"; then
  python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["unrelated"] = 1
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
  expect_poll "the shell read the unrelated key" 1 unrelated_key
  expect "an unrelated configuration write rebuilds nothing" "$before" builds
  # Every completed scan logs whether the plugin set changed. A rescan
  # that changes nothing moves no slot key, so it builds nothing; the
  # logged line is the scan's completion.
  if unchanged_scans="$(log_lines 'plugins: scan complete changed=false$')"; then
    expect "a rescan that changes nothing answers ok" ok ipc shell rescanPlugins
    expect_log "the rescan that changes nothing completed" "$((unchanged_scans + 1))" 'plugins: scan complete changed=false$'
    expect "a rescan that changes nothing rebuilds nothing" "$before" builds
  else
    fail "instance log unreadable: $instance_log"
  fi
  # A rescan that adds a plugin nothing enables changes the set but moves
  # no other plugin's slot key, so nothing is built: not the bars, not
  # the placed widget, not the new plugin. The new plugin's appearance in
  # the listing is the scan's completion.
  idle="$home/.config/vgs/plugins/acme.idle"
  mkdir -p "$idle"
  cp -R "$repo/scripts/smoke/fixtures/plugins/acme.idle/." "$idle/"
  expect "a rescan after adding a plugin answers ok" ok ipc shell rescanPlugins
  expect_poll "the rescan discovered the plugin, disabled" False plugin_enabled acme.idle
  expect "a rescan that adds a disabled plugin does not build it" False record_exists acme.idle
  expect "a rescan that adds a plugin rebuilds no other plugin" "$before" builds
else
  fail "buildCount unreadable"
fi
