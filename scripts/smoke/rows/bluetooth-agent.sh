# The Bluetooth pairing agent, capability `bluetoothAgent` (D085), over
# the bluetoothctl stand-in on the shell's PATH
# (docs/architecture/validation-smoke-devices.md): the child the core
# starts is the stand-in, which replays the transcript the row plants and
# records its argv and every stdin line. No row reaches the host's BlueZ
# or system bus.
#
# The fixture acme.pairing holds the capability and drives it over IPC.
# Rows, over the first transcript: a lease reads pending when begin
# returns and ready once the stand-in printed the default acknowledgement;
# the child ran as `bluetoothctl --agent KeyboardDisplay` and read
# `default-agent`; the confirm prompt the transcript prints shows as one
# request with its code; answering it true writes `yes`; release writes
# `agent off`, closes stdin, and the lending record reads no child and no
# lease. The core writes each of its own commands after 17 spaces, so no
# held prompt accepts one (docs/architecture/bluetooth-agent.md), and the
# stand-in reads them so. Over the second: a copy of the fixture under another id, which
# names the capability, is not built while acme.pairing holds it and is
# built once acme.pairing is disabled; disabling acme.pairing with its lease
# held ends the child after `agent off` and EOF and releases its hold. The
# control is the third transcript, which answers the default-agent request
# with a failure: the same lease reads refused with that reason and no
# child is left. Every poll is expect_poll's: 25 reads 0.2 s apart. The
# rival's absence is rival_absent's: 10 reads 0.2 s apart, after its
# enabled flag reads True.
set -euo pipefail
devices_ready bluetooth-agent || return 0
pairing_dir="$home/.config/vgs/plugins/acme.pairing"
rival_dir="$home/.config/vgs/plugins/acme.pairing-rival"
mkdir -p "$pairing_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.pairing/." "$pairing_dir/"
python3 - "$repo/scripts/smoke/fixtures/plugins/acme.pairing" "$rival_dir" <<'PY'
import json, pathlib, shutil, sys
shutil.copytree(sys.argv[1], sys.argv[2])
manifest = pathlib.Path(sys.argv[2]) / "manifest.json"
data = json.loads(manifest.read_text())
data["id"] = "acme.pairing-rival"
manifest.write_text(json.dumps(data))
PY
pairing() { ipc acme.pairing invoke "$1" "${2:-}"; }
pairing_read() { ipc smoke readInstance service acme.pairing "$1"; }
pairing_requests() { pairing_read requests | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))'; }
agent_lent() { ipc shell lent | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["bluetoothAgent"], sort_keys=True))'; }
agent_holders() { ipc shell lent | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["holders"].get("bluetoothAgent")))'; }
# The stand-in's records since the row's count before a transcript: its
# argv lists, and its stdin lines and end in order.
agent_calls_since() { device_calls bluetoothctl | py_reply 'import json,sys; print(json.dumps([c for c in json.load(sys.stdin)[int(sys.argv[1]):] if isinstance(c, list)]))' "$1"; }
agent_stdin_since() { device_calls bluetoothctl | py_reply 'import json,sys; print(json.dumps([c.get("stdin", "EOF") for c in json.load(sys.stdin)[int(sys.argv[1]):] if isinstance(c, dict)]))' "$1"; }
agent_count() { device_calls bluetoothctl | py_reply 'import json,sys; print(len(json.load(sys.stdin)))'; }
# A refused plugin gets no slot, so no build is tried and nothing is
# logged: its refusal reads as an instance that stays missing. Every read
# False prints `absent`; the first other reading is printed as it is.
rival_absent() {
  local reading
  for _ in $(seq 1 10); do
    reading="$(record_exists acme.pairing-rival)" || return
    [[ $reading == False ]] || { echo "$reading"; return 0; }
    sleep 0.2
  done
  echo absent
}
off='{"leases": [], "refusal": "", "requests": 0, "running": false, "state": "off"}'

# bluetoothctl's own output: a line clear before each message, the prompt
# drawn again after it, the agent's prompt in bold with no newline.
device_transcript '[
  {"out": "Waiting to connect to bluetoothd...\r[bluetoothctl]> \r\u001b[KAgent registered\n[bluetoothctl]> "},
  {"in": "                 default-agent"},
  {"out": "                 default-agent\n[bluetoothctl]> \r\u001b[KDefault agent request successful\n[bluetoothctl]> \r\u001b[KRequest confirmation\n[bluetoothctl]> \r\u001b[1;39m\u001b[1;39m[agent] Confirm passkey 004821 (yes/no): \u001b[0m\u001b[0m"},
  {"in": "yes"},
  {"out": "yes\n[bluetoothctl]> "},
  {"in": "                 agent off"},
  {"out": "                 agent off\n[bluetoothctl]> \r\u001b[KAgent unregistered\n[bluetoothctl]> "}
]'
expect "rescan after adding the pairing fixtures answers ok" ok ipc shell rescanPlugins
expect_poll "the pairing fixture is discovered" True plugin_known acme.pairing
expect_poll "the rival fixture is discovered" True plugin_known acme.pairing-rival
expect "enabling the pairing fixture is allowed" ok ipc shell setPluginEnabled acme.pairing true
expect_poll "the pairing fixture's service is built" True record_exists acme.pairing
expect_poll "the fixture holds the Bluetooth agent" '["acme.pairing"]' agent_holders
expect "the agent runs no child before a lease" "$off" agent_lent
before="$(agent_count)" || { fail "bluetooth agent: the stand-in's calls are unreadable"; return 0; }
expect "a lease reads pending when begin returns" pending pairing begin "pair a test device"
expect_poll "the lease reads ready after the default acknowledgement" '"ready"' pairing_read leaseState
expect "the capability reads ready" true pairing_read agentReady
expect "the child is bluetoothctl with the agent's capability" '[["--agent", "KeyboardDisplay"]]' agent_calls_since "$before"
expect_poll "the planted confirm prompt is one request with its code" '[{"code": "004821", "entered": 0, "id": 1, "kind": "confirm", "service": ""}]' pairing_requests
expect "answering the request true answers ok" ok pairing answer '1|true'
expect_poll "the request is answered" '[]' pairing_requests
expect_poll "the stand-in read default-agent, then yes" '["                 default-agent", "yes"]' agent_stdin_since "$before"
expect "releasing the lease answers ok" ok pairing release
expect_poll "release unregisters the agent and closes the child's stdin" '["                 default-agent", "yes", "                 agent off", "EOF"]' agent_stdin_since "$before"
expect_poll "the lending record reads no child and no lease" "$off" agent_lent

device_transcript '[
  {"out": "Agent registered\n"},
  {"in": "                 default-agent"},
  {"out": "Default agent request successful\n"},
  {"in": "                 agent off"},
  {"out": "Agent unregistered\n"}
]'
before="$(agent_count)" || { fail "bluetooth agent: the stand-in's calls are unreadable"; return 0; }
expect "a second lease reads pending when begin returns" pending pairing begin "pair before disable"
expect_poll "the second lease reads ready" '"ready"' pairing_read leaseState
# The build, if it raced a lending snapshot that predates the hold, is
# refused on the live hold and logs this; a settled snapshot logs nothing.
expected_errors+=('plugins: acme\.pairing-rival refused: capability=bluetoothAgent held-by=acme\.pairing')
expect "enabling the rival is allowed" ok ipc shell setPluginEnabled acme.pairing-rival true
expect_poll "the rival reads enabled" True plugin_enabled acme.pairing-rival
expect "the rival is not built while the fixture holds the agent" absent rival_absent
expect "disabling the fixture with its lease held is allowed" ok ipc shell setPluginEnabled acme.pairing false
expect_poll "disable ends the child after agent off and EOF" '["                 default-agent", "                 agent off", "EOF"]' agent_stdin_since "$before"
expect_poll "the lending record reads no child and no lease after disable" "$off" agent_lent
expect_poll "the rival builds once the fixture let go" True record_exists acme.pairing-rival
expect_poll "the rival holds the agent" '["acme.pairing-rival"]' agent_holders
expect "disabling the rival is allowed" ok ipc shell setPluginEnabled acme.pairing-rival false
expect_poll "no plugin holds the agent" null agent_holders

# Control: a refused default role leaves the same lease refused.
device_transcript '[
  {"out": "Agent registered\n"},
  {"in": "                 default-agent"},
  {"out": "Failed to request default agent: org.bluez.Error.Failed\n"}
]'
refusal="refused: agent=busy reason=default-failed error=org.bluez.Error.Failed"
expected_errors+=("bluetoothAgent: refused: agent=busy reason=default-failed error=org\\.bluez\\.Error\\.Failed")
expect "enabling the pairing fixture again is allowed" ok ipc shell setPluginEnabled acme.pairing true
expect_poll "the pairing fixture's service is built again" True record_exists acme.pairing
expect "control: a lease reads pending when begin returns" pending pairing begin "pair against a refusal"
expect_poll "control: a refused default role refuses the lease" '"refused"' pairing_read leaseState
expect "control: the lease names the refusal" "\"$refusal\"" pairing_read leaseRefusal
expect "control: the capability does not read ready" false pairing_read agentReady
expect_poll "control: no child is left" "{\"leases\": [{\"id\": 3, \"reason\": \"pair against a refusal\", \"state\": \"refused\"}], \"refusal\": \"$refusal\", \"requests\": 0, \"running\": false, \"state\": \"failed\"}" agent_lent
expect "releasing the refused lease answers ok" ok pairing release
expect "the record reads off once the refused lease is released" "{\"leases\": [], \"refusal\": \"$refusal\", \"requests\": 0, \"running\": false, \"state\": \"off\"}" agent_lent
expect "disabling the pairing fixture is allowed" ok ipc shell setPluginEnabled acme.pairing false
expect_poll "no plugin holds the agent at the row's end" null agent_holders
device_transcript -
