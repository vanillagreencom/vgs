# vgs.agent-warden, D041. The service is the one reader of the warden's
# status file. The row writes vsys's own fixture documents into the
# sandbox's runtime dir, $rt_dir/agent-warden/status.json, each replaced by
# rename as the warden replaces it, with its time and its events' set to
# now, so it is fresh, or ten minutes back, so it is stale. It reads each
# state back through the plugin's `status` IPC function, which answers the
# record the core holds, and reads the plugin's Settings rows back from the
# Settings window. An older warden's state.json alone reads as Update the
# warden, and the empty directory as Not set up. `vsys` reads absent or
# present from the scan as a stub on the sandbox PATH comes and goes; the
# host's PATH sets its first answer. A status written 85 s back and left
# unchanged turns stale on the service's own timer, with no file change.
# Two controls are copies of the plugin installed over the bundled one: a
# logic copy that ignores staleness reads the stale document as calm, and
# a service copy whose timer derives nothing keeps the ageing status calm
# past its stale moment. The harness starts the plugin disabled; the row
# ends with it disabled, its runtime files gone and no stub on PATH.
set -euo pipefail
warden_dir="$rt_dir/agent-warden"
warden_fixtures="$repo/scripts/smoke/fixtures/agent-warden"
warden_copy="$home/.config/vgs/plugins/vgs.agent-warden"
rm -rf -- "$warden_dir"
# warden_put NAME AGE: status-NAME.json with its time and every event's set
# AGE seconds before now, replaced into place by rename; prints the time.
warden_put() {
  python3 - "$warden_fixtures/status-$1.json" "$warden_dir" "$2" <<'PY'
import json, os, sys, time
source, target, age = sys.argv[1], sys.argv[2], int(sys.argv[3])
doc = json.load(open(source))
moment = int(time.time()) - age
doc["time"] = moment
for event in doc["events"]:
    event["time"] = moment
tmp = os.path.join(target, "status.tmp.%d" % os.getpid())
with open(tmp, "w") as out:
    json.dump(doc, out)
os.replace(tmp, os.path.join(target, "status.json"))
print(moment)
PY
}
# warden_raw TEXT: TEXT as status.json, replaced into place by rename.
warden_raw() { printf '%s' "$1" >"$warden_dir/status.tmp.raw" && mv -T -- "$warden_dir/status.tmp.raw" "$warden_dir/status.json"; }
warden_values() { ipc vgs.agent-warden invoke status ''; }
# warden_value KEY: one published value as JSON, `null` when unpublished.
warden_value() { warden_values | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get(sys.argv[1])))' "$1"; }
# The published detail's state and reason, and each item's kind and level.
warden_state() { warden_values | python3 -c 'import json,sys; d=json.load(sys.stdin).get("detail"); print("unpublished" if d is None else json.dumps([d["state"], d["reason"], d["issues"], [[i["kind"], i["level"]] for i in d["items"]]]))'; }
warden_lent() { ipc shell lent | python3 -c 'import json,sys; r=json.load(sys.stdin)["status"].get("vgs.agent-warden"); print(json.dumps(r if r is None else r["keys"]))'; }
warden_rows() { settings_rows | python3 -c 'import json,sys; r=[p for p in json.load(sys.stdin) if p["id"] == "vgs.agent-warden"][0]["status"]; print(json.dumps([[s["label"], s["report"], s["value"], s["tone"], s["command"]] for s in r]))'; }
# The answer the scan gives for vsys on the sandbox PATH.
vsys_on_path() { if "${shell_env[@]}" PATH="$shim:$(dirname -- "$node_bin"):$PATH" bash -c 'command -v vsys' >/dev/null; then echo '"present"'; else echo '"absent"'; fi; }
expected_errors+=('agent-warden: status=unreadable cause=json ' 'agent-warden: status=schema schema=2\.0 ' 'plugins: hidden by a higher-precedence plugin with the same id: vgs\.agent-warden')

expect "enabling the agent warden is allowed" ok ipc shell setPluginEnabled vgs.agent-warden true
expect_poll "the agent warden's service is built" True record_exists vgs.agent-warden
expect_poll "no warden directory reads as not set up" '["not-set-up", null, 0, []]' warden_state
expect "an absent status logs nothing" 0 log_lines 'agent-warden: status='
expect "the warden row says it is not set up" '{"tone": "info", "text": "Not set up"}' warden_value warden
expect "no agent count is published before a status" null warden_value agents
expect "the lending record holds the published keys" '["detail", "vsys", "warden"]' warden_lent
vsys_first="$(vsys_on_path)"
expect "vsys reads as the scan finds it on the sandbox PATH" "$vsys_first" warden_value vsys

cp -- "$warden_fixtures/state.json" "$warden_dir/state.json"
expect_poll "an older warden's state.json alone reads as update the warden" '["update-warden", null, 0, []]' warden_state
expect "the warden row asks for an update" '{"tone": "warning", "text": "Update the warden"}' warden_value warden

calm_time="$(warden_put calm 0)"
expect_poll "a fresh calm status reads as calm" '["calm", null, 0, []]' warden_state
expect "the warden row says it checks" '{"tone": "ok", "text": "Checking"}' warden_value warden
expect "one agent runs in the calm status" 1 warden_value agents
expect "the last check is the status time" "$((calm_time * 1000))" warden_value lastCheck
expect "the lending record holds every declared key" '["agents", "detail", "lastCheck", "vsys", "warden"]' warden_lent

# Each document replaces the last by rename, as the warden writes it.
warden_put near-limit 0 >/dev/null
expect_poll "a lane near its limits needs a look" '["look", null, 1, [["near", "look"]]]' warden_state
warden_put holding-off 0 >/dev/null
expect_poll "held-off moves above the slowdown point are a problem" '["problem", null, 2, [["headroom", "problem"], ["slowdown", "look"]]]' warden_state
warden_put partial 0 >/dev/null
expect_poll "a partial move is a problem" '["problem", null, 1, [["partial", "problem"]]]' warden_state
warden_put reaped 0 >/dev/null
expect_poll "a cleanup is a problem" '["problem", null, 1, [["reaped", "problem"]]]' warden_state
warden_put reaped 600 >/dev/null
expect_poll "a status ten minutes old reads as not checking" '["not-checking", "stale", 0, []]' warden_state
expect "the warden row says it stopped checking" '{"tone": "warning", "text": "Stopped checking"}' warden_value warden
# A fresh status the warden stops rewriting: the file stays as it is and
# the service's timer turns it stale at its time plus 90 s, which is about
# 5 s after the write. The poll allows 15 s.
warden_stamp() { stat -c '%i %Y' -- "$warden_dir/status.json"; }
# warden_ages LABEL: polls for up to 15 s until the unchanged status reads
# as stale, then checks the file was not replaced meanwhile.
warden_ages() {
  local stamp got="" i
  stamp="$(warden_stamp)" || { fail "$1: the status file is unreadable"; return; }
  for i in $(seq 1 75); do
    got="$(warden_state)" || got=""
    [[ $got == '["not-checking", "stale", 0, []]' ]] && break
    sleep 0.2
  done
  if [[ $got != '["not-checking", "stale", 0, []]' ]]; then fail "$1: got $got"; return; fi
  if [[ $(warden_stamp) == "$stamp" ]]; then ok "$1"; else fail "$1: the status file changed during the wait"; fi
}
warden_put calm 85 >/dev/null
expect_poll "a status 85 s old reads as calm" '["calm", null, 0, []]' warden_state
warden_ages "the unchanged status turns stale at its moment"
warden_raw '{'
expect_poll "a status that is not JSON reads as not checking" '["not-checking", "unreadable", 0, []]' warden_state
expect "the warden row says the status is unreadable" '{"tone": "danger", "text": "Status unreadable"}' warden_value warden
expect_log "the unreadable status is logged" 1 'agent-warden: status=unreadable cause=json '
warden_raw '{"schema": "2.0"}'
expect_poll "a newer major reads as not checking" '["not-checking", "schema", 0, []]' warden_state
expect_log "the unsupported major is logged" 1 'agent-warden: status=schema schema=2\.0 '
calm_time="$(warden_put calm 0)"
expect_poll "a fresh status after the refusals reads as calm again" '["calm", null, 0, []]' warden_state

# The Settings page draws the four rows, never `detail`.
expect "enabling the Settings plugin for the warden's rows is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect_poll "the Settings service is built" True record_exists vgs.settings
expect "the Settings window is summoned" ok ipc shell summon panel vgs.settings '{}'
expect_poll "the Settings rows show the warden, the agents, the last check and vsys" "$(python3 -c 'import json,sys; print(json.dumps([["Warden", "reported", {"tone": "ok", "text": "Checking"}, "success", "vsys warden install"], ["Agents running", "reported", 1, "", ""], ["Last check", "reported", int(sys.argv[1]) * 1000, "", ""], ["vsys", "reported", json.loads(sys.argv[2]), {"present": "success", "absent": "warning"}[json.loads(sys.argv[2])], "curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vsys/main/install.sh | bash"]]))' "$calm_time" "$vsys_first")" warden_rows
expect "the Settings window is hidden" ok ipc shell hide panel vgs.settings
expect "disabling the Settings plugin after the rows is allowed" ok ipc shell setPluginEnabled vgs.settings false

# vsys follows the scan: a stub on the sandbox PATH is present after a
# rescan and gone after the next, and the service is not rebuilt.
printf '#!/bin/sh\nexit 0\n' >"$shim/vsys"; chmod 755 "$shim/vsys"
expect "a rescan after vsys arrives starts" ok ipc shell rescanPlugins
expect_poll "vsys reads as present" '"present"' warden_value vsys
rm -f -- "$shim/vsys"
expect "a rescan after vsys goes starts" ok ipc shell rescanPlugins
expect_poll "vsys reads as the host PATH gives it again" "$vsys_first" warden_value vsys

rm -f -- "$warden_dir/status.json"
expect_poll "state.json left alone reads as update the warden again" '["update-warden", null, 0, []]' warden_state
rm -f -- "$warden_dir/state.json"
expect_poll "an empty directory reads as not set up again" '["not-set-up", null, 0, []]' warden_state

expect "disabling the agent warden is allowed" ok ipc shell setPluginEnabled vgs.agent-warden false
expect_poll "the disabled plugin holds no status record" null warden_lent

# warden_control FILE NEEDLE REPLACEMENT: the plugin copied over the
# bundled one with NEEDLE, which must occur once in FILE, replaced; then a
# rescan and the copy enabled. warden_uncontrol: the copy disabled and
# removed with the runtime files, and the bundled plugin back.
warden_control() {
  local scans
  mkdir -p -- "$warden_copy"
  cp -R -- "$repo/shell/plugins/vgs.agent-warden/." "$warden_copy/"
  if python3 -c '
import sys
path, needle, replacement = sys.argv[1:]
text = open(path).read()
if text.count(needle) != 1:
    sys.exit("the rule occurs %d times" % text.count(needle))
open(path, "w").write(text.replace(needle, replacement))' "$warden_copy/$1" "$2" "$3"; then ok "the control copy of $1 drops its rule"; else fail "the control copy of $1 could not be made"; fi
  scans="$(log_lines 'plugins: scan complete changed=true')" || fail "the instance log is unreadable before the control copy"
  expect "a rescan after installing the control copy starts" ok ipc shell rescanPlugins
  expect_log "the rescan publishes the control copy" "$((scans + 1))" 'plugins: scan complete changed=true'
  expect "enabling the control copy is allowed" ok ipc shell setPluginEnabled vgs.agent-warden true
  expect_poll "the control copy made the warden directory and reads no warden" '["not-set-up", null, 0, []]' warden_state
}
warden_uncontrol() {
  local scans
  expect "disabling the control copy is allowed" ok ipc shell setPluginEnabled vgs.agent-warden false
  rm -rf -- "$warden_copy" "$warden_dir"
  scans="$(log_lines 'plugins: scan complete changed=true')" || fail "the instance log is unreadable after the control copy"
  expect "a rescan after removing the control copy starts" ok ipc shell rescanPlugins
  expect_log "the rescan brings the bundled plugin back" "$((scans + 1))" 'plugins: scan complete changed=true'
  expect_poll "the bundled agent warden is known again" True plugin_known vgs.agent-warden
}

# Control: a logic copy that ignores staleness reads the stale document as
# calm, so the stale rows above turn red on it.
warden_control WardenLogic.js "if (Math.abs(now - checkedAt) > STALE_AFTER_MS) {" "if (false) {"
warden_put calm 600 >/dev/null
expect_poll "the staleness control reads the stale document as calm" '["calm", null, 0, []]' warden_state
warden_uncontrol

# Control: a service copy whose timer derives nothing keeps an unchanged
# status calm past its stale moment, so the ageing row above turns red on
# it. The sleep waits out that moment, about 5 s after the write, with 5 s
# more for a derivation that would come late.
warden_control Service.qml "onTriggered: root.derive()" "onTriggered: {}"
warden_put calm 85 >/dev/null
expect_poll "the timer control reads the fresh status as calm" '["calm", null, 0, []]' warden_state
sleep 10
expect "the timer control keeps the unchanged status calm past its stale moment" '["calm", null, 0, []]' warden_state
warden_uncontrol
