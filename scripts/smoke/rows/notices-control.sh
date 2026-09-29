# Control for scripts/smoke/rows/notices.sh's enable trigger: a copy of the
# tree whose Plugins.setEnabled no longer calls Notices.enabled runs as the
# guarded shell, and enabling acme.needs, which still misses a command it
# needs, must raise no notice. Notices.enabled runs before setPluginEnabled
# replies, so the lending record read after the reply is decisive. The copy
# holds its own bin/, since bin/vgsh finds the tree from its own real path,
# and its own shell/; config/ and themes/ are links to the sandbox's. The
# row runs last: it stops the shell rows/read-only-prefix.sh started and
# leaves the copy running for the harness's teardown.
set -euo pipefail
mutant="$sandbox/notice-mutant"
mkdir -p -- "$mutant"
cp -R -- "$repo/shell" "$mutant/shell"
cp -R -- "$repo/bin" "$mutant/bin"
for dir in config themes; do ln -s -- "$repo/$dir" "$mutant/$dir"; done
for file in VERSION LICENSE README.md; do cp -- "$repo/$file" "$mutant/$file"; done
trigger='        if (enabled) Notices.enabled(id);
'
plugins_qml="$mutant/shell/Core/Plugins.qml"
cp -- "$plugins_qml" "$sandbox/notice-mutant-Plugins.qml.orig"
if python3 -c '
import sys
path, needle = sys.argv[1:]
text = open(path).read()
if text.count(needle) != 1:
    sys.exit("the enable trigger occurs %d times" % text.count(needle))
open(path, "w").write(text.replace(needle, ""))' "$plugins_qml" "$trigger" && ! cmp -s -- "$plugins_qml" "$sandbox/notice-mutant-Plugins.qml.orig"; then
  ok "the control copy drops the enable trigger, which occurs once"
else
  fail "the control copy could not drop the enable trigger from $plugins_qml"
fi

# acme.needs sits in the user plugin directory before the copy starts, so
# its first scan finds it and its missing command.
mkdir -p -- "$home/.config/vgs/plugins/acme.needs"
cp -R -- "$repo/scripts/smoke/fixtures/plugins/acme.needs/." "$home/.config/vgs/plugins/acme.needs/"

kill -TERM "$shell_pid" 2>/dev/null || true
for _ in $(seq 1 50); do
  kill -0 "$shell_pid" 2>/dev/null || break
  sleep 0.1
done
wait "$shell_pid" 2>/dev/null || true

mutant_bin="$mutant/bin/vgsh"
spawn "$sandbox/notice-mutant-qs.log" "${shell_env[@]}" PATH="$shim:$(dirname -- "$node_bin"):$PATH" VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR="$shim" "$mutant_bin" run
shell_pid="$spawn_pid"
ipc() {
  "${shell_env[@]}" "$mutant_bin" ipc call "$@" 2>>"$sandbox/ipc.log" | tail -n 1
}
up=false
for _ in $(seq 1 $((timeout_s * 5))); do
  if pong="$(ipc shell ping 2>/dev/null)" && [[ $pong == ok ]]; then up=true; break; fi
  kill -0 "$shell_pid" 2>/dev/null || break
  sleep 0.2
done
if [[ $up == true ]]; then
  ok "the control copy starts as the guarded shell"
else
  fail "the control copy did not answer ping within ${timeout_s}s"
  tail -n 40 "$sandbox/notice-mutant-qs.log"
fi
expect "the control copy is the guarded shell" true ipc shell guarded
needs_required_state() { ipc shell listPlugins | python3 -c 'import json,sys; print(json.dumps([r["state"] for p in json.load(sys.stdin)["plugins"] if p["id"]=="acme.needs" for r in p["requirements"] if r["command"]=="vgs-smoke-needs"]))'; }
expect_poll "the control copy's scan finds acme.needs missing the command it needs" '["missing"]' needs_required_state
expect "no notice shows in the control copy before the enable" null notice_shown
expect "control: enabling acme.needs in the copy without the trigger is allowed" ok ipc shell setPluginEnabled acme.needs true
expect "control: the copy without the enable trigger raises no notice" null notice_shown
