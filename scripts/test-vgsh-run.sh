#!/usr/bin/env bash
# Controls for the lifetime of `vgsh run`, the runner: it holds the
# instance lock, starts the shell as its child and waits on it
# (docs/decisions/D053-runner-holds-the-instance-lock.md). Each row runs
# the runner against a stub qs in a runtime directory of its own and reads
# a verdict line whose words the rows pin: who the lock file and
# VGSH_RUNNER_PID name, whether the shell or a process it leaves behind
# holds the lock, the runner's exit status and which process outlives
# which. Each rule has a must-fail control on a copy of bin/vgsh.
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

# The stub qs answers the preflight's `--version`. Run as the shell, it
# writes `pid= runner= parent= lockfds=` to STUB_RECORD: its pid,
# VGSH_RUNNER_PID, its parent's pid and how many of its descriptors are
# open on STUB_LOCK. With STUB_CHILD_GATE it then starts a process that
# runs until that file exists, 20 s at most, writing its pid beside the
# gate as GATE.pid; the process inherits every descriptor the stub has.
# STUB_TERM_EXIT makes it answer TERM by exiting with that status 0.3 s
# later; STUB_SHELL_HOLD makes it sleep that long; otherwise it exits
# STUB_EXIT.
cat >"$tmp/qs" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then echo "Quickshell 0.3.1"; exit 0; fi
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
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$tmp/qs"
# The preflight's `hyprctl -j version`.
cat >"$tmp/hyprctl" <<'EOF'
#!/usr/bin/env bash
echo '{"version": "0.56.2"}'
EOF
chmod +x "$tmp/hyprctl"

# run_bg BIN RT [NAME=VALUE...]: the runner BIN started in the background
# against the runtime directory RT, with INT at its default disposition as
# a terminal's foreground job has it. Sets runner, then shell once the stub
# wrote its record, and returns 1 when it wrote none within 5 s.
run_bg() { # BIN RT [NAME=VALUE...]
  local bin="$1" rt="$2"
  shift 2
  mkdir -p -- "$rt"
  "${base_env[@]:0:2}" --default-signal=INT "${base_env[@]:2}" XDG_RUNTIME_DIR="$rt" STUB_RECORD="$rt/record" STUB_LOCK="$rt/vgsh.lock" "$@" "$bin" run </dev/null >"$rt/out" 2>&1 &
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
  "${base_env[@]}" XDG_RUNTIME_DIR="$2" STUB_RECORD="$2/record-next" STUB_LOCK="$2/vgsh.lock" "$1" run </dev/null >/dev/null 2>&1 || status=$?
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

# rows: name | verdict function and its arguments after BIN | the verdict
rows=(
  "the lock file and VGSH_RUNNER_PID name the shell, the runner's child, which holds no descriptor on the held lock|identity|lock=shell env=shell parent=runner lockfds=0 lock=held"
  "TERM to the runner stops the shell and the runner exits with its status|signalled TERM|status=143 shell=ended lock=free"
  "INT to the runner reaches the shell as TERM|signalled INT|status=143 shell=ended lock=free"
  "a runner whose wait a TERM interrupts waits on until the shell ended and exits with its status|slow_stop|status=7 shell=ended"
  "a process the shell leaves behind holds no lock, and the next run starts while it runs|left_behind exit|status=3 lock=free child=running next=0 child=running"
  "after a shell crash with a live child the lock is free and the next run starts|left_behind crash|status=137 lock=free child=running next=0 child=running"
  "a runner killed with SIGKILL takes the shell with it|runner_killed|shell=ended lock=free"
)
verdict_of() { # BIN ROW_FUNCTION_WORDS
  local -a words
  read -ra words <<<"$2"
  "${words[0]}" "$1" "${words[@]:1}"
}
for row in "${rows[@]}"; do
  IFS='|' read -r name fn want <<<"$row"
  got="$(verdict_of "$repo/bin/vgsh" "$fn")"
  if [[ $got == "$want" ]]; then ok "$name"; else fail "$name: got [$got] want [$want]"; fi
done

# Controls: one copy of bin/vgsh per rule, each with NEEDLE replaced once;
# the row the rule decides must not hold on the copy.
# control NAME NEEDLE REPLACEMENT ROW_FUNCTION_WORDS WANT
control() {
  local got
  copy_with "$1" "$repo/bin/vgsh" "$2" "$3"
  chmod +x "$copy"
  got="$(verdict_of "$copy" "$4")"
  if [[ $got != "$5" ]]; then ok "control $1: $got"; else fail "control $1 still holds: $got"; fi
}
control pid-from-runner "printf '%s\\n' \"\$BASHPID\" >&9" "printf '%s\\n' \"\$\$\" >&9" \
  identity "lock=shell env=shell parent=runner lockfds=0 lock=held"
control inherited-lock '      exec 9>&-' '      :' \
  identity "lock=shell env=shell parent=runner lockfds=0 lock=held"
control inherited-lock-left-behind '      exec 9>&-' '      :' \
  "left_behind exit" "status=3 lock=free child=running next=0 child=running"
control inherited-lock-crash '      exec 9>&-' '      :' \
  "left_behind crash" "status=137 lock=free child=running next=0 child=running"
control no-forward 'kill -TERM "$shell_child"' 'kill -0 "$shell_child"' \
  "signalled TERM" "status=143 shell=ended lock=free"
control int-not-trapped "2>/dev/null || :' HUP INT TERM" "2>/dev/null || :' HUP TERM" \
  "signalled INT" "status=143 shell=ended lock=free"
control no-wait-loop '[[ -n $forwarded ]] || break' 'break' \
  slow_stop "status=7 shell=ended"
control status-dropped 'exit "$shell_status"' 'exit 0' \
  "left_behind exit" "status=3 lock=free child=running next=0 child=running"
control no-parent-death-signal '--pdeathsig TERM' '--pdeathsig clear' \
  runner_killed "shell=ended lock=free"

rows_done test-vgsh-run
