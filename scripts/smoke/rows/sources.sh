# Source revisions: an edit to a plugin's own files, including a sibling
# file its entry point imports, reaches a new build of that plugin alone;
# a build that failed is not tried again until the source changes; two
# rescans asked for back to back both complete; and an unchanged plugin's
# files stay readable after the sources of others were replaced. Every
# fixture write is a rename, so the scan never reads half a file.
set -euo pipefail
tick_revision() { ipc shell listPlugins | py_reply 'import json,sys; print([p["revision"] for p in json.load(sys.stdin)["plugins"] if p["id"]=="acme.tick"][0])'; }
write_tick() { # FILE CONTENT: replace one file of the placed widget whole
  printf '%s' "$2" >"$tick/$1.tmp" && mv -T -- "$tick/$1.tmp" "$tick/$1"
}
tick_sibling() { # VALUE: the sibling's exported value
  write_tick Tick.js ".pragma library
var VALUE = \"$1\";
"
}
# The build records list a rebuilt widget last; the drawn order is the
# order of the section's children, read from each widget's own index.
widget_index() { ipc smoke childIndex "$(bar_key)" "$1"; }
tick_before_probe() { python3 -c 'import sys; a, b = int(sys.argv[1]), int(sys.argv[2]); print(a >= 0 and b >= 0 and a < b)' "$(widget_index acme.tick)" "$(widget_index acme.probe)"; }
scans_done() { log_lines 'plugins: scan complete '; }

expect "the placed widget reads its sibling import" '"one"' read_tick sibling
revision_one="$(tick_revision)"
if before="$(builds)"; then
  tick_sibling two
  expect "a rescan after editing a sibling file answers ok" ok ipc shell rescanPlugins
  expect_poll "the edited sibling reaches the rebuilt widget" '"two"' read_tick sibling
  expect "the edit rebuilt the widget on every screen and nothing else" "$((before + monitors))" builds
  if revision_two="$(tick_revision)" && [[ -n $revision_one && -n $revision_two && $revision_one != "$revision_two" ]]; then ok "the edit gave the plugin a new revision"; else fail "revisions before and after the edit: $revision_one ${revision_two:-unreadable}"; fi
  expect "the rebuilt widget keeps its layout entry" '"HH:mm:ss"' read_tick format
else
  fail "buildCount unreadable before the source rows"
fi

# A rebuilt widget keeps its place among its section's widgets: the
# fixture widget is moved beside the placed widget for the check and back.
move_probe() { # SECTION: move the fixture widget's layout entry to that section
  python3 - "$home/.config/vgs/shell.json" "$1" <<'PY'
import json, os, sys
p, section = sys.argv[1], sys.argv[2]
d = json.load(open(p))
layout = d["bar"]["layout"]
entry = [e for s in layout.values() for e in s if e["id"] == "acme.probe"][0]
for s in layout.values():
    s[:] = [e for e in s if e["id"] != "acme.probe"]
layout[section].append(entry)
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
}
move_probe center
expect_widgets "the fixture widget follows the placed widget in the centre section" '["acme.tick","acme.probe"]'
expect_poll "the placed widget precedes the fixture widget in the section" True tick_before_probe
if before="$(builds)"; then
  tick_sibling three
  expect "a rescan after a second edit answers ok" ok ipc shell rescanPlugins
  expect_poll "the second edit reaches the rebuilt widget" '"three"' read_tick sibling
  expect "the second edit rebuilt the widget alone" "$((before + monitors))" builds
  expect_poll "the rebuilt widget keeps its place before its neighbour" True tick_before_probe
else
  fail "buildCount unreadable before the order rows"
fi
move_probe right
expect_widgets "the fixture widget returns to the right section" '["acme.tick","acme.probe"]'

# A widget whose code fails to load is logged once per bar and not tried
# again for a settings change; the repaired code is tried on its rescan.
widget_good="$(cat "$tick/Widget.qml")"
expected_errors+=('plugins: acme\.tick failed to load: ')
loads_before="$(log_lines 'plugins: acme\.tick failed to load: ')" || fail "instance log unreadable: $instance_log"
write_tick Widget.qml 'import QtQuick
import qs.Ui
BarWidget { broken
'
expect "a rescan after breaking the widget answers ok" ok ipc shell rescanPlugins
expect_log "the core logged the failed load on every bar" "$((loads_before + monitors))" 'plugins: acme\.tick failed to load: '
expect_widgets "the broken widget leaves the bar" '["acme.probe"]'
if before="$(builds)"; then
  python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
[e for e in d["bar"]["layout"]["center"] if e["id"] == "acme.tick"][0]["format"] = "retry-check"
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
  tick_format_effective() { ipc shell listShellConfig | py_reply 'import json,sys; print([e["format"] for e in json.load(sys.stdin)["bar"]["layout"]["center"] if e["id"]=="acme.tick"][0])'; }
  expect_poll "the shell read the settings change for the broken widget" retry-check tick_format_effective
  expect "a settings change does not try the failed code again" "$((loads_before + monitors))" log_lines 'plugins: acme\.tick failed to load: '
  expect "a settings change builds nothing for the failed code" "$before" builds
else
  fail "buildCount unreadable before the retry rows"
fi
write_tick Widget.qml "$widget_good"
expect "a rescan after repairing the widget answers ok" ok ipc shell rescanPlugins
expect_widgets "the repaired widget returns to the bar" '["acme.probe","acme.tick"]'
expect_poll "the repaired widget reads its layout entry" '"retry-check"' read_tick format

# Two rescans asked for back to back: the second is queued while the first
# runs, or starts after it; either way both complete.
if scans_before="$(scans_done)"; then
  ipc shell rescanPlugins >"$sandbox/rescan-first.out" &
  rescan_first=$!
  second="$(ipc shell rescanPlugins)" || second="failed"
  wait "$rescan_first" || true
  first="$(cat "$sandbox/rescan-first.out")" || first="unreadable"
  if [[ ($first == ok || $first == busy) && ($second == ok || $second == busy) ]]; then ok "two back-to-back rescans are accepted ($first, $second)"; else fail "back-to-back rescans answered $first and $second"; fi
  expect_log "both back-to-back rescans completed" "$((scans_before + 2))" 'plugins: scan complete '
else
  fail "instance log unreadable: $instance_log"
fi
expect "an unchanged plugin's files stay readable after the rescans" lazy ipc smoke invokeInstance "$(bar_key)" acme.tick lazy ''
# The rescans above changed only the placed widget, so the fixture
# service's in-memory state stayed: its shortcut counter, pressed once here.
expect "the compositor triggers the fixture's shortcut before the state check" ok hypr dispatch 'hl.dsp.global("acme.probe:ping")'
expect_poll "the fixture service counted the press" 1 read_service presses
expect "a rescan that changes nothing answers ok before the state check" ok ipc shell rescanPlugins
expect_log "that rescan completed" "$((scans_before + 3))" 'plugins: scan complete '
expect "the running service kept its in-memory state across the rescans" 1 read_service presses

# The scanner's output is usable only after a successful exit. Each bad
# scanner is installed in the sandbox copy, never in the live checkout.
scan_error() { ipc shell listPlugins | py_reply 'import json,sys; print(json.load(sys.stdin)["scanError"])'; }
cp -p -- "$repo/bin/vgsh-scan" "$sandbox/vgsh-scan.good"
scan_plugins_before="$(ipc shell listPlugins | py_reply 'import json,sys; print(json.load(sys.stdin)["plugins"])')"
scan_plugins() { ipc shell listPlugins | py_reply 'import json,sys; print(json.load(sys.stdin)["plugins"])'; }
expected_errors+=('plugins: vgsh-scan exited 9 status=0' 'plugins: vgsh-scan did not start' 'plugins: scan output does not parse: ')
printf '#!/bin/sh\nprintf "[]\\n"\nexit 9\n' >"$repo/bin/vgsh-scan"
expect "a scanner that exits nonzero accepts the scan request" ok ipc shell rescanPlugins
expect_poll "the nonzero scanner exit is reported" 'vgsh-scan exited 9 status=0' scan_error
expect "valid-looking output from a failed scanner keeps the registry" "$scan_plugins_before" scan_plugins
chmod 000 "$repo/bin/vgsh-scan"
expect "an unstartable scanner accepts the scan request" ok ipc shell rescanPlugins
expect_poll "the scanner failed start is reported" 'vgsh-scan did not start' scan_error
expect "a failed start keeps the registry" "$scan_plugins_before" scan_plugins
chmod 755 "$repo/bin/vgsh-scan"
printf '#!/bin/sh\nprintf "{}\\n"\n' >"$repo/bin/vgsh-scan"
expect "a malformed scanner accepts the scan request" ok ipc shell rescanPlugins
expect_poll "a non-list scan result is reported" 'scan output does not parse: expected an entry list' scan_error
expect "a malformed result keeps the registry" "$scan_plugins_before" scan_plugins
mv -T -- "$sandbox/vgsh-scan.good" "$repo/bin/vgsh-scan"
expect "a repaired scanner accepts the scan request" ok ipc shell rescanPlugins
expect_poll "a successful scan clears the error" '' scan_error
expect "the repaired scan preserves the plugin list" "$scan_plugins_before" scan_plugins
