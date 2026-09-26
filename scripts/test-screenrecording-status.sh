#!/usr/bin/env bash
# Drive bin/vshell-capture-screenrecording start against a stub recorder and
# check the recording state it leaves in status.json. The shell watches that
# file instead of polling, so the script alone keeps it true:
#   - start returns and closes its output while the recording runs on;
#   - status.json and the pid file go once the recorder dies, with no stop;
#   - a watcher that wakes while its recorder still runs leaves the state;
#   - a watcher that wakes after a newer recording started leaves that
#     recording's state.
# The atomic replace of status.json has no case: no fixture can catch a reader
# between the truncate and the last write, so no edit to it reddens a test.
#
# The recorder is a stub that sleeps and records its pid, killed with SIGKILL
# to stand in for a crash. The crash case runs the real tail, so it proves the
# watcher waits for the recorder. The other two cases put a gated tail first on
# PATH that returns only when the test releases it, so they choose when the
# watcher wakes instead of racing tail's poll. Portal capture skips the region
# picker and postprocessing is off, so no compositor or media tool is needed.
# Every run gets an explicit environment.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script_under_test="$repo_root/bin/vshell-capture-screenrecording"

for tool in jq tail timeout; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'test-screenrecording-status: required tool %s is not installed\n' "$tool" >&2
    exit 1
  }
done

tmp="$(mktemp -d)" || {
  printf 'test-screenrecording-status: could not create a temporary directory\n' >&2
  exit 1
}
recorder_pids=()
# Removing the directory also ends every gated tail still waiting for release.
cleanup() {
  local pid
  for pid in "${recorder_pids[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "${tmp:?}"
}
trap cleanup EXIT INT TERM

stubs="$tmp/stubs"
gated="$tmp/gated"
mutants="$tmp/mutants"
mkdir -p "$stubs" "$gated" "$mutants"

cat >"$stubs/gpu-screen-recorder" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >>"$RECORDER_PIDS"
exec sleep 300
EOF
for tool in notify-send wl-copy slurp hyprpicker hyprctl ffmpeg ffprobe; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$stubs/$tool"
done

# Stands in for `tail --pid=N -f /dev/null`. It records its parent, the watcher,
# then returns once the test creates N.release in the gate directory.
cat >"$gated/tail" <<'EOF'
#!/usr/bin/env bash
pid=""
for arg in "$@"; do
  if [[ $arg == --pid=* ]]; then
    pid="${arg#--pid=}"
  fi
done
[[ -n $pid ]] || exit 2
printf '%s\n' "$PPID" >"$TAIL_GATE/$pid.watcher"
while [[ ! -e $TAIL_GATE/$pid.release ]]; do
  [[ -d $TAIL_GATE ]] || exit 0
  sleep 0.05
done
EOF
chmod +x "$stubs"/* "$gated/tail"

failures=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}
ok() { printf '  ok    %s\n' "$1"; }
both_yes() { [[ $1 == yes && $2 == yes ]]; }
# $1 case key, $2 description, $3 detail on failure, then the test command.
expect() {
  local key="$1" what="$2" detail="$3"
  shift 3
  if "$@"; then
    ok "$what"
  else
    fail "$key" "$detail"
  fi
}

# Start a recording with script $1 in case directory $2. $3 is a directory put
# first on PATH, empty for the real tail. Sets start_rc (124 when start held
# its output open) and rec_pid, empty when no recorder started.
start_in() {
  local script="$1" dir="$tmp/$2" tail_dir="$3"
  mkdir -p "$dir/home" "$dir/out" "$dir/state" "$dir/gate"
  : >"$dir/recorders"
  start_rc=0
  # shellcheck disable=SC2016  # the bash -c program expands its own $1, not this shell
  env -i HOME="$dir/home" PATH="${tail_dir:+$tail_dir:}$stubs:$PATH" XDG_STATE_HOME="$dir/state" \
    RECORDER_PIDS="$dir/recorders" TAIL_GATE="$dir/gate" \
    VSHELL_SCREENRECORD_DIR="$dir/out" VSHELL_SCREENRECORD_PORTAL=true \
    VSHELL_SCREENRECORD_POSTPROCESS=false VSHELL_NO_APP_SCOPE=1 \
    timeout 5 bash -c 'set -o pipefail; "$1" start fullscreen 2>&1 | cat >/dev/null' _ "$script" ||
    start_rc=$?
  rec_pid=""
  if [[ -s $dir/recorders ]]; then
    rec_pid="$(tail -n 1 "$dir/recorders")"
    recorder_pids+=("$rec_pid")
  fi
}

# Wait up to 5 s for process $1 to be gone.
wait_gone() {
  local i
  for ((i = 0; i < 50; i++)); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

# Release the gated watcher of recorder $2 in case $1 and wait for it to finish.
# Sets watcher_done: no when no watcher reached tail or it outlived the wait.
release_watcher() {
  local gate="$tmp/$1/gate" watcher="" i
  watcher_done=no
  for ((i = 0; i < 50; i++)); do
    if [[ -s $gate/$2.watcher ]]; then
      watcher="$(<"$gate/$2.watcher")"
      break
    fi
    sleep 0.1
  done
  [[ -n $watcher ]] || return 0
  : >"$gate/$2.release"
  if wait_gone "$watcher"; then
    watcher_done=yes
  fi
}

# Whether case $1's status.json and pid file both name live recorder $2.
state_names() {
  local state="$tmp/$1/state/vshell-screenrecord"
  kill -0 "$2" 2>/dev/null &&
    jq -e --argjson pid "$2" '.active == true and .pid == $pid' "$state/status.json" >/dev/null 2>&1 &&
    [[ -r $state/pid && "$(<"$state/pid")" == "$2" ]]
}

# Real tail: kill the recorder and wait for the state to clear. Sets
# crash_started and crash_cleared.
scenario_crash() { # $1 script, $2 case
  local state="$tmp/$2/state/vshell-screenrecord" i
  start_in "$1" "$2" ""
  crash_started=no
  crash_cleared=no
  [[ -n $rec_pid ]] || return 0
  crash_started=yes
  kill -KILL "$rec_pid" 2>/dev/null || true
  for ((i = 0; i < 50; i++)); do
    if [[ ! -e $state/status.json && ! -e $state/pid ]]; then
      crash_cleared=yes
      break
    fi
    sleep 0.1
  done
}

# Gated tail: wake the watcher while its recorder runs. Sets alive_started,
# alive_done and alive_kept.
scenario_alive() { # $1 script, $2 case
  start_in "$1" "$2" "$gated"
  alive_started=no
  alive_done=no
  alive_kept=no
  [[ -n $rec_pid ]] || return 0
  alive_started=yes
  release_watcher "$2" "$rec_pid"
  alive_done="$watcher_done"
  if state_names "$2" "$rec_pid"; then
    alive_kept=yes
  fi
}

# Gated tail: recorder A dies, recorder B starts, then A's watcher wakes. Sets
# newer_started, newer_done and newer_kept.
scenario_newer() { # $1 script, $2 case
  local first second
  start_in "$1" "$2" "$gated"
  first="$rec_pid"
  newer_started=no
  newer_done=no
  newer_kept=no
  [[ -n $first ]] || return 0
  kill -KILL "$first" 2>/dev/null || true
  wait_gone "$first" || return 0
  start_in "$1" "$2" "$gated"
  second="$rec_pid"
  [[ -n $second && $second != "$first" ]] || return 0
  newer_started=yes
  release_watcher "$2" "$first"
  newer_done="$watcher_done"
  if state_names "$2" "$second"; then
    newer_kept=yes
  fi
}

echo "=== cases ==="
scenario_crash "$script_under_test" crash
expect start-closes-output "start closes its output" "start_rc=$start_rc" \
  test "$start_rc" -eq 0
expect start-records-pid "start launches the recorder" "crash_started=$crash_started" \
  test "$crash_started" = yes
expect crashed-recorder-clears-status "a killed recorder clears status.json" "crash_cleared=$crash_cleared" \
  test "$crash_cleared" = yes

scenario_alive "$script_under_test" alive
expect live-recorder-keeps-status "a watcher that wakes during its recording keeps status.json" \
  "alive_started=$alive_started alive_done=$alive_done alive_kept=$alive_kept" \
  both_yes "$alive_done" "$alive_kept"

scenario_newer "$script_under_test" newer
expect newer-recording-keeps-status "a watcher that wakes after a newer recording started keeps that recording" \
  "newer_started=$newer_started newer_done=$newer_done newer_kept=$newer_kept" \
  both_yes "$newer_done" "$newer_kept"

echo "=== must-fail controls ==="
# Copy the script to $1 with each following ANCHOR REPLACEMENT pair applied.
# Each anchor must occur exactly once, so a control whose anchor drifted
# reports itself as broken.
build_mutant() {
  local mutant="$1" text count
  shift
  text="$(<"$script_under_test")"
  while (($# >= 2)); do
    count="$(grep -cF -- "$1" "$script_under_test")" || count=0
    if [[ $count -ne 1 ]]; then
      fail control-anchor "anchor occurs $count time(s), want 1: $1"
      return 1
    fi
    text="${text/"$1"/"$2"}"
    shift 2
  done
  printf '%s\n' "$text" >"$mutant"
  chmod +x "$mutant"
}

# shellcheck disable=SC2016  # bash source of the script under test, quoted verbatim as its anchor
watcher_launch='watch_recorder_exit "$pid" </dev/null >/dev/null 2>>"$LOG_FILE" &'
# shellcheck disable=SC2016  # bash source of the script under test, quoted verbatim as its anchor
tail_wait='tail --pid="$1" -f /dev/null ||'
watcher_clear='recording_status >/dev/null'
# shellcheck disable=SC2016  # bash source substituted into the mutant, quoted verbatim
unconditional_clear='rm -f "$PID_FILE"; clear_status'

if build_mutant "$mutants/no-watcher" "$watcher_launch" ':'; then
  scenario_crash "$mutants/no-watcher" no-watcher
  expect control-no-watcher "dropping the exit watcher reddens the crashed-recorder case" \
    "crash_started=$crash_started crash_cleared=$crash_cleared" \
    test "$crash_started/$crash_cleared" = yes/no
fi

# shellcheck disable=SC2016  # bash source substituted into the mutant, quoted verbatim
if build_mutant "$mutants/shared-output" "$watcher_launch" 'watch_recorder_exit "$pid" &'; then
  scenario_crash "$mutants/shared-output" shared-output
  expect control-shared-output "handing the watcher the caller's output reddens the start case" \
    "crash_started=$crash_started start_rc=$start_rc" \
    test "$crash_started/$start_rc" = yes/124
fi

if build_mutant "$mutants/unconditional-clear" "$watcher_clear" "$unconditional_clear"; then
  scenario_newer "$mutants/unconditional-clear" unconditional-clear
  expect control-unconditional-clear "clearing without the liveness check reddens the newer-recording case" \
    "newer_started=$newer_started newer_done=$newer_done newer_kept=$newer_kept" \
    test "$newer_started/$newer_done/$newer_kept" = yes/yes/no
fi

if build_mutant "$mutants/no-wait-clear" "$tail_wait" 'false ||' "$watcher_clear" "$unconditional_clear"; then
  scenario_alive "$mutants/no-wait-clear" no-wait-clear
  expect control-no-wait-clear "clearing without waiting reddens the live-recorder case" \
    "alive_started=$alive_started alive_kept=$alive_kept" \
    test "$alive_started/$alive_kept" = yes/no
fi

if [[ $failures -ne 0 ]]; then
  printf '\ntest-screenrecording-status: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'test-screenrecording-status: all checks passed\n'
