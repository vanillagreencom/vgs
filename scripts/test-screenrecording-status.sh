#!/usr/bin/env bash
# Drive bin/vshell-capture-screenrecording start against a stub recorder and
# check the recording state it leaves in status.json. The shell watches that
# file instead of polling, so the script alone keeps it true:
#   - start returns and closes its output while the recording runs on;
#   - status.json stays while the recorder lives;
#   - status.json and the pid file go once the recorder dies, with no stop.
# The atomic replace of status.json has no case: no fixture can catch a reader
# between the truncate and the last write, so no edit to it reddens a test.
#
# The recorder is a stub that sleeps, killed with SIGKILL to stand in for a
# crash. Portal capture skips the region picker, and postprocessing is off, so
# no compositor or media tool is needed. Every run gets an explicit environment.
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
cleanup() {
  local pid
  for pid in "${recorder_pids[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "${tmp:?}"
}
trap cleanup EXIT INT TERM

stubs="$tmp/stubs"
mutants="$tmp/mutants"
mkdir -p "$stubs" "$mutants"
printf '#!/usr/bin/env bash\nexec sleep 300\n' >"$stubs/gpu-screen-recorder"
for tool in notify-send wl-copy slurp hyprpicker hyprctl ffmpeg ffprobe; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$stubs/$tool"
done
chmod +x "$stubs"/*

failures=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}
ok() { printf '  ok    %s\n' "$1"; }

# Start a recording with $1 in a fresh state directory named $2, then read the
# state back while the recorder lives and after it is killed. Sets start_rc
# (124 when start held its output open), started, alive_kept, crash_cleared.
run_scenario() {
  local script="$1" name="$2" state_dir pid="" i
  state_dir="$tmp/$name/state/vshell-screenrecord"
  mkdir -p "$tmp/$name/home" "$tmp/$name/out" "$tmp/$name/state"
  start_rc=0
  env -i HOME="$tmp/$name/home" PATH="$stubs:$PATH" XDG_STATE_HOME="$tmp/$name/state" \
    VSHELL_SCREENRECORD_DIR="$tmp/$name/out" VSHELL_SCREENRECORD_PORTAL=true \
    VSHELL_SCREENRECORD_POSTPROCESS=false VSHELL_NO_APP_SCOPE=1 \
    timeout 5 bash -c 'set -o pipefail; "$1" start fullscreen 2>&1 | cat >/dev/null' _ "$script" ||
    start_rc=$?

  started=no
  [[ -r $state_dir/pid ]] && pid="$(<"$state_dir/pid")"
  if [[ $pid =~ ^[0-9]+$ ]]; then
    started=yes
    recorder_pids+=("$pid")
  fi

  alive_kept=no
  crash_cleared=no
  [[ $started == yes ]] || return 0

  # Longer than the watcher's one-second poll, so a watcher that clears a live
  # recording has had its chance.
  sleep 1.5
  if kill -0 "$pid" 2>/dev/null &&
    jq -e --argjson pid "$pid" '.active == true and .pid == $pid' "$state_dir/status.json" >/dev/null 2>&1; then
    alive_kept=yes
  fi

  kill -KILL "$pid" 2>/dev/null || true
  for ((i = 0; i < 50; i++)); do
    if [[ ! -e $state_dir/status.json && ! -e $state_dir/pid ]]; then
      crash_cleared=yes
      break
    fi
    sleep 0.1
  done
}

echo "=== cases ==="
run_scenario "$script_under_test" real
[[ $start_rc -eq 0 ]] && ok "start closes its output" ||
  fail start-closes-output "start_rc=$start_rc"
[[ $started == yes ]] && ok "start records the recorder pid" ||
  fail start-records-pid "started=$started"
[[ $alive_kept == yes ]] && ok "a live recorder keeps status.json" ||
  fail live-recorder-keeps-status "alive_kept=$alive_kept"
[[ $crash_cleared == yes ]] && ok "a killed recorder clears status.json" ||
  fail crashed-recorder-clears-status "crash_cleared=$crash_cleared"

echo "=== must-fail controls ==="
# Copy the script with ANCHOR replaced by REPLACEMENT. The anchor must occur
# exactly once, so a control whose anchor drifted reports itself as broken.
build_mutant() { # $1 mutant path, $2 anchor, $3 replacement
  local text count
  count="$(grep -cF -- "$2" "$script_under_test")" || count=0
  if [[ $count -ne 1 ]]; then
    fail control-anchor "anchor occurs $count time(s), want 1: $2"
    return 1
  fi
  text="$(<"$script_under_test")"
  printf '%s\n' "${text/"$2"/"$3"}" >"$1"
  chmod +x "$1"
}

# shellcheck disable=SC2016  # bash source of the script under test, quoted verbatim as its anchor
watcher_launch='watch_recorder_exit "$pid" </dev/null >/dev/null 2>>"$LOG_FILE" &'

if build_mutant "$mutants/no-watcher" "$watcher_launch" ':'; then
  run_scenario "$mutants/no-watcher" no-watcher
  if [[ $started == yes && $crash_cleared == no ]]; then
    ok "dropping the exit watcher reddens the crashed-recorder case"
  else
    fail control-no-watcher "started=$started crash_cleared=$crash_cleared"
  fi
fi

# shellcheck disable=SC2016  # bash source of the script under test, quoted verbatim
if build_mutant "$mutants/shared-output" "$watcher_launch" 'watch_recorder_exit "$pid" &'; then
  run_scenario "$mutants/shared-output" shared-output
  if [[ $started == yes && $start_rc -eq 124 ]]; then
    ok "handing the watcher the caller's output reddens the start case"
  else
    fail control-shared-output "started=$started start_rc=$start_rc"
  fi
fi

if [[ $failures -ne 0 ]]; then
  printf '\ntest-screenrecording-status: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'test-screenrecording-status: all checks passed\n'
