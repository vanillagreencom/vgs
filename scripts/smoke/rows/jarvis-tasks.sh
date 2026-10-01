# The Jarvis service's half of a floating coding task, against the real
# core tui capability: a daemon request opens the `task` TUI, the reply
# carries the core's answer, and the TUI's run state reaches the daemon.
# No task script, agent or tmux runs: the stand-in terminal holds the
# shipped script's run, and the requests come from a gated daemon fixture.
# No latency ceiling. Reads poll once per nested IPC round trip; the
# fixture polls its gates every 10 ms.
set -euo pipefail
task_daemon="$repo/shell/plugins/vgs.jarvis/backend/jarvisd.js"
task_service="$repo/shell/plugins/vgs.jarvis/Service.qml"
task_gates="$sandbox/jarvis-task-gates"
mkdir -p -- "$task_gates"
cp -- "$task_daemon" "$sandbox/jarvis-task-daemon-original"
cp -- "$task_service" "$sandbox/jarvis-task-service-original"
"$node_bin" "$source_repo/scripts/fixtures/jarvis/prepare.js" --task-requests "$task_daemon" "$task_gates"
terminal_stand_in
terminal_ready "Jarvis tasks"

task_log() { # FILE: the fixture's log lines as one JSON list
  python3 - "$task_gates/$1" <<'PY'
import json, os, sys
path = sys.argv[1]
lines = open(path).read().splitlines() if os.path.exists(path) else []
print(json.dumps([json.loads(line) for line in lines]))
PY
}
task_tui_state() { # the last task TUI state the daemon received, or none
  python3 - "$task_gates/tui-states.jsonl" <<'PY'
import json, os, sys
lines = open(sys.argv[1]).read().splitlines() if os.path.exists(sys.argv[1]) else []
print(json.dumps(json.loads(lines[-1])) if lines else "none")
PY
}
task_reset() {
  rm -f -- "${task_gates:?}"/request-* "${task_gates:?}/replies.jsonl" "${task_gates:?}/tui-states.jsonl"
  forget_record
}
task_scenario() {
  expect_poll "the service reports the idle task TUI once the daemon is ready" false task_tui_state
  hold_runs
  : >"$task_gates/request-1"
  expect_poll "the first task request opens the TUI" '[{"n": 1, "answer": "ok"}]' task_log replies.jsonl
  expect_poll "the core runs the task TUI with the spec path alone" \
    "$(words vgs.jarvis/task tui/task.sh "$task_gates/spec-1.json")" recorded_tail
  expect_poll "the service forwards the running task TUI" true task_tui_state
  : >"$task_gates/request-2"
  expect_poll "the core refuses a second task TUI as busy" \
    '[{"n": 1, "answer": "ok"}, {"n": 2, "answer": "refused: tui=task reason=busy"}]' task_log replies.jsonl
  release_runs
  expect_run_end "the held task TUI ends" vgs.jarvis/task
  expect_poll "the service forwards the task TUI's end" false task_tui_state
}
task_control() { # LABEL: run the scenario on a planted Service defect
  (failures=0 behaviour_failures=0
   task_scenario >"$sandbox/jarvis-task-$1-control.log"
   echo "$failures")
}
task_control_count() {
  local output
  output="$("$@")" || return 1
  [[ ${output##*$'\n'} -gt 0 ]] && echo failed || echo passed
}
# task_plant NEEDLE REPLACEMENT: one Service defect, text kept, effect gone.
task_plant() {
  cp -- "$sandbox/jarvis-task-service-original" "$task_service"
  python3 - "$task_service" "$1" "$2" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
assert not p.is_symlink()
s = p.read_text()
assert s.count(sys.argv[2]) == 1
changed = s.replace(sys.argv[2], sys.argv[3])
assert changed != s
p.write_text(changed)
PY
}

task_reset
jarvis_rescan
jarvis_enable
task_scenario
jarvis_disable

task_plant "onTaskTuiRunningChanged: sendTuiState()" "onTaskTuiRunningChanged: {}"
task_reset
jarvis_rescan
jarvis_enable
expect "dropping the run-state forward breaks the daemon's TUI reading" failed task_control_count task_control forward
release_runs
jarvis_disable

task_plant "String(shell.tui.run(message.name, message.args, () => {" "String(shell.tui.run(message.name, [], () => {"
task_reset
jarvis_rescan
jarvis_enable
expect "dropping the request's spec argument breaks the core's argv" failed task_control_count task_control argv
release_runs
jarvis_disable

cp -- "$sandbox/jarvis-task-service-original" "$task_service"
cp -- "$sandbox/jarvis-task-daemon-original" "$task_daemon"
task_reset
jarvis_rescan
