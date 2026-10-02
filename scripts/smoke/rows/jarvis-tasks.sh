# The Jarvis service's half of coding tasks, against the real core: a
# daemon request opens the `task` TUI, the reply carries the core's answer
# and the TUI's run state reaches the daemon; the live-task count reaches
# the status record; the stop-task IPC handle sends the intent and a failed
# stop raises its toast. No task script, agent or tmux runs: the stand-in
# terminal holds the shipped script's run, the requests come from a gated
# daemon fixture, and the one task record is a synthetic starting record.
# No latency ceiling. Reads poll once per nested IPC round trip; the
# fixture polls its gates every 10 ms.
set -euo pipefail
expected_errors+=('WARN qml: jarvis: task-stop=not-alive task=smoke-task-[0-9]+')
task_daemon="$repo/shell/plugins/vgs.jarvis/backend/jarvisd.js"
task_service="$repo/shell/plugins/vgs.jarvis/Service.qml"
task_gates="$sandbox/jarvis-task-gates"
task_state="$home/.local/state/vgs/jarvis"
task_round=0
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
task_last() { # FILE: the fixture's last logged value, or none
  python3 - "$task_gates/$1" <<'PY'
import json, os, sys
lines = open(sys.argv[1]).read().splitlines() if os.path.exists(sys.argv[1]) else []
print(json.dumps(json.loads(lines[-1])) if lines else "none")
PY
}
task_count() { # the service's `tasks` status value
  ipc smoke jarvisProcess | py_reply '
import json,sys
print(json.dumps(json.load(sys.stdin)["status"].get("tasks")))
'
}
task_record() { # ID KIND JSON: one synthetic record through the shipped producer
  "$node_bin" "$repo/shell/plugins/vgs.jarvis/backend/task-event" --state "$task_state" "$1" "$2" <<<"$3" >/dev/null
}
# A fresh round: no gate or log, no recorded argv, and one new starting task.
task_reset() {
  rm -f -- "${task_gates:?}"/request-* "${task_gates:?}/replies.jsonl" "${task_gates:?}/tui-states.jsonl" \
    "${task_gates:?}/task-stops.jsonl"
  forget_record
  task_round=$((task_round + 1))
  task_id="smoke-task-$task_round"
  task_record "$task_id" create "{\"goal\":\"Smoke fixture\",\"cwd\":\"$home\",\"agent\":\"fixture\",\"account\":\"\"}"
}
task_scenario() {
  expect_poll "the service reports the idle task TUI once the daemon is ready" false task_last tui-states.jsonl
  expect_poll "the daemon's live task count reaches the status" 1 task_count
  hold_runs
  : >"$task_gates/request-1"
  expect_poll "the first task request opens the TUI" '[{"n": 1, "answer": "ok"}]' task_log replies.jsonl
  expect_poll "the core runs the task TUI with the spec path alone" \
    "$(words vgs.jarvis/task tui/task.sh "$task_gates/spec-1.json")" recorded_tail
  expect_poll "the service forwards the running task TUI" true task_last tui-states.jsonl
  : >"$task_gates/request-2"
  expect_poll "the core refuses a second task TUI as busy" \
    '[{"n": 1, "answer": "ok"}, {"n": 2, "answer": "refused: tui=task reason=busy"}]' task_log replies.jsonl
  release_runs
  expect_run_end "the held task TUI ends" vgs.jarvis/task
  expect_poll "the service forwards the task TUI's end" false task_last tui-states.jsonl
  task_record "$task_id" lost '{"seq":0}'
  expect "the stop-task IPC handle answers" ok ipc vgs.jarvis invoke stop-task "$task_id"
  expect_poll "the daemon receives the task-stop intent" "\"$task_id\"" task_last task-stops.jsonl
  expect_poll "a failed stop raises its toast" 1 ipc smoke jarvisMuteNotices "Coding task not stopped" "Task $task_id: not-alive"
  expect_poll "the stop's observation clears the count" 0 task_count
  expect "the stop-task IPC handle refuses a malformed id" "refused: jarvis: protocol=task-id" \
    ipc vgs.jarvis invoke stop-task "../$task_id"
}
# task_control LABEL TARGET: `killed` when the scenario, run on a planted
# Service defect, fails at the step TARGET names; other failures do not count.
task_control() {
  (failures=0 behaviour_failures=0
   task_scenario >"$sandbox/jarvis-task-$1-control.log"
   if grep -qF -- "  FAIL  $2:" "$sandbox/jarvis-task-$1-control.log"; then echo killed; else echo missed; fi)
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
task_round_start() {
  task_reset
  jarvis_rescan
  jarvis_enable
}

task_round_start
task_scenario
jarvis_disable

task_controls=(
  "forward|onTaskTuiRunningChanged: sendTuiState()|onTaskTuiRunningChanged: {}|the service forwards the running task TUI"
  "argv|shell.tui.run(\"task\", args, () => {|shell.tui.run(\"task\", [], () => {|the core runs the task TUI with the spec path alone"
  "count|const reply = shell.status.set(\"tasks\", message.count);|const reply = \"ok\";|the daemon's live task count reaches the status"
  "intent|        send(fields);
        return \"ok\";|        return \"ok\";|the daemon receives the task-stop intent"
  "toast|if (message.answer === \"stopped\") return;|return;|a failed stop raises its toast"
)
for task_row in "${task_controls[@]}"; do
  IFS='|' read -r -d '' task_name task_needle task_replacement task_target <<<"$task_row" || true
  task_target="${task_target%$'\n'}"
  task_plant "$task_needle" "$task_replacement"
  task_round_start
  expect "the $task_name control fails at its own step" killed task_control "$task_name" "$task_target"
  release_runs
  jarvis_disable
done

cp -- "$sandbox/jarvis-task-service-original" "$task_service"
cp -- "$sandbox/jarvis-task-daemon-original" "$task_daemon"
rm -f -- "${task_gates:?}"/request-* "${task_gates:?}/replies.jsonl" "${task_gates:?}/tui-states.jsonl" \
  "${task_gates:?}/task-stops.jsonl"
jarvis_rescan
