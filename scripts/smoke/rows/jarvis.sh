# This row has no latency ceiling. It polls once per nested IPC round trip.
# The real child runs inside J09, with no account, audio or desktop endpoint.
set -euo pipefail
expected_errors+=('WARN qml: jarvis: stderr=.*Killed.*')
expected_errors+=('WARN qml: jarvis: stderr=jarvis: node=21[.]0[.]0 need=22')
expected_errors+=('WARN qml: jarvis: hello=timeout')

jarvis_ready() { # EXPECTED_RETRIES, zero for every fresh startup
  ipc smoke jarvisProcess | py_reply '
import json,sys
d=json.load(sys.stdin)
expected=int(sys.argv[1])
if d["retries"] > expected:
    print("unexpected-retries=" + str(d["retries"]))
elif d["retries"] == expected and d["lifetime"]["kind"] == "ready":
    print("ready")
else:
    print("pending")
' "${1:-0}"
}

jarvis_wait_ready() { # EXPECTED_RETRIES
  local answer expected="${1:-0}"
  for ((attempt = 0; attempt < 200; attempt++)); do
    answer="$(jarvis_ready "$expected")" || return 1
    if [[ $answer == ready ]]; then
      echo ready
      return
    fi
    if [[ $answer == unexpected-retries=* ]]; then
      printf '%s\n' "$answer"
      return
    fi
    sleep 0.01
  done
  printf 'not-ready %s\n' "$answer"
}

# Read the actual daemon below the Process-owned J09 launcher. PIDs come
# only from that launcher's /proc descendants, never a name-based search.
jarvis_descendants() { # LAUNCHER_PID
  python3 - "$1" <<'PY'
import pathlib, sys
pending = [int(sys.argv[1])]
found = []
while pending:
    pid = pending.pop()
    try:
        children = pathlib.Path(f"/proc/{pid}/task/{pid}/children").read_text().split()
        pending.extend(map(int, children))
        args = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        executable = pathlib.Path(f"/proc/{pid}/exe").resolve().name
    except FileNotFoundError:
        continue
    if executable == "node" and any(arg.endswith(b"/backend/jarvisd.js") for arg in args):
        found.append(pid)
if len(found) != 1:
    sys.exit(f"jarvis-row: daemon-count={len(found)}")
print(found[0])
PY
}

jarvis_enable() {
  expect "Jarvis enables" ok ipc shell setPluginEnabled vgs.jarvis true
  expect "the real Jarvis daemon answers hello" ready jarvis_wait_ready
}

jarvis_reject_timeout_start() {
  (failures=0 behaviour_failures=0
   jarvis_enable >"$sandbox/jarvis-timeout-control-assertions.log"
   echo "$failures")
}

jarvis_toasts() {
  ipc shell lent | py_reply 'import json,sys; d=json.load(sys.stdin)["toasts"]; print(sum(e["plugin"] == "vgs.jarvis" for e in d["visible"] + d["waiting"]))'
}

jarvis_revision() {
  ipc shell listPlugins | py_reply 'import json,sys; print(next(p["revision"] for p in json.load(sys.stdin)["plugins"] if p["id"] == "vgs.jarvis"))'
}

jarvis_launcher_pid() {
  local launcher
  if ! launcher="$(py_reply 'import json,sys; print(json.load(sys.stdin)["pid"])')" || [[ ! $launcher =~ ^[1-9][0-9]*$ ]]; then
    fail "Jarvis launcher PID is unavailable: value=$launcher"
    return 1
  fi
  printf '%s\n' "$launcher"
}

jarvis_rescan() {
  local before current
  if ! before="$(jarvis_revision)"; then fail "Jarvis revision is unreadable before rescan"; return 1; fi
  expect "the changed Jarvis service rescans" ok ipc shell rescanPlugins
  for ((attempt = 0; attempt < 200; attempt++)); do
    if ! current="$(jarvis_revision)"; then fail "Jarvis revision is unreadable after rescan"; return 1; fi
    [[ $current == "$before" ]] || return 0
    sleep 0.01
  done
  fail "Jarvis source revision did not change"
  return 1
}

jarvis_no_pid() { # PID
  for ((attempt = 0; attempt < 200; attempt++)); do
    if [[ ! -e /proc/$1 ]]; then echo absent; return; fi
    sleep 0.01
  done
  echo present
}

jarvis_disable() {
  local answer launcher daemon_pid
  answer="$(ipc smoke jarvisProcess)"
  launcher="$(jarvis_launcher_pid <<<"$answer")" || return 1
  daemon_pid="$(jarvis_descendants "$launcher")"
  expect "Jarvis disables" ok ipc shell setPluginEnabled vgs.jarvis false
  expect "disable releases the real daemon" absent jarvis_no_pid "$daemon_pid"
  expect "disable releases the namespace launcher" absent jarvis_no_pid "$launcher"
  expect "disable drops the service" absent ipc smoke jarvisProcess
}

jarvis_exhaust() {
  local answer launcher daemon_pid retries kind
  for ((crash = 0; crash <= 5; crash++)); do
    answer="$(ipc smoke jarvisProcess)"
    launcher="$(jarvis_launcher_pid <<<"$answer")" || return 1
    daemon_pid="$(jarvis_descendants "$launcher")"
    kill -KILL "$daemon_pid"
    # Wait for the service to observe this child exit, not just /proc loss.
    for ((attempt = 0; attempt < 300; attempt++)); do
      answer="$(ipc smoke jarvisProcess)"
      if ! kind="$(py_reply 'import json,sys; print(json.load(sys.stdin)["lifetime"]["kind"])' <<<"$answer")"; then
        fail "Jarvis lifetime is unreadable"
        return 1
      fi
      if ! retries="$(py_reply 'import json,sys; print(json.load(sys.stdin)["retries"])' <<<"$answer")" || [[ ! $retries =~ ^[0-9]+$ ]]; then
        fail "Jarvis retry count is unavailable: value=$retries"
        return 1
      fi
      if [[ $kind == problem || $retries -gt $crash ]]; then break; fi
      sleep 0.01
    done
    if [[ $crash -lt 5 ]]; then
      answer="$(jarvis_wait_ready "$((crash + 1))")" || return 1
      if [[ $answer != ready ]]; then
        printf 'crash=%s readiness=%s\n' "$crash" "$answer"
        return 1
      fi
    fi
  done
  answer="$(ipc smoke jarvisProcess)"
  py_reply '
import json, sys
d = json.load(sys.stdin)
ok = d["lifetime"]["kind"] == "problem" and d["retries"] == 5 and d["pid"] is None
ok = ok and d["status"]["daemon"]["tone"] == "danger"
print("problem" if ok else "not-problem")
' <<<"$answer"
}

jarvis_lock_answer() {
  ipc smoke jarvisProcess | py_reply '
import json,sys
d=json.load(sys.stdin)
if d["retries"] != 0:
    print("stale")
elif d["lifetime"]["kind"] == "ready":
    print(d["status"]["daemon"]["text"])
else:
    print("pending")
'
}

jarvis_session() { # EXPECTED_GATE_REASON
  ipc smoke jarvisProcess | py_reply '
import json,sys
d=json.load(sys.stdin)["status"].get("detail")
if d is None:
    print("pending")
else:
    s=d["state"]
    ok=(d["phase"] == "down" and d["seq"] >= 1 and s["gate"] == {"kind":"down","reason":sys.argv[1]}
        and s["capture"] == {"kind":"closed"} and s["action"] == {"kind":"none"} and s["gen"] == 0)
    print("session" if ok else "wrong-session")
' "$1"
}

jarvis_session_assertion() {
  (failures=0 behaviour_failures=0
   expect_poll "the service consumes the real Session state" session jarvis_session unconfigured >"$sandbox/jarvis-session-control-assertions.log"
   echo "$failures")
}

jarvis_seen_hello() {
  [[ -s $jarvis_seen ]] && echo seen || echo pending
}

jarvis_permanent() {
  ipc smoke jarvisProcess | py_reply '
import json,sys
d=json.load(sys.stdin)
if d["retries"] != 0:
    print("retried")
elif d["lifetime"]["kind"] == "problem" and d["pid"] is None and d["status"]["daemon"]["text"] == "Problem: jarvis: node=21.0.0 need=22":
    print("permanent")
else:
    print("pending")
'
}

jarvis_lock_case() { # EXPECTED
  rm -f -- "$jarvis_gate" "$jarvis_seen"
  expect "the test-only holder unlocks before startup" ok probe unlock
  expect "the gated Jarvis service enables" ok ipc shell setPluginEnabled vgs.jarvis true
  expect_poll "the daemon has consumed its first hello" seen jarvis_seen_hello
  expect "the real test-only holder locks during startup" ok probe lock
  expect_poll "the compositor confirms the fixture lock" true read_service lockSecure
  : >"$jarvis_gate"
  expect_poll "startup keeps the current lock snapshot without restarting" "$1" jarvis_lock_answer
  if [[ $1 == "Locked; no capture" ]]; then
    expect_poll "the reducer observes lock without capture" session jarvis_session locked
  fi
  expect "the fixture unlocks without authentication" ok probe unlock
  if [[ $1 == "Locked; no capture" ]]; then
    expect_poll "the reducer observes unlock without capture" session jarvis_session unconfigured
    expect_poll "the running daemon observes unlock" "Ready; no capture" jarvis_lock_answer
  fi
  expect "the gated service disables" ok ipc shell setPluginEnabled vgs.jarvis false
}

jarvis_key_value() {
  ipc smoke jarvisProcess | py_reply '
import json,sys
d=json.load(sys.stdin)
rows=d["status"].get("keys", [])
expected=[{"label":"fixture / test", "value":sys.argv[1]}]
print("matched" if rows == expected else "pending")
' "$1"
}

jarvis_enable
expect_poll "the healthy skeleton keeps the Session gate unconfigured" session jarvis_session unconfigured
expect_poll "Jarvis publishes only the fixture key presence" matched jarvis_key_value present
jarvis_disable

jarvis_service="$repo/shell/plugins/vgs.jarvis/Service.qml"
jarvis_backend="$repo/shell/plugins/vgs.jarvis/backend/jarvisd.js"
cp -- "$jarvis_service" "$sandbox/jarvis-service-original"
cp -- "$jarvis_backend" "$sandbox/jarvis-backend-original"
# The control keeps the receive branch but removes its publication. The
# ordinary state read, not a text pin, must fail on this disposable copy.
python3 - "$jarvis_service" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
needle='const result = shell.status.set("detail", { phase: message.phase, seq: message.seq, state: message.state });'
assert s.count(needle)==1
changed=s.replace(needle, needle.replace("= shell.status", "= false ? shell.status").replace(" });", ' }) : "ok";'))
assert changed != s
p.write_text(changed)
PY
jarvis_rescan
jarvis_enable
expect "removing Session publication breaks its real consumer assertion" 1 jarvis_session_assertion
jarvis_disable
cp -- "$sandbox/jarvis-service-original" "$jarvis_service"
jarvis_rescan

jarvis_drop="$sandbox/jarvis-dropped-first-reply"
"$node_bin" "$source_repo/scripts/fixtures/jarvis/prepare.js" --drop-initial-replies "$jarvis_backend" "$jarvis_drop"
jarvis_rescan
jarvis_timeouts="$(log_lines 'jarvis: hello=timeout')" || { fail "Jarvis timeout log is unreadable"; return 1; }
expect "a timeout recovery fails the actual ordinary startup assertion once" 1 jarvis_reject_timeout_start
expect "the intentional recovery still reaches ready with its explicit allowance" ready jarvis_wait_ready 1
expect_log "the control retains its real hello timeout log" "$((jarvis_timeouts + 1))" 'jarvis: hello=timeout'
expect "the first-reply suppression control disables" ok ipc shell setPluginEnabled vgs.jarvis false
cp -- "$sandbox/jarvis-backend-original" "$jarvis_backend"
jarvis_rescan

jarvis_gate="$sandbox/jarvis-first-reply-gate"
jarvis_seen="$sandbox/jarvis-first-hello"
expect "the test-only session holder enables" ok ipc shell setPluginEnabled acme.probe true
"$node_bin" "$source_repo/scripts/fixtures/jarvis/prepare.js" --gate-daemon "$jarvis_backend" "$jarvis_gate" "$jarvis_seen"
jarvis_rescan
jarvis_lock_case "Locked; no capture"
python3 - "$jarvis_service" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
needle="onLockedChanged: hello()"
assert s.count(needle)==1
p.write_text(s.replace(needle, 'onLockedChanged: if (lifetime.kind === "ready") hello()'))
PY
jarvis_rescan
jarvis_lock_case stale
cp -- "$sandbox/jarvis-service-original" "$jarvis_service"
cp -- "$sandbox/jarvis-backend-original" "$jarvis_backend"
jarvis_rescan

"$node_bin" "$source_repo/scripts/fixtures/jarvis/prepare.js" --floor-daemon "$jarvis_backend"
jarvis_rescan
expect "the unsupported Node fixture enables" ok ipc shell setPluginEnabled vgs.jarvis true
expect_poll "Node exit 78 is a permanent problem without retries" permanent jarvis_permanent
expect "the unsupported Node service disables" ok ipc shell setPluginEnabled vgs.jarvis false
python3 - "$jarvis_service" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
needle="completion.code === 78"
assert s.count(needle)==1
p.write_text(s.replace(needle, "completion.code === 79"))
PY
jarvis_rescan
expect "the Node-floor recovery control enables" ok ipc shell setPluginEnabled vgs.jarvis true
expect_poll "the missing permanent-exit rule wrongly retries" retried jarvis_permanent
expect "the recovery control disables" ok ipc shell setPluginEnabled vgs.jarvis false
cp -- "$sandbox/jarvis-service-original" "$jarvis_service"
cp -- "$sandbox/jarvis-backend-original" "$jarvis_backend"
jarvis_rescan

jarvis_enable
expect "five retries end in problem status" problem jarvis_exhaust
expect "retry exhaustion raises one Jarvis toast" 1 jarvis_toasts
expect "the exhausted service disables" ok ipc shell setPluginEnabled vgs.jarvis false

# The control changes the live retry rule in a disposable plugin copy.
# Its six-crash observation must not satisfy the five-retry assertion.
python3 - "$jarvis_service" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
needle = "if (permanent || retries === 5)"
assert s.count(needle) == 1
p.write_text(s.replace(needle, "if (permanent || retries === 6)"))
PY
jarvis_rescan
jarvis_enable
expect "the six-retry control breaks the five-retry assertion" not-problem jarvis_exhaust
expect "the control disables" ok ipc shell setPluginEnabled vgs.jarvis false
cp -- "$sandbox/jarvis-service-original" "$jarvis_service"
jarvis_rescan
jarvis_enable

# The core's floating terminal receives only the declared script path.
# Its disposable script is a no-auth fixture, not the real key entry flow.
jarvis_keys="$repo/shell/plugins/vgs.jarvis/Keys.qml"
cp -- "$jarvis_keys" "$sandbox/jarvis-keys-original"
cp -- "$repo/shell/plugins/vgs.jarvis/tui/add-key.sh" "$sandbox/jarvis-add-key-original"
printf '#!/bin/sh\nexit 0\n' >"$repo/shell/plugins/vgs.jarvis/tui/add-key.sh"
terminal_stand_in
terminal_ready "Jarvis Add key"
jarvis_rescan
jarvis_listed_key() {
  ipc shell listTuis | py_reply '
import json,sys
rows=json.load(sys.stdin)
want={"key":"vgs.jarvis/add-key","plugin":"vgs.jarvis","name":"add-key",
      "title":"Add Jarvis key","label":"Add key","icon":"key-round","group":"Jarvis"}
print("listed" if want in rows else "missing")
'
}
expect "the key-entry action is listed" listed jarvis_listed_key
jarvis_open_key() {
  local revision snapshot
  revision="$(jarvis_revision)" || return 1
  snapshot="$rt_dir/vgsh-sources-$shell_qs_pid/$revision"
  forget_record
  expect "Add key opens by its core TUI key" ok ipc shell openTui vgs.jarvis/add-key
  expect_poll "Add key hands the terminal only its declared script" \
    "$(words --app-id=org.vgs.tui "--title=VGS · Add Jarvis key" -- "$tui_self" present --presentation full \
      --plugin vgs.jarvis --dir "$snapshot" --record vgs.jarvis/add-key --run RUN --record-dir "$rt_dir/vgs/tui" \
      --app-id org.vgs.tui --window-title "VGS · Add Jarvis key" -- tui/add-key.sh)" recorded
  expect_run_end "the fixture Add key terminal ends" vgs.jarvis/add-key
}
expect_poll "the key row starts present" matched jarvis_key_value present
printf 'locked\n' >"$sandbox/jarvis-world/key-mode"
jarvis_open_key
expect_poll "the service checks presence after Add key ends" matched jarvis_key_value locked
python3 - "$jarvis_keys" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
needle="onEndedAtChanged: if (endedAt !== null) refresh()"
assert s.count(needle)==1
p.write_text(s.replace(needle, "onEndedAtChanged: {}"))
PY
printf 'present\n' >"$sandbox/jarvis-world/key-mode"
jarvis_rescan
expect_poll "the no-refresh control first publishes present" matched jarvis_key_value present
printf 'locked\n' >"$sandbox/jarvis-world/key-mode"
jarvis_open_key
jarvis_refresh_control() {
  (failures=0 behaviour_failures=0
   expect_poll "Add key must refresh presence" matched jarvis_key_value locked >"$sandbox/jarvis-refresh-control.log"
   echo "$failures")
}
expect "removing the end refresh breaks its actual assertion" 1 jarvis_refresh_control
cp -- "$sandbox/jarvis-keys-original" "$jarvis_keys"
cp -- "$sandbox/jarvis-add-key-original" "$repo/shell/plugins/vgs.jarvis/tui/add-key.sh"
printf 'present\n' >"$sandbox/jarvis-world/key-mode"
jarvis_rescan
expect_poll "restored key status contains no secret" matched jarvis_key_value present
