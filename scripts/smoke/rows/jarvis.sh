# This row has no latency ceiling. It polls once per nested IPC round trip.
# The real child runs inside J09, with no account, audio or desktop endpoint.
set -euo pipefail
expected_errors+=('WARN qml: jarvis: stderr=.*Killed.*')

jarvis_wait_ready() {
  local answer kind
  for ((attempt = 0; attempt < 200; attempt++)); do
    answer="$(ipc smoke jarvisProcess)" || return 1
    kind="$(py_reply 'import json,sys; print(json.load(sys.stdin)["lifetime"]["kind"])' <<<"$answer")" || return 1
    if [[ $kind == ready ]]; then
      echo ready
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

jarvis_toasts() {
  ipc shell lent | python3 -c 'import json,sys; d=json.load(sys.stdin)["toasts"]; print(sum(e["plugin"] == "vgs.jarvis" for e in d["visible"] + d["waiting"]))'
}

jarvis_revision() {
  ipc shell listPlugins | python3 -c 'import json,sys; print(next(p["revision"] for p in json.load(sys.stdin)["plugins"] if p["id"] == "vgs.jarvis"))'
}

jarvis_rescan() {
  local before current
  if ! before="$(jarvis_revision)"; then fail "Jarvis revision is unreadable before rescan"; return 1; fi
  expect "the changed Jarvis service rescans" ok ipc shell rescanPlugins
  for ((attempt = 0; attempt < 200; attempt++)); do
    if ! current="$(jarvis_revision)"; then fail "Jarvis revision is unreadable after rescan"; return 1; fi
    [[ $current == "$before" ]] || return
    sleep 0.01
  done
  fail "Jarvis source revision did not change"
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
  launcher="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["pid"])' "$answer")"
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
    launcher="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["pid"])' "$answer")"
    daemon_pid="$(jarvis_descendants "$launcher")"
    kill -KILL "$daemon_pid"
    # Wait for the service to observe this child exit, not just /proc loss.
    for ((attempt = 0; attempt < 300; attempt++)); do
      answer="$(ipc smoke jarvisProcess)"
      if ! kind="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["lifetime"]["kind"])' "$answer")"; then
        fail "Jarvis lifetime is unreadable"
        return 1
      fi
      retries="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["retries"])' "$answer")"
      if [[ $kind == problem || $retries -gt $crash ]]; then break; fi
      sleep 0.01
    done
    if [[ $crash -lt 5 ]]; then
      jarvis_wait_ready >/dev/null
    fi
  done
  answer="$(ipc smoke jarvisProcess)"
  python3 - "$answer" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
ok = d["lifetime"]["kind"] == "problem" and d["retries"] == 5 and d["pid"] is None
ok = ok and d["status"]["daemon"]["tone"] == "danger"
print("problem" if ok else "not-problem")
PY
}

jarvis_enable
jarvis_disable
jarvis_enable
expect "five retries end in problem status" problem jarvis_exhaust
expect "retry exhaustion raises one Jarvis toast" 1 jarvis_toasts
expect "the exhausted service disables" ok ipc shell setPluginEnabled vgs.jarvis false

# The control changes the live retry rule in a disposable plugin copy.
# Its six-crash observation must not satisfy the five-retry assertion.
jarvis_service="$repo/shell/plugins/vgs.jarvis/Service.qml"
cp -- "$jarvis_service" "$sandbox/jarvis-service-original"
python3 - "$jarvis_service" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
needle = "if (retries === 5)"
assert s.count(needle) == 1
p.write_text(s.replace(needle, "if (retries === 6)"))
PY
jarvis_rescan
jarvis_enable
expect "the six-retry control breaks the five-retry assertion" not-problem jarvis_exhaust
expect "the control disables" ok ipc shell setPluginEnabled vgs.jarvis false
cp -- "$sandbox/jarvis-service-original" "$jarvis_service"
jarvis_rescan
jarvis_enable
