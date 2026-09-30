# The polkit agent, vgs.polkit: a first-party service and overlay. The
# harness starts it disabled, since polkit is exclusive and the capability
# rows' fixture, acme.probe, holds it. This row disables the fixture when
# an earlier row left it enabled, enables vgs.polkit once no plugin holds
# polkit, reads the agent the core lends it
# and the agent status its service publishes back, asserts that no prompt
# surface exists without an authentication flow and that a summon with none
# is refused, and disables it again, which destroys the agent.
#
# A live flow cannot run here: it needs polkitd and the setuid
# polkit-agent-helper-1, which would run PAM against the real account and
# could trip pam_faillock. The sandbox's system bus has no polkitd, so the
# agent stays unregistered. The row reads that no flow ever went live, from
# the core's count over the shell's whole life, which the row never
# restarts, and that the harness's helper watcher saw no
# polkit-agent-helper-1 or other authentication helper over the whole row;
# the lock row's stand-in is the watcher's control. What the prompt draws from a flow is
# scripts/test-polkit-model.js's.
#
# The control installs a copy of the plugin in the user directory, whose id
# wins, with the prompt's refusal of a flowless summon removed: the same
# summon reading maps a prompt then, so the reading is not vacuous. The
# row ends with vgs.polkit disabled and the fixture as it found it.
set -euo pipefail
polkit_lent() { ipc shell lent | py_reply 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v.get(k) if isinstance(v, dict) else None
print(json.dumps(v))' "$1"; }
polkit_status() { ipc smoke statusValues vgs.polkit | py_reply 'import json,sys; v=json.load(sys.stdin).get("agent"); print(json.dumps(v if v is None else [v["tone"], v["text"]]))'; }
# The summon a request would make, with no request live: the host's answer.
flowless_summon() { ipc shell summon overlay vgs.polkit '{}'; }
unregistered='["warning", "Not registered with polkitd: another polkit agent holds this session, or polkitd is not running"]'

auth_watch_start "$sandbox/polkit-auth-helpers.log"
expect "the helper watcher scans the tree that holds the shell" yes in_harness_tree "$shell_qs_pid"
expect "the polkit plugin starts disabled in the sandbox" False plugin_enabled vgs.polkit
probe_enabled="$(plugin_enabled acme.probe)" || probe_enabled=unreadable
case "$probe_enabled" in
  True) expect "disabling the capability fixture, which holds polkit, is allowed" ok ipc shell setPluginEnabled acme.probe false ;;
  False|absent) ;;
  *) fail "the capability fixture's enabled state is unreadable: $probe_enabled" ;;
esac
expect_poll "no plugin holds polkit before the row" null polkit_lent holders.polkit
expect_poll "the core builds no agent while nothing holds polkit" false polkit_lent polkitAgent
expect "enabling the polkit plugin is allowed" ok ipc shell setPluginEnabled vgs.polkit true
expect_poll "the polkit service is built" True record_exists vgs.polkit
expect_poll "vgs.polkit holds polkit" '["vgs.polkit"]' polkit_lent holders.polkit
expect_poll "the core built the agent for it" true polkit_lent polkitAgent
expect "the agent is not registered on a bus without polkitd" false polkit_lent polkitRegistered
expect_poll "the service publishes that polkitd did not accept the agent" "$unregistered" polkit_status
expect "no prompt surface exists without a flow" 0 layer_count vgs:overlay
expected_errors+=('summon host: vgs\.polkit open\(\) failed: polkit: refused: flow=none')
expect "a summon with no flow is refused" "refused: open-failed=vgs.polkit" flowless_summon
expect "the refused summon maps no prompt surface" 0 layer_count vgs:overlay
expect "no authentication helper runs under the shell" none auth_helpers "$shell_qs_pid"

# Control: the same reading over a prompt that opens with no flow.
control_dir="$home/.config/vgs/plugins/vgs.polkit"
mkdir -p -- "$control_dir"
cp -R -- "$repo/shell/plugins/vgs.polkit/." "$control_dir/"
python3 - "$control_dir/Prompt.qml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = '        if (flow === null) throw new Error("polkit: refused: flow=none");\n'
assert text.count(needle) == 1, "polkit control: the refusal must match once"
open(path, "w").write(text.replace(needle, ""))
PY
expected_errors+=('plugins: .*vgs\.polkit')
expect "rescan over the control copy answers ok" ok ipc shell rescanPlugins
control_dir_of() { ipc shell listPlugins | py_reply 'import json,sys; print([p["dir"] for p in json.load(sys.stdin)["plugins"] if p["id"] == "vgs.polkit"][0])'; }
expect_poll "the control copy is the plugin the shell runs" "$control_dir" control_dir_of
expect_poll "the control copy's agent is lent" true polkit_lent polkitAgent
got="$(flowless_summon)" || got="unreadable"
if [[ $got == ok ]]; then ok "control: a prompt that opens with no flow is summoned"; else fail "control: the flowless summon reading got [$got] over a prompt that opens with no flow"; fi
expect_poll "control: the prompt that opened with no flow maps a surface" 1 layer_count vgs:overlay
expect "the control copy's prompt hides" ok ipc shell hide overlay vgs.polkit
rm -r -- "$control_dir"
expect "rescan after removing the control copy answers ok" ok ipc shell rescanPlugins
expect_poll "the shipped plugin runs again" "$repo/shell/plugins/vgs.polkit" control_dir_of
expect_poll "no prompt surface is left" 0 layer_count vgs:overlay

expect "no authentication request went live in this shell" 0 polkit_lent polkitFlows
expect "no authentication helper runs under the shell at the row's end" none auth_helpers "$shell_qs_pid"
kill "$auth_watch_pid" 2>/dev/null || fail "stopping the helper watcher pid $auth_watch_pid failed"
expect "over the whole row, the watcher saw no authentication helper" "" cat -- "$sandbox/polkit-auth-helpers.log"
expect "disabling the polkit plugin is allowed" ok ipc shell setPluginEnabled vgs.polkit false
expect_poll "disable destroyed the agent" false polkit_lent polkitAgent
expect "disable released polkit" null polkit_lent holders.polkit
polkit_record() { ipc shell lent | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["status"].get("vgs.polkit")))'; }
expect "disable dropped the plugin's status record" null polkit_record
if [[ $probe_enabled == True ]]; then
  expect "re-enabling the capability fixture is allowed" ok ipc shell setPluginEnabled acme.probe true
  expect_poll "the fixture holds polkit again" '["acme.probe"]' polkit_lent holders.polkit
fi
