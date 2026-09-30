#!/usr/bin/env bash
# Controls for the lifetime of `vgsh run`, the runner: it holds the
# instance lock, starts the shell as its child and waits on it
# (docs/decisions/D053-runner-holds-the-instance-lock.md), and starts it
# again after an exit as its supervision table decides
# (docs/decisions/D069-runner-supervises-the-shell.md); and of the stop
# `vgsh restart` sends it. Each row runs the runner against a stub qs and
# a stub hyprctl in a runtime directory of its own and reads a verdict line
# whose words the rows pin: who the lock file and VGSH_RUNNER_PID name,
# whether the shell or a process it leaves behind holds the lock, the
# runner's exit status, how many shells it started, its keyed stderr lines,
# the notices it asked Hyprland for and which process outlives which. Each
# rule has a must-fail control on a copy of bin/vgsh.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

for tool in setpriv flock timeout; do
  command -v "$tool" >/dev/null || { echo "test-vgsh-run: status=not-measured missing=$tool"; exit 77; }
done

# Every runner, shell and left-behind process a row starts is killed on
# exit, whatever the row left running. The rows run inside command
# substitutions, so the pids go to a file.
track() { printf '%s\n' "$@" >>"$tmp/started"; }
cleanup() {
  local pid
  if [[ -r $tmp/started ]]; then
    while IFS= read -r pid; do kill -KILL "$pid" 2>/dev/null || true; done <"$tmp/started"
  fi
  rm -rf -- "${tmp:?}"
}
trap cleanup EXIT

# The stub qs answers the preflight's `--version`, and `ipc` calls as
# `vgsh restart` makes them: shell.locked false, shell.guarded true. Run as
# the shell, it appends its pid to STUB_RECORD.pids and writes
# `pid= runner= parent= lockfds=` to STUB_RECORD: its pid,
# VGSH_RUNNER_PID, its parent's pid and how many of its descriptors are
# open on STUB_LOCK. With STUB_CHILD_GATE it then starts a process that
# runs until that file exists, 20 s at most, writing its pid beside the
# gate as GATE.pid; the process inherits every descriptor the stub has.
# STUB_TERM_EXIT makes it answer TERM by exiting with that status 0.3 s
# later; STUB_SHELL_HOLD makes it sleep that long; STUB_PLAN, words of
# SECONDS:STATUS, makes the Nth shell a runner starts sleep the Nth word's
# seconds and exit its status, the last word serving every later shell;
# otherwise it exits STUB_EXIT.
cat >"$tmp/qs" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then echo "Quickshell 0.3.1"; exit 0; fi
if [[ ${1:-} == ipc ]]; then
  case "${5:-} ${6:-}" in
    "shell locked") echo false ;;
    "shell guarded") echo true ;;
    *) echo "stub qs: unexpected ipc call: $*"; exit 1 ;;
  esac
  exit 0
fi
printf '%s\n' "$$" >>"${STUB_RECORD:?}.pids"
lockfds=0
for fd in /proc/$$/fd/*; do
  [[ $(readlink -- "$fd" 2>/dev/null) == "${STUB_LOCK:?}" ]] && lockfds=$((lockfds + 1))
done
printf 'pid=%s runner=%s parent=%s lockfds=%s\n' "$$" "${VGSH_RUNNER_PID:-unset}" "$PPID" "$lockfds" >"$STUB_RECORD.part"
mv -- "$STUB_RECORD.part" "$STUB_RECORD"
if [[ -n ${STUB_CHILD_GATE:-} ]]; then
  timeout 20 sh -c 'until [ -e "$1" ]; do sleep 0.05; done' sh "$STUB_CHILD_GATE" </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" >"$STUB_CHILD_GATE.pid"
fi
if [[ -n ${STUB_TERM_EXIT:-} ]]; then
  trap 'sleep 0.3; exit "$STUB_TERM_EXIT"' TERM
  while :; do sleep 0.05; done
fi
[[ -n ${STUB_SHELL_HOLD:-} ]] && exec sleep "$STUB_SHELL_HOLD"
if [[ -n ${STUB_PLAN:-} ]]; then
  read -ra plan <<<"$STUB_PLAN"
  launch="$(wc -l <"$STUB_RECORD.pids")"
  step="${plan[launch - 1]:-${plan[-1]}}"
  [[ ${step%%:*} == 0 ]] || sleep "${step%%:*}"
  exit "${step#*:}"
fi
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$tmp/qs"
# The stub hyprctl answers the preflight's `-j version` and restart's
# `-j status`, the Lua dialect. `-j monitors` appends a line to
# STUB_HYPR_LOG and answers STUB_MONITORS, or fails as a Hyprland that is
# gone does while STUB_MONITORS is unset. `notify` appends its words to
# STUB_HYPR_LOG and answers ok. `dispatch` appends its request to
# STUB_HYPR_LOG, starts STUB_HYPR_LAUNCH's `run` in a session of its own
# as Hyprland's exec does, appends that runner's pid to
# STUB_HYPR_LOG.launched and answers ok.
cat >"$tmp/hyprctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "-j version") echo '{"version": "0.56.2"}' ;;
  "-j status") echo '{"configProvider": "lua"}' ;;
  "-j monitors")
    echo monitors >>"${STUB_HYPR_LOG:?}"
    [[ -n ${STUB_MONITORS:-} ]] || { echo "HYPRLAND_INSTANCE_SIGNATURE not set"; exit 1; }
    printf '%s\n' "$STUB_MONITORS"
    ;;
  notify*)
    printf '%s\n' "$*" >>"${STUB_HYPR_LOG:?}"
    echo ok
    ;;
  dispatch*)
    printf '%s\n' "$*" >>"${STUB_HYPR_LOG:?}"
    setsid "${STUB_HYPR_LAUNCH:?}" run </dev/null >>"$STUB_HYPR_LOG.runner" 2>&1 &
    printf '%s\n' "$!" >>"$STUB_HYPR_LOG.launched"
    echo ok
    ;;
  *) echo "stub hyprctl: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/hyprctl"
# Hyprland's monitors with the session unlocked, locked, and with no
# monitor past WORKSPACE, which LockModel.sessionLockState reads unknown.
monitors_unlocked='[{"name": "DP-1", "solitaryBlockedBy": ["WINDOWED"]}]'
monitors_locked='[{"name": "DP-1", "solitaryBlockedBy": ["LOCK"]}]'
monitors_unknown='[{"name": "DP-1", "solitaryBlockedBy": ["WORKSPACE"]}]'

# run_bg BIN RT [NAME=VALUE...]: the runner BIN started in the background
# against the runtime directory RT, with INT at its default disposition as
# a terminal's foreground job has it. Sets runner, then shell once the stub
# wrote its record, and returns 1 when it wrote none within 5 s.
run_bg() { # BIN RT [NAME=VALUE...]
  local bin="$1" rt="$2"
  shift 2
  mkdir -p -- "$rt"
  "${base_env[@]:0:2}" --default-signal=INT "${base_env[@]:2}" XDG_RUNTIME_DIR="$rt" STUB_RECORD="$rt/record" STUB_LOCK="$rt/vgsh.lock" STUB_HYPR_LOG="$rt/hyprctl.log" "$@" "$bin" run </dev/null >"$rt/out" 2>&1 &
  runner=$!
  track "$runner"
  shell=""
  # A real wait: the runner starts the shell after its preflight.
  for _ in $(seq 1 50); do
    if [[ -s $rt/record ]]; then
      shell="$(sed -n 's/^pid=\([0-9]*\) .*/\1/p' "$rt/record")"
      track "$shell"
      return 0
    fi
    sleep 0.1
  done
  return 1
}
# Sets status to the runner's exit status once it ended within 5 s, or to
# `running`.
runner_end() {
  for _ in $(seq 1 100); do
    if ! proc_live "$runner"; then
      status=0
      wait "$runner" || status=$?
      return
    fi
    sleep 0.05
  done
  status=running
}
lock_state() { # RT
  if flock -n "$1/vgsh.lock" true; then echo free; else echo held; fi
}
ended() { if proc_live "$1"; then echo running; else echo ended; fi; } # PID
# The status of one more `vgsh run` from BIN in RT whose shell exits at once.
next_run() { # BIN RT
  local status=0
  "${base_env[@]}" XDG_RUNTIME_DIR="$2" STUB_RECORD="$2/record-next" STUB_LOCK="$2/vgsh.lock" STUB_HYPR_LOG="$2/hyprctl-next.log" "$1" run </dev/null >/dev/null 2>&1 || status=$?
  echo "$status"
}
# A runtime directory no other row used. Rows run in command
# substitutions, so no counter in this shell could number them.
new_rt() { rt="$(mktemp -d "$tmp/rt-XXXXXX")" || { echo "test-vgsh-run: scratch=mktemp-failed" >&2; exit 1; }; }

# Who the lock file and VGSH_RUNNER_PID name, the shell's parent, the
# shell's descriptors on the lock and the lock's state while it runs.
identity() { # BIN
  local record lock_pid runner_env parent fds held
  new_rt
  run_bg "$1" "$rt" STUB_SHELL_HOLD=20 || { echo "no-shell"; return; }
  record="$(<"$rt/record")"
  lock_pid="$(<"$rt/vgsh.lock")"
  runner_env="${record#*runner=}"; runner_env="${runner_env%% *}"
  parent="${record#*parent=}"; parent="${parent%% *}"
  fds="${record#*lockfds=}"
  held="$(lock_state "$rt")"
  kill -KILL "$shell" "$runner" 2>/dev/null || true
  wait "$runner" 2>/dev/null || true
  printf 'lock=%s env=%s parent=%s lockfds=%s lock=%s\n' \
    "$([[ $lock_pid == "$shell" ]] && echo shell || echo "other:$lock_pid")" \
    "$([[ $runner_env == "$shell" ]] && echo shell || echo "other:$runner_env")" \
    "$([[ $parent == "$runner" ]] && echo runner || echo "other:$parent")" "$fds" "$held"
}
# SIGNAL to the runner of a shell that exits at once on TERM: the runner's
# status and the shell's state once the runner ended.
signalled() { # BIN SIGNAL
  local status
  new_rt
  run_bg "$1" "$rt" STUB_SHELL_HOLD=20 || { echo "no-shell"; return; }
  kill -s "$2" "$runner"
  runner_end
  printf 'status=%s shell=%s lock=%s\n' "$status" "$(ended "$shell")" "$(lock_state "$rt")"
}
# TERM to the runner of a shell that takes 0.3 s to exit on TERM, with
# status 7: the runner's status and the shell's state when it ended.
slow_stop() { # BIN
  local status
  new_rt
  run_bg "$1" "$rt" STUB_TERM_EXIT=7 || { echo "no-shell"; return; }
  kill -TERM "$runner"
  runner_end
  printf 'status=%s shell=%s\n' "$status" "$(ended "$shell")"
}
# A shell that leaves a process behind and ends, on its own with status 3
# (`exit`) or killed with SIGKILL (`crash`): the runner's status, the
# lock's state and the process's state after the runner ended, and the
# status of the next run while that process still runs.
left_behind() { # BIN exit|crash
  local status child="" gate next
  new_rt
  gate="$rt/child.gate"
  if [[ $2 == exit ]]; then
    run_bg "$1" "$rt" STUB_CHILD_GATE="$gate" STUB_EXIT=3 || { echo "no-shell"; return; }
  else
    run_bg "$1" "$rt" STUB_CHILD_GATE="$gate" STUB_SHELL_HOLD=20 || { echo "no-shell"; return; }
  fi
  for _ in $(seq 1 50); do [[ -s $gate.pid ]] && break; sleep 0.1; done
  [[ -s $gate.pid ]] && child="$(<"$gate.pid")"
  [[ -n $child ]] || { echo "no-child"; return; }
  track "$child"
  [[ $2 == crash ]] && kill -KILL "$shell"
  runner_end
  printf 'status=%s lock=%s child=%s' "$status" "$(lock_state "$rt")" "$(ended "$child")"
  next="$(next_run "$1" "$rt")"
  printf ' next=%s child=%s\n' "$next" "$(ended "$child")"
  : >"$gate"
}
# SIGKILL to the runner: the shell's state within 5 s and the lock's.
runner_killed() { # BIN
  new_rt
  run_bg "$1" "$rt" STUB_SHELL_HOLD=20 || { echo "no-shell"; return; }
  kill -KILL "$runner"
  wait "$runner" 2>/dev/null || true
  for _ in $(seq 1 100); do proc_live "$shell" || break; sleep 0.05; done
  printf 'shell=%s lock=%s\n' "$(ended "$shell")" "$(lock_state "$rt")"
  kill -KILL "$shell" 2>/dev/null || true
}

# The supervision rows. launches RT: how many shells the runner in RT
# started. runner_lines RT KEY: its `vgsh: shell=KEY ...` stderr lines,
# joined by `;`. notices RT: the notify calls it made, each cut to its
# first four words, the icon, the time and the colour, joined by `;`.
launches() { if [[ -r $1/record.pids ]]; then wc -l <"$1/record.pids"; else echo 0; fi; } # RT
runner_lines() { grep -E "^vgsh: shell=$2 " -- "$1/out" | paste -sd';' || :; } # RT KEY
notices() { grep -E '^notify ' -- "$1/hyprctl.log" | cut -d' ' -f1-4 | paste -sd';' || :; } # RT
# Ends the runner a row left running, and its shell.
stop_runner() { kill -KILL "$runner" 2>/dev/null || :; wait "$runner" 2>/dev/null || :; }
# SIGKILL to the shell while Hyprland answers with the session unlocked:
# whether the same runner started a new shell within 5 s, who the lock
# file and VGSH_RUNNER_PID name then and whose child the new shell is,
# whether a lock probe every 20 ms from the kill until the new shell ran
# ever found the lock free, and the runner's relaunch line.
relaunched() { # BIN
  local first new="" record lock_pid runner_env parent prober probes
  new_rt
  run_bg "$1" "$rt" STUB_SHELL_HOLD=20 STUB_MONITORS="$monitors_unlocked" || { echo "no-shell"; return; }
  first="$shell"
  ( while [[ ! -e $rt/probes.stop ]]; do lock_state "$rt" >>"$rt/probes"; sleep 0.02; done ) &
  prober=$!
  kill -KILL "$first"
  # A real wait: the relaunch comes after the table's first delay.
  for _ in $(seq 1 100); do
    new="$(tail -n 1 -- "$rt/record.pids")"
    if [[ $new != "$first" ]] && grep -q "^pid=$new " -- "$rt/record" 2>/dev/null; then break; fi
    new=""
    sleep 0.05
  done
  : >"$rt/probes.stop"
  wait "$prober"
  probes="$(sort -u -- "$rt/probes" | paste -sd,)"
  if [[ -z $new ]]; then printf 'new=none probes=%s\n' "$probes"; stop_runner; return; fi
  track "$new"
  record="$(<"$rt/record")"
  lock_pid="$(<"$rt/vgsh.lock")"
  runner_env="${record#*runner=}"; runner_env="${runner_env%% *}"
  parent="${record#*parent=}"; parent="${parent%% *}"
  printf 'new=yes lock=%s env=%s parent=%s probes=%s line=[%s]\n' \
    "$([[ $lock_pid == "$new" ]] && echo shell || echo "other:$lock_pid")" \
    "$([[ $runner_env == "$new" ]] && echo shell || echo "other:$runner_env")" \
    "$([[ $parent == "$runner" ]] && echo runner || echo "other:$parent")" "$probes" "$(runner_lines "$rt" exited)"
  stop_runner
}
# A shell that exits 0 while Hyprland answers: the runner's status and
# how many shells it started.
clean_exit() { # BIN
  local status
  new_rt
  run_bg "$1" "$rt" STUB_PLAN=0:0 STUB_MONITORS="$monitors_unlocked" || { echo "no-shell"; return; }
  runner_end
  printf 'status=%s launches=%s\n' "$status" "$(launches "$rt")"
  stop_runner
}
# TERM to the runner while Hyprland answers: the runner's status, how many
# shells it started and the lock's state.
stopped() { # BIN
  local status
  new_rt
  run_bg "$1" "$rt" STUB_SHELL_HOLD=20 STUB_MONITORS="$monitors_unlocked" || { echo "no-shell"; return; }
  kill -TERM "$runner"
  runner_end
  printf 'status=%s launches=%s lock=%s\n' "$status" "$(launches "$rt")" "$(lock_state "$rt")"
  stop_runner
}
# TERM to the runner once it waits to relaunch a shell that exited 3:
# its status, whether it ended within 2 s of the TERM, the shells it
# started and the lock's state. The row runs a copy whose delays are 5 s,
# so a wait the TERM does not end outlasts the bound.
backoff_stopped() { # BIN
  local status sent_us took_ms
  new_rt
  run_bg "$1" "$rt" STUB_PLAN=0:3 STUB_MONITORS="$monitors_unlocked" || { echo "no-shell"; return; }
  for _ in $(seq 1 100); do [[ -n $(runner_lines "$rt" exited) ]] && break; sleep 0.05; done
  [[ -n $(runner_lines "$rt" exited) ]] || { echo "no-relaunch-line"; stop_runner; return; }
  sent_us="${EPOCHREALTIME//[!0-9]/}"
  kill -TERM "$runner"
  runner_end
  took_ms=$(( (${EPOCHREALTIME//[!0-9]/} - sent_us) / 1000 ))
  printf 'status=%s prompt=%s launches=%s lock=%s\n' "$status" "$( ((took_ms < 2000)) && echo yes || echo "no:${took_ms}ms")" "$(launches "$rt")" "$(lock_state "$rt")"
  stop_runner
}
# Shells that exit 3 at once while Hyprland answers MONITORS, the session
# unlocked: the runner's status, the shells it started, its relaunch and
# give-up lines and the notices it asked for. The row runs a copy whose
# delays are 0.1 s.
gave_up() { # BIN
  local status
  new_rt
  run_bg "$1" "$rt" STUB_PLAN=0:3 STUB_MONITORS="$monitors_unlocked" || { echo "no-shell"; return; }
  runner_end
  printf 'status=%s launches=%s relaunches=%s gave_up=[%s] notices=[%s] text=%s\n' "$status" "$(launches "$rt")" \
    "$(grep -c -E '^vgsh: shell=exited .* relaunch=' -- "$rt/out" || :)" "$(runner_lines "$rt" gave-up)" "$(notices "$rt")" \
    "$(grep -q -E '^notify 3 [0-9]+ 0 [^ ]' -- "$rt/hyprctl.log" && echo yes || echo none)"
  stop_runner
}
# The same with Hyprland's monitors naming the session `locked`, or
# `unknown` when no monitor is readable: whether the runner started eight
# shells within 5 s and still runs, the notices it asked for and its
# seventh relaunch line. The row runs a copy whose delays are 0.1 s.
kept_on() { # BIN locked|unknown
  local n=0 monitors
  case "$2" in
    locked) monitors="$monitors_locked" ;;
    unknown) monitors="$monitors_unknown" ;;
    *) echo "kept_on: refused: session=$2"; return ;;
  esac
  new_rt
  run_bg "$1" "$rt" STUB_PLAN=0:3 STUB_MONITORS="$monitors" || { echo "no-shell"; return; }
  for _ in $(seq 1 100); do n="$(launches "$rt")"; ((n >= 8)) && break; sleep 0.05; done
  printf 'launches=%s runner=%s notices=[%s] seventh=[%s]\n' "$( ((n >= 8)) && echo 8+ || echo "$n")" "$(ended "$runner")" \
    "$(notices "$rt")" "$(grep -E '^vgsh: shell=exited ' -- "$rt/out" | sed -n 7p || :)"
  stop_runner
}
# Three quick exits, a run of 2 s and quick exits after it, while Hyprland
# answers with the session unlocked: the runner's status, the shells it
# started and its give-up line. The row runs a copy whose delays are 0.1 s
# and whose healthy run is 1 s, so the long run starts a new streak.
healthy_reset() { # BIN
  local status
  new_rt
  run_bg "$1" "$rt" STUB_PLAN="0:3 0:3 0:3 2:3 0:3" STUB_MONITORS="$monitors_unlocked" || { echo "no-shell"; return; }
  runner_end
  printf 'status=%s launches=%s gave_up=[%s]\n' "$status" "$(launches "$rt")" "$(runner_lines "$rt" gave-up)"
  stop_runner
}
# A shell that exits 3 while Hyprland does not answer: the runner's
# status, the shells it started, how many times it asked for the monitors
# and its line.
compositor_gone() { # BIN
  local status
  new_rt
  run_bg "$1" "$rt" STUB_PLAN=0:3 || { echo "no-shell"; return; }
  runner_end
  printf 'status=%s launches=%s monitor_calls=%s line=[%s]\n' "$status" "$(launches "$rt")" \
    "$(grep -c -x monitors -- "$rt/hyprctl.log" || :)" "$(runner_lines "$rt" exited)"
  stop_runner
}
# `vgsh restart` from BIN, while Hyprland answers with the session
# unlocked, so a runner whose shell ends with no stop signal starts it
# again. PARENT `runner`: the shell is a runner's child. `inherited`: the
# pid the lock file names holds the lock itself, as under a runner that
# execed qs in place, and its parent holds none. The verdict: restart's
# status and first stderr line, whether the old shell and its parent
# ended, and whether the new shell's parent is the runner Hyprland's
# dispatch started.
restarted() { # BIN runner|inherited
  local old parent status=0 out err="" new launched="" new_parent
  new_rt
  if [[ $2 == runner ]]; then
    run_bg "$repo/bin/vgsh" "$rt" STUB_SHELL_HOLD=20 STUB_MONITORS="$monitors_unlocked" || { echo "no-shell"; return; }
    old="$shell" parent="$runner"
  else
    "${base_env[@]}" bash -c 'bash -c '\''exec 9>>"$1"; flock 9; printf "%s\n" "$$" >"$1"; exec sleep 20'\'' _ "$1" & wait; exec sleep 20' _ "$rt/vgsh.lock" </dev/null >/dev/null 2>&1 &
    parent=$!
    track "$parent"
    old=""
    for _ in $(seq 1 50); do [[ -s $rt/vgsh.lock ]] && old="$(<"$rt/vgsh.lock")" && break; sleep 0.1; done
    [[ -n $old ]] || { echo "no-holder"; return; }
    track "$old"
  fi
  out="$("${base_env[@]}" XDG_RUNTIME_DIR="$rt" STUB_RECORD="$rt/record" STUB_LOCK="$rt/vgsh.lock" STUB_HYPR_LOG="$rt/hyprctl.log" \
    STUB_HYPR_LAUNCH="$repo/bin/vgsh" STUB_SHELL_HOLD=20 STUB_MONITORS="$monitors_unlocked" "$1" restart 2>"$rt/restart.err" </dev/null)" || status=$?
  if [[ -r $rt/hyprctl.log.launched ]]; then launched="$(<"$rt/hyprctl.log.launched")"; track $launched; fi
  [[ -s $rt/restart.err ]] && IFS= read -r err <"$rt/restart.err"
  new_parent=none
  if [[ $out =~ ^ok\ pid=([0-9]+)$ ]]; then
    new="${BASH_REMATCH[1]}"
    track "$new"
    new_parent="$(awk '$1 == "PPid:" { print $2 }' "/proc/$new/status" 2>/dev/null)" || new_parent=unreadable
    [[ -n $launched && $new_parent == "$launched" ]] && new_parent=dispatched
  fi
  printf 'restart=%s err=[%s] old=%s parent=%s new_parent=%s\n' "$status" "$err" "$(ended "$old")" "$(ended "$parent")" "$new_parent"
  [[ $2 == runner ]] && stop_runner
  return 0
}

# Copies of bin/vgsh the supervision rows run, each a tree with bin/lib and
# shell/ linked, since the runner judges the session lock through
# bin/lib/qml-library.js and vgs.lock's LockModel.js: a `fast` table
# whose delays are 0.1 s, a `slow` one whose delays are 5 s and a
# `healthy` one whose delays are 0.1 s and whose healthy run is 1 s.
# tree_with NAME FILE NEEDLE REPLACEMENT: copy_with's copy of FILE moved
# into such a tree; copy names its bin/vgsh.
tree_with() {
  local tree="$tmp/trees/$1"
  copy_with "$1" "$2" "$3" "$4"
  mkdir -p -- "$tree/bin"
  mv -- "$copy" "$tree/bin/vgsh"
  chmod +x "$tree/bin/vgsh"
  ln -s -- "$repo/bin/lib" "$tree/bin/lib"
  ln -s -- "$repo/shell" "$tree/shell"
  copy="$tree/bin/vgsh"
}
delays_needle='supervise_delays=(0.5 1 2 4 8)'
tree_with fast "$repo/bin/vgsh" "$delays_needle" 'supervise_delays=(0.1 0.1 0.1 0.1 0.1)'; fast="$copy"
tree_with slow "$repo/bin/vgsh" "$delays_needle" 'supervise_delays=(5 5 5 5 5)'; slow="$copy"
tree_with healthy "$fast" 'supervise_healthy_ms=60000' 'supervise_healthy_ms=1000'; healthy="$copy"
# The restart controls run on a copy that waits 1 s for the lock, not 10 s:
# each control's restart ends on that wait.
tree_with restart-wait "$repo/bin/vgsh" 'flock -w 10 "$lock" true' 'flock -w 1 "$lock" true'; restart_wait="$copy"

gave_up_want="status=3 launches=6 relaunches=5 gave_up=[vgsh: shell=gave-up exits=6 status=3] notices=[notify 3 600000 0] text=yes"
# rows: name | verdict function and its arguments after BIN | the verdict | BIN
rows=(
  "the lock file and VGSH_RUNNER_PID name the shell, the runner's child, which holds no descriptor on the held lock|identity|lock=shell env=shell parent=runner lockfds=0 lock=held|$repo/bin/vgsh"
  "TERM to the runner stops the shell and the runner exits with its status|signalled TERM|status=143 shell=ended lock=free|$repo/bin/vgsh"
  "INT to the runner reaches the shell as TERM|signalled INT|status=143 shell=ended lock=free|$repo/bin/vgsh"
  "a runner whose wait a TERM interrupts waits on until the shell ended and exits with its status|slow_stop|status=7 shell=ended|$repo/bin/vgsh"
  "a process the shell leaves behind holds no lock, and the next run starts while it runs|left_behind exit|status=3 lock=free child=running next=0 child=running|$repo/bin/vgsh"
  "after a shell crash with Hyprland gone and a live child the lock is free and the next run starts|left_behind crash|status=137 lock=free child=running next=0 child=running|$repo/bin/vgsh"
  "a runner killed with SIGKILL takes the shell with it|runner_killed|shell=ended lock=free|$repo/bin/vgsh"
  "a killed shell is started again by the same runner, which holds the lock throughout and hands the new shell its pid|relaunched|new=yes lock=shell env=shell parent=runner probes=held line=[vgsh: shell=exited status=137 relaunch=1 delay=0.5 session=unlocked]|$repo/bin/vgsh"
  "a shell that exits 0 is not started again|clean_exit|status=0 launches=1|$repo/bin/vgsh"
  "TERM to the runner stops the shell and starts none again|stopped|status=143 launches=1 lock=free|$repo/bin/vgsh"
  "TERM while the runner waits to relaunch ends it at once|backoff_stopped|status=3 prompt=yes launches=1 lock=free|$slow"
  "after the last relaunch of a streak the runner gives up with the shell's status and one error notice|gave_up|$gave_up_want|$fast"
  "while the session is locked the runner never gives up and waits the last delay|kept_on locked|launches=8+ runner=running notices=[] seventh=[vgsh: shell=exited status=3 relaunch=7 delay=0.1 session=locked]|$fast"
  "while the session lock is unreadable the runner never gives up|kept_on unknown|launches=8+ runner=running notices=[] seventh=[vgsh: shell=exited status=3 relaunch=7 delay=0.1 session=unknown]|$fast"
  "a run as long as the healthy run starts a new streak|healthy_reset|status=3 launches=9 gave_up=[vgsh: shell=gave-up exits=6 status=3]|$healthy"
  "a Hyprland that does not answer three tries ends the runner with no relaunch|compositor_gone|status=3 launches=1 monitor_calls=3 line=[vgsh: shell=exited status=3 hyprland=gone]|$repo/bin/vgsh"
  "restart stops the runner, which starts no shell again, and the dispatched runner starts the new shell|restarted runner|restart=0 err=[] old=ended parent=ended new_parent=dispatched|$repo/bin/vgsh"
  "restart stops a shell whose parent holds no lock by its own pid|restarted inherited|restart=0 err=[] old=ended parent=running new_parent=dispatched|$repo/bin/vgsh"
)
verdict_of() { # BIN ROW_FUNCTION_WORDS
  local -a words
  IFS=' ' read -ra words <<<"$2"
  "${words[0]}" "$1" "${words[@]:1}"
}
row_want() { local row="$1" name fn want bin; IFS='|' read -r name fn want bin <<<"$row"; printf '%s\n' "$want"; }
for row in "${rows[@]}"; do
  IFS='|' read -r name fn want bin <<<"$row"
  got="$(verdict_of "$bin" "$fn")"
  if [[ $got == "$want" ]]; then ok "$name"; else fail "$name: got [$got] want [$want]"; fi
done

# Controls: one copy per rule of bin/vgsh, or of the supervision copy the
# rule's row runs, each with NEEDLE replaced once; the row the rule decides
# must not hold on the copy. tree_with links bin/lib beside each copy, the
# library bin/vgsh loads at start, and each control first proves its copy
# loads.
# control NAME NEEDLE REPLACEMENT ROW_FUNCTION_WORDS WANT [SOURCE]
control() {
  local got
  tree_with "$1" "${6:-$repo/bin/vgsh}" "$2" "$3"
  if ! vgsh_copy_loads "$copy"; then fail "control $1: the copy does not load"; return; fi
  got="$(verdict_of "$copy" "$4")"
  if [[ $got != "$5" ]]; then ok "control $1: $got"; else fail "control $1 still holds: $got"; fi
}
control pid-from-runner "printf '%s\\n' \"\$BASHPID\" >&9" "printf '%s\\n' \"\$\$\" >&9" \
  identity "lock=shell env=shell parent=runner lockfds=0 lock=held"
control inherited-lock '    exec 9>&-' '    :' \
  identity "lock=shell env=shell parent=runner lockfds=0 lock=held"
control inherited-lock-left-behind '    exec 9>&-' '    :' \
  "left_behind exit" "status=3 lock=free child=running next=0 child=running"
control inherited-lock-crash '    exec 9>&-' '    :' \
  "left_behind crash" "status=137 lock=free child=running next=0 child=running"
control no-forward '[[ -z $shell_child ]] || kill -TERM "$shell_child"' '[[ -z $shell_child ]] || kill -0 "$shell_child"' \
  "signalled TERM" "status=143 shell=ended lock=free"
control int-not-trapped "2>/dev/null || :' HUP INT TERM" "2>/dev/null || :' HUP TERM" \
  "signalled INT" "status=143 shell=ended lock=free"
control no-wait-loop '[[ -n $forwarded ]] || break' 'break' \
  slow_stop "status=7 shell=ended"
control status-dropped 'exit "$shell_status"' 'exit 0' \
  "left_behind exit" "status=3 lock=free child=running next=0 child=running"
control no-parent-death-signal '--pdeathsig TERM' '--pdeathsig clear' \
  runner_killed "shell=ended lock=free"
control no-relaunch 'if ! monitors="$(compositor_monitors)"; then' 'if ! monitors="$(false)"; then' \
  relaunched "$(row_want "${rows[7]}")"
control relaunch-after-clean-exit '[[ -z $stop && $shell_status != 0 ]] || break' '[[ -z $stop ]] || break' \
  clean_exit "status=0 launches=1"
control stop-not-marked "trap 'stop=1; forwarded=1;" "trap 'forwarded=1;" \
  stopped "status=143 launches=1 lock=free"
control backoff-not-interrupted 'sleep "$delay" 9>&- &' 'sleep "$delay" 9>&-; : &' \
  backoff_stopped "status=3 prompt=yes launches=1 lock=free" "$slow"
control limit-unreachable 'if ((streak > ${#supervise_delays[@]})) && [[ $session == unlocked ]]; then' \
  'if ((streak > 1000)) && [[ $session == unlocked ]]; then' gave_up "$gave_up_want" "$fast"
control lock-ignored '[[ $session == unlocked ]]; then' '[[ -n $session ]]; then' \
  "kept_on locked" "$(row_want "${rows[12]}")" "$fast"
control no-healthy-reset '((ran_ms < supervise_healthy_ms)) || streak=0' '((ran_ms < supervise_healthy_ms)) || :' \
  healthy_reset "status=3 launches=9 gave_up=[vgsh: shell=gave-up exits=6 status=3]" "$healthy"
control relaunch-without-hyprland 'if ! monitors="$(compositor_monitors)"; then' "if ! monitors=\"\$(compositor_monitors || echo '[]')\"; then" \
  compositor_gone "$(row_want "${rows[15]}")"
control one-compositor-try 'supervise_compositor_tries=3' 'supervise_compositor_tries=1' \
  compositor_gone "$(row_want "${rows[15]}")"
control restart-stops-the-shell 'target="$parent"' 'target="$1"' \
  "restarted runner" "$(row_want "${rows[16]}")" "$restart_wait"
control restart-parent-unproven 'held="$(readlink -- "/proc/$parent/fd/9" 2>/dev/null)"' 'held="$(readlink -f -- "$lock")"' \
  "restarted inherited" "$(row_want "${rows[17]}")" "$restart_wait"

rows_done test-vgsh-run
