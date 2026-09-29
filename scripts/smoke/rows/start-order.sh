# Start order, D047. The row stops the running shell and starts the
# sandbox's tree again over the default set, every first-party plugin
# enabled as in a live session (harness.sh's default_set_prepare), plus
# two fixtures that name the lock: acme.contention, a background, and
# acme.locker, a service. The compiled QML cache is cleared first, so the
# start compiles as the first start of the run did. It reads:
# - the first bar within the default set's budget, printed as
#   latency_first_bar_ms with plugin_set=default;
# - ServiceGate's release, reason first-frame, and in the probe's start
#   order every bar window's first frame before the first service the core
#   built;
# - the lock held by the background and the service not built: at start
#   every surface plugin claims before any service;
# - the theme follow of the start's scan queued in the turn that scan
#   ended, so it never waits on the service gate, which releases on a bar
#   frame in a later turn, and one more follow for a rescan.
# Three controls start the same state over a mutant copy of the tree, each
# holding its own bin/ and shell/ with config/ and themes/ linked, as
# rows/notices-control.sh does: a service host with no gate builds its
# services in the scan's turn, before the first frame; a background host
# that waits for a built service leaves the lock with the service; a
# follow moved onto the gate's release is queued after its scan's turn; a
# follow that runs only while the services are held queues none for a
# rescan. The row runs last and leaves the last copy running
# for the harness's teardown.
set -euo pipefail
ipc() {
  "${shell_env[@]}" "$repo/bin/vgsh" ipc call "$@" 2>>"$sandbox/ipc.log" | tail -n 1
}
for fixture in acme.locker acme.contention; do
  rm -rf -- "$home/.config/vgs/plugins/$fixture"
  mkdir -p -- "$home/.config/vgs/plugins/$fixture"
  cp -R -- "$repo/scripts/smoke/fixtures/plugins/$fixture/." "$home/.config/vgs/plugins/$fixture/"
done

# restart_over TREE LOG [DISABLED_JSON BAR]: the running shell stopped
# and TREE's runner started over the default set and the two fixtures,
# with the plugins DISABLED_JSON lists disabled and no compiled QML cache;
# start_shell's readings follow, BAR passed on. Returns 1 when the start
# failed.
restart_over() { # TREE LOG [DISABLED_JSON BAR]
  stop_shell
  default_set_prepare '["acme.locker", "acme.contention"]' "${3:-[]}"
  rm -rf -- "$home/.cache/quickshell/qmlcache"
  start_shell "$1" "$2" "${4:-bar}"
}

# The probe's start order, judged. services_order: `bars-first` when every
# bar window, one per monitor, presented its first frame before the first
# service the core built; `services-first` when a service came earlier;
# otherwise what is missing. follow_order: `in-scan-turn` when the first
# follow was queued in the turn the first scan ended, before the event
# loop ran on, `late` otherwise, or what is missing. order_count KIND: the
# entries of that kind.
start_order() { ipc smoke startOrder; }
services_order() {
  start_order | python3 -c '
import json, sys
order, bars = json.load(sys.stdin), int(sys.argv[1])
presented = next((i for i, e in enumerate(order) if e[0] == "frame" and e[1] >= bars), None)
service = next((i for i, e in enumerate(order) if e[0] == "service"), None)
if service is None: print("no-service")
elif presented is None or service < presented: print("services-first")
else: print("bars-first")' "$monitors"
}
follow_order() {
  start_order | python3 -c '
import json, sys
order = json.load(sys.stdin)
turn_end = next((i for i, e in enumerate(order) if e[0] == "scan-turn-end"), None)
follow = next((i for i, e in enumerate(order) if e[0] == "follow"), None)
if follow is None: print("no-follow")
elif turn_end is None: print("no-scan")
else: print("in-scan-turn" if follow < turn_end else "late")'
}
order_count() { start_order | python3 -c 'import json,sys; print(sum(1 for e in json.load(sys.stdin) if e[0] == sys.argv[1]))' "$1"; }
# The follows the probe noted for one rescan, started once the theme
# runner is idle. A scan's note and its follow come in one emission of
# scanFinished, so the count read once the scan is noted is final.
rescan_follows() {
  local scans follows
  [[ $(theme_idle) == idle ]] || { echo theme-busy; return; }
  scans="$(order_count scan)" || return
  follows="$(order_count follow)" || return
  [[ $(ipc shell rescanPlugins) == ok ]] || { echo rescan-refused; return; }
  for _ in $(seq 1 25); do
    if [[ $(order_count scan) -gt $scans ]]; then echo $(( $(order_count follow) - follows )); return; fi
    sleep 0.2
  done
  echo scan-pending
}
release_reason() { local reason waited; read -r reason waited < <(service_release) && echo "$reason"; }

if restart_over "$repo" "$sandbox/start-order-qs.log"; then
  echo "  latency_first_bar_ms=${first_bar_ms:-unmeasured} budget_ms=$default_first_bar_budget_ms cpu_some_pct=$first_bar_cpu_some_pct plugin_set=default"
  if [[ -n $first_bar_ms && $first_bar_ms -le $default_first_bar_budget_ms ]]; then ok "the first bar of the default set maps within its budget"; else fail "default-set first bar latency ${first_bar_ms:-unmeasured} ms over budget $default_first_bar_budget_ms ms"; fi
  expect "the gate released the services on the first bar frame" first-frame release_reason
  expect "every bar presented its first frame before the core built a service" bars-first services_order
  # The service's build, if the gate's lending snapshot let one through,
  # is refused on the live hold.
  expected_errors+=('plugins: acme\.locker refused: capability=lock held-by=acme\.contention')
  expect_poll "the background holds the lock at start" '["acme.contention"]' lent holders.lock
  expect "the service naming the lock is not built" False record_exists acme.locker
  expect "the start's follow was queued in the turn its scan ended" in-scan-turn follow_order
  expect "a rescan queues one follow" 1 rescan_follows
  check_unexpected_log "the default-set shell's log" "$instance_log"
fi

# copy_tree NAME: a copy of the tree at $sandbox/start-order-NAME, with its
# own bin/ and shell/. edit_tree NAME FILE OLD NEW: in that copy, OLD in
# FILE, a path under it, replaced by NEW; returns 1, with the row failed,
# unless OLD occurs once and the file changed.
copy_tree() { # NAME
  local tree="$sandbox/start-order-$1" dir file
  rm -rf -- "$tree"
  mkdir -p -- "$tree"
  cp -R -- "$repo/shell" "$tree/shell"
  cp -R -- "$repo/bin" "$tree/bin"
  for dir in config themes; do ln -s -- "$repo/$dir" "$tree/$dir"; done
  for file in VERSION LICENSE README.md; do cp -- "$repo/$file" "$tree/$file"; done
}
edit_tree() { # NAME FILE OLD NEW
  local path="$sandbox/start-order-$1/$2"
  cp -- "$path" "$path.orig"
  if python3 -c '
import sys
path, old, new = sys.argv[1:]
text = open(path).read()
if text.count(old) != 1:
    sys.exit("occurs %d times" % text.count(old))
open(path, "w").write(text.replace(old, new))' "$path" "$3" "$4" && ! cmp -s -- "$path" "$path.orig"; then
    ok "the $1 copy's edit applies once to $2"
  else
    fail "the $1 copy could not edit $2"
    return 1
  fi
}

# The service host with no gate: services build in the scan's turn, before
# any bar frame.
if copy_tree ungated && edit_tree ungated shell/Hosts/ServiceHost.qml \
    'model: ServiceGate.release !== "" ? Registry.enabledOfKind("service") : []' \
    'model: Registry.enabledOfKind("service")' \
  && restart_over "$sandbox/start-order-ungated" "$sandbox/start-order-ungated-qs.log"; then
  expect "control: with no gate a service is built before the first bar frame" services-first services_order
fi

# The backgrounds held until a service is built: acme.locker, first in id
# order, claims the lock before the background builds. The tree with no
# gate is no control here: its services build in the scan's turn, and the
# background host, whose binding the scan reaches first, still claims
# first.
if copy_tree backgrounds-late && edit_tree backgrounds-late shell/Hosts/BackgroundHost.qml \
    'readonly property var ids: Registry.enabledOfKind("background").filter(id => {' \
    'readonly property var ids: (Plugins.built["service"] === undefined ? [] : Registry.enabledOfKind("background")).filter(id => {' \
  && restart_over "$sandbox/start-order-backgrounds-late" "$sandbox/start-order-backgrounds-late-qs.log"; then
  expect_poll "control: a background built after the services leaves the lock with the service" '["acme.locker"]' lent holders.lock
fi

# The follow moved onto the gate's release.
if copy_tree follow-on-release && edit_tree follow-on-release shell/shell.qml \
    $'        target: root.guarded ? Registry : null\n        function onScanFinished() { Capabilities.themes.follow(); }' \
    $'        target: root.guarded ? ServiceGate : null\n        function onReleaseChanged() { Capabilities.themes.follow(); }' \
  && restart_over "$sandbox/start-order-follow-on-release" "$sandbox/start-order-follow-on-release-qs.log"; then
  expect "control: a follow on the release is queued after its scan's turn" late follow_order
fi

# The follow run only while the services are held.
if copy_tree follow-held && edit_tree follow-held shell/shell.qml \
    'function onScanFinished() { Capabilities.themes.follow(); }' \
    'function onScanFinished() { if (ServiceGate.release === "") Capabilities.themes.follow(); }' \
  && restart_over "$sandbox/start-order-follow-held" "$sandbox/start-order-follow-held-qs.log"; then
  expect "control: a follow held to the gate queues none for a rescan" 0 rescan_follows
fi

# No bar: the default set with the bar disabled builds none, and the gate
# releases at once. Its control is a gate that waits for a bar however
# many were built: it never releases.
if restart_over "$repo" "$sandbox/start-order-no-bar-qs.log" '["vgs.bar"]' no-bar; then
  expect "with the bar disabled the gate releases with no bar to wait for" no-bar release_reason
  expect_poll "with the bar disabled the services are built" True record_exists vgs.themes
fi
if copy_tree no-bar-held && edit_tree no-bar-held shell/Core/ServiceGate.qml \
    'if (built.length === 0) { open("no-bar", []); return; }' \
    'if (built.length === 0) return;' \
  && restart_over "$sandbox/start-order-no-bar-held" "$sandbox/start-order-no-bar-held-qs.log" '["vgs.bar"]' no-bar; then
  expect "control: a gate that waits when no bar is built never releases" unreleased release_reason
fi

# A bar that never presents, as on a monitor the compositor configures no
# surface for: a copy whose bar window is never shown. The gate releases
# at its deadline and its one warning names the bar host. Its control
# adds a gate that never starts the deadline: it never releases.
bar_hidden() { # NAME
  copy_tree "$1" && edit_tree "$1" shell/Hosts/BarHost.qml \
    $'            WlrLayershell.layer: WlrLayer.Top\n' \
    $'            WlrLayershell.layer: WlrLayer.Top\n            visible: false\n'
}
deadline_warnings() { log_lines 'WARN qml: plugins: services released reason=deadline waited_ms=[0-9]+ unpresented=bar:'; }
if bar_hidden bar-hidden && restart_over "$sandbox/start-order-bar-hidden" "$sandbox/start-order-bar-hidden-qs.log" '[]' no-bar; then
  expect "a bar that never presents holds the services until the deadline" deadline release_reason
  expect "the deadline's one warning names the bar host" 1 deadline_warnings
  expect_poll "past the deadline the services are built" True record_exists vgs.themes
fi
if bar_hidden no-deadline && edit_tree no-deadline shell/Core/ServiceGate.qml $'            deadline.start();\n' '' \
  && restart_over "$sandbox/start-order-no-deadline" "$sandbox/start-order-no-deadline-qs.log" '[]' no-bar; then
  expect "control: a gate with no deadline never releases past a bar that never presents" unreleased release_reason
fi
