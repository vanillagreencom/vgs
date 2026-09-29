#!/usr/bin/env bash
# Controls for bin/vgsh against a stub qs on PATH. Each row pins a reply,
# an exit status or a keyed refusal the header promises. `run` execs the
# stub, which records the identity and environment it was handed.
set -euo pipefail

# One row removes a directory's permission bits, which bind only a non-root
# uid; a run that could not measure it is not a pass.
if [[ $(id -u) == 0 ]]; then
  echo "test-vgsh: status=not-measured reason=euid-0"
  exit 77
fi
# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

started_pids=()
cleanup_started_pids() {
  local pid
  for pid in "${started_pids[@]}"; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_started_pids; rm -rf -- "${tmp:?}"' EXIT

# The stub answers `qs ipc ... call <target> <fn> ...` from STUB_REPLY and
# STUB_STATUS, prints STUB_NOISE on stdout before the reply (as qs does with
# its log) and STUB_STDERR on stderr after it. `qs --version` prints
# STUB_QS_STDERR on stderr, then STUB_QS_VERSION, and exits
# STUB_QS_VERSION_EXIT. Invoked as the shell (no
# `ipc` argument) it records its pid, VGSH_RUNNER_PID, the file-watcher
# environment and its arguments in STUB_RECORD. STUB_SHELL_HOLD keeps that
# process and the inherited instance lock alive for restart rows.
cat >"$tmp/qs" <<'EOF2'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then
  [[ -n ${STUB_QS_STDERR:-} ]] && printf '%s\n' "$STUB_QS_STDERR" >&2
  printf '%s\n' "${STUB_QS_VERSION-Quickshell 0.3.1 (revision stub, distributed by test-vgsh)}"
  exit "${STUB_QS_VERSION_EXIT:-0}"
fi
if [[ ${1:-} != ipc && ${1:-} != log ]]; then
  printf 'pid=%s runner=%s disable=%s no_popup=%s args=%s\n' "$$" "${VGSH_RUNNER_PID:-unset}" "${QS_DISABLE_FILE_WATCHER:-unset}" "${QS_NO_RELOAD_POPUP:-unset}" "$*" >"${STUB_RECORD:?}"
  [[ -n ${STUB_SHELL_HOLD:-} ]] && exec sleep "$STUB_SHELL_HOLD"
  exit 0
fi
printf '%s\n' "$*" >"${STUB_ARGS:-/dev/null}"
[[ -n ${STUB_NOISE:-} ]] && printf '%s\n' "$STUB_NOISE"
reply="${STUB_REPLY:-ok}"
if [[ ${4:-} == call && ${5:-} == shell && ${6:-} == guarded ]]; then
  reply="${STUB_GUARDED:-true}"
  if [[ -n ${STUB_GUARDED_FALSE_CALLS:-} ]]; then
    count=0
    [[ -r ${STUB_GUARDED_COUNT:?} ]] && IFS= read -r count <"$STUB_GUARDED_COUNT"
    count=$((count + 1))
    printf '%s\n' "$count" >"$STUB_GUARDED_COUNT"
    if (( count <= STUB_GUARDED_FALSE_CALLS )); then
      reply=false
    else
      reply=true
    fi
  fi
fi
printf '%s\n' "$reply"
[[ -n ${STUB_STDERR:-} ]] && printf '%s\n' "$STUB_STDERR" >&2
exit "${STUB_STATUS:-0}"
EOF2
chmod +x "$tmp/qs"

cat >"$tmp/hyprctl" <<'EOF2'
#!/usr/bin/env bash
if [[ ${1:-} == -j && ${2:-} == version ]]; then
  printf '{\n    "branch": "stub",\n    "version": "%s",\n    "dirty": false\n}\n' "${STUB_HYPR_VERSION:-0.56.2}"
  exit "${STUB_HYPR_VERSION_EXIT:-0}"
fi
if [[ ${1:-} == -j && ${2:-} == status ]]; then
  status='{"configProvider":"lua"}'
  printf '%s\n' "${STUB_HYPR_STATUS:-$status}"
  exit "${STUB_HYPR_STATUS_EXIT:-0}"
fi
if [[ ${1:-} == dispatch ]]; then
  printf '%s\n' "${2:-}" >>"${STUB_HYPR_DISPATCH:?}"
  reply="${STUB_HYPR_REPLY:-ok}"
  printf '%s\n' "$reply"
  if [[ $reply == ok ]]; then
    setsid "${STUB_HYPR_LAUNCH:?}" run </dev/null >/dev/null 2>&1 &
  fi
  exit 0
fi
printf 'unexpected hyprctl args: %s\n' "$*" >&2
exit 1
EOF2
chmod +x "$tmp/hyprctl"

# Every row runs with this environment and nothing else. The runtime dir
# holds the lock file; `live` names a lock file recording this process,
# which is alive, so the CLI addresses it.
rt_live="$tmp/rt-live"; mkdir -p "$rt_live"; printf '%s\n' "$$" >"$rt_live/vgsh.lock"

# rows: name | runtime dir | env | args | want stdout (last line) | want exit | want stderr (first line)
# A refusal row pins its keyed first line; a success row pins an empty stderr.
run_row() { # NAME RT ENVSTR ARGS WANT_OUT WANT_EXIT WANT_ERR
  local name="$1" rt="$2" envstr="$3" args="$4" want_out="$5" want_exit="$6" want_err="$7" out status err=""
  set +e
  # shellcheck disable=SC2086
  out="$("${base_env[@]}" XDG_RUNTIME_DIR="$rt" $envstr "$repo/bin/vgsh" $args 2>"$tmp/err")"
  status=$?
  set -e
  [[ -s $tmp/err ]] && IFS= read -r err <"$tmp/err"
  local last="${out##*$'\n'}"
  if [[ $status == "$want_exit" && $last == "$want_out" && $err == "$want_err" ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit last=[$last] want=[$want_out] stderr=[$err] want=[$want_err]"; fi
}

run_has_file_watcher_env() { # RECORD
  local record="$1" disable no_popup
  disable="${record#*disable=}"
  disable="${disable%% *}"
  no_popup="${record#*no_popup=}"
  no_popup="${no_popup%% *}"
  [[ $disable == 1 && $no_popup == 1 ]]
}

record_runner() { # RECORD
  local record="$1" runner
  runner="${record#*runner=}"
  printf '%s\n' "${runner%% *}"
}

lock_live_pid() { # RUNTIME_DIR
  local pid
  [[ -r $1/vgsh.lock ]] || return 1
  IFS= read -r pid <"$1/vgsh.lock" || return 1
  [[ $pid =~ ^[0-9]+$ && -d /proc/$pid ]] || return 1
  printf '%s\n' "$pid"
}

wait_lock_pid() { # RUNTIME_DIR [OLD_PID]
  local rt="$1" old="${2:-}" pid
  for _ in $(seq 1 100); do
    if pid="$(lock_live_pid "$rt")" && [[ -z $old || $pid != "$old" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

start_fake_shell() { # NAME RUNTIME_DIR RECORD
  local name="$1" rt="$2" record="$3" pid lock_pid
  mkdir -p -- "$rt"
  "${base_env[@]}" XDG_RUNTIME_DIR="$rt" STUB_RECORD="$record" STUB_SHELL_HOLD=60 "$repo/bin/vgsh" run &
  pid=$!
  fake_pid="$pid"
  started_pids+=("$pid")
  if lock_pid="$(wait_lock_pid "$rt")" && [[ $lock_pid == "$pid" ]]; then
    ok "$name"
  else
    fail "$name: pid=$pid lock=${lock_pid:-unreadable}"
  fi
}

run_restart_capture() { # RUNTIME_DIR RECORD DISPATCH REPLY [ENV...]
  local rt="$1" record="$2" dispatch="$3" reply="$4" bin="${RESTART_BIN:-$repo/bin/vgsh}"
  shift 4
  set +e
  restart_out="$("${base_env[@]}" XDG_RUNTIME_DIR="$rt" STUB_RECORD="$record" STUB_SHELL_HOLD=60 STUB_HYPR_DISPATCH="$dispatch" STUB_HYPR_LAUNCH="$repo/bin/vgsh" STUB_REPLY="$reply" "$@" "$bin" restart 2>"$tmp/err")"
  restart_status=$?
  set -e
  restart_err=""
  [[ -s $tmp/err ]] && IFS= read -r restart_err <"$tmp/err"
  return 0
}

dead_pid="$(( $(cat /proc/sys/kernel/pid_max) + 1 ))"

run_row "enable prints ok" "$rt_live" "STUB_REPLY=ok" "plugin enable vgs.clock" "ok" 0 ""
run_row "reply is the last stdout line, log noise ahead of it is ignored" "$rt_live" "STUB_REPLY=ok STUB_NOISE=INFO:something" "plugin enable vgs.clock" "ok" 0 ""
run_row "stderr after the reply does not become the reply" "$rt_live" "STUB_REPLY=ok STUB_STDERR=WARN:late" "plugin enable vgs.clock" "ok" 0 "WARN:late"
run_row "an unexpected reply is a refusal" "$rt_live" "STUB_REPLY=ok_hidden" "plugin disable vgs.bar" "" 1 "vgsh: refused: ok_hidden"
run_row "a guard refusal from the shell is a refusal with exit 1" "$rt_live" "STUB_REPLY=refused:_guard=unowned" "plugin enable vgs.clock" "" 1 "vgsh: refused: refused:_guard=unowned"
run_row "unknown id is a refusal with exit 1" "$rt_live" "STUB_REPLY=unknown:_x" "plugin enable x" "" 1 "vgsh: refused: unknown:_x"
run_row "an ipc failure exits 69 on enable" "$rt_live" "STUB_STATUS=1 STUB_REPLY=none" "plugin enable vgs.clock" "" 69 "vgsh: refused: shell=not-running pid=$$"
run_row "an ipc failure exits 69 on list" "$rt_live" "STUB_STATUS=1 STUB_REPLY=none" "plugin list" "" 69 "vgsh: refused: shell=not-running pid=$$"
run_row "no lock file exits 69 without calling qs" "$rt_empty" "STUB_REPLY=ok" "plugin enable vgs.clock" "" 69 "vgsh: refused: shell=not-running lock=$rt_empty/vgsh.lock"
run_row "no lock file exits 69 on ipc" "$rt_empty" "STUB_REPLY=ok" "ipc call shell ping" "" 69 "vgsh: refused: shell=not-running lock=$rt_empty/vgsh.lock"
run_row "pid prints the pid the lock file records" "$rt_live" "" "pid" "$$" 0 ""
run_row "pid with no lock file exits 69" "$rt_empty" "" "pid" "" 69 "vgsh: refused: shell=not-running lock=$rt_empty/vgsh.lock"
run_row "missing id is exit 2" "$rt_live" "" "plugin enable" "" 2 "vgsh: refused: id=missing"
run_row "unknown subcommand is exit 2" "$rt_live" "" "plugin frobnicate" "" 2 "vgsh: refused: plugin-subcommand=frobnicate"
run_row "unknown command is exit 2" "$rt_live" "" "frobnicate" "" 2 "vgsh: refused: command=frobnicate"
run_row "run refuses an argument" "$rt_live" "STUB_RECORD=$tmp/never" "run --daemonize" "" 2 "vgsh: refused: argument=--daemonize"
if [[ ! -e $tmp/never ]]; then ok "a refused run never started the shell"; else fail "a refused run started the shell"; fi

# The recorded pid must be a dead process for the not-running refusal, and
# a pid nothing can own is the one past the kernel's maximum.
rt_dead="$tmp/rt-dead"; mkdir -p "$rt_dead"; printf '%s\n' "$dead_pid" >"$rt_dead/vgsh.lock"
run_row "a lock file naming a dead pid exits 69" "$rt_dead" "STUB_REPLY=ok" "plugin list" "" 69 "vgsh: refused: shell=not-running pid=$dead_pid"
run_row "pid with a lock file naming a dead pid exits 69" "$rt_dead" "" "pid" "" 69 "vgsh: refused: shell=not-running pid=$dead_pid"
rt_junk="$tmp/rt-junk"; mkdir -p "$rt_junk"; printf 'x\n' >"$rt_junk/vgsh.lock"
run_row "a lock file holding no pid exits 69" "$rt_junk" "STUB_REPLY=ok" "plugin list" "" 69 "vgsh: refused: shell=not-running lock=$rt_junk/vgsh.lock"

# Every call addresses the recorded pid, never whichever instance qs picks.
"${base_env[@]}" XDG_RUNTIME_DIR="$rt_live" STUB_ARGS="$tmp/args" STUB_REPLY=ok "$repo/bin/vgsh" plugin enable vgs.clock >/dev/null
if [[ "$(cat "$tmp/args")" == "ipc --pid $$ call shell setPluginEnabled vgs.clock true" ]]; then ok "a manager call names the runner's pid"; else fail "manager call args: $(cat "$tmp/args")"; fi
"${base_env[@]}" XDG_RUNTIME_DIR="$rt_live" STUB_ARGS="$tmp/args" STUB_REPLY=ok "$repo/bin/vgsh" ipc call shell ping >/dev/null
if [[ "$(cat "$tmp/args")" == "ipc --pid $$ call shell ping" ]]; then ok "a raw ipc call names the runner's pid"; else fail "ipc args: $(cat "$tmp/args")"; fi

# The hidden reply carries a space, which env cannot pass; call directly.
set +e
out="$("${base_env[@]}" XDG_RUNTIME_DIR="$rt_live" STUB_REPLY='ok hidden=vgs.clock,vgs.workspaces' "$repo/bin/vgsh" plugin disable vgs.bar 2>/dev/null)"
status=$?
set -e
if [[ $status == 0 && $out == $'ok hidden=vgs.clock,vgs.workspaces\nthose bar widgets stay enabled and return when a bar is enabled' ]]; then ok "disable prints the hidden widgets and the note"; else fail "hidden reply: exit=$status out=[$out]"; fi

# The instance lock. With no holder, run takes the lock, records its pid
# and execs the shell with that pid as its identity; with a holder it exits
# 75 before any shell starts.
rt_run="$tmp/rt-run"; mkdir -p "$rt_run/vgsh-sources-1"; : >"$rt_run/vgsh-sources-1/x"
run_state="$tmp/home/.local/state/vgs"
if [[ ! -e $run_state ]]; then ok "no state directory stands before run"; else fail "a row before run created $run_state"; fi
set +e
"${base_env[@]}" XDG_RUNTIME_DIR="$rt_run" STUB_RECORD="$tmp/record" "$repo/bin/vgsh" run 2>"$tmp/err"
status=$?
set -e
if [[ $status == 0 && -f $tmp/record ]]; then
  record="$(cat "$tmp/record")"
  pid="${record#pid=}"; pid="${pid%% *}"
  runner="${record#*runner=}"; runner="${runner%% *}"
  args="${record#*args=}"
  if [[ $pid == "$runner" ]]; then ok "run execs the shell with its own pid as the runner identity"; else fail "run identity: $record"; fi
  if run_has_file_watcher_env "$record"; then ok "run disables Quickshell's file watcher and reload popup"; else fail "run watcher env: $record"; fi
  if [[ "$(cat "$rt_run/vgsh.lock")" == "$pid" ]]; then ok "run records the shell's pid in the lock file"; else fail "lock file holds [$(cat "$rt_run/vgsh.lock")] want $pid"; fi
  if [[ $args == "-p $repo/shell" ]]; then ok "run passes qs the shell path and nothing else"; else fail "run args: $args"; fi
  if [[ ! -e $rt_run/vgsh-sources-1 ]]; then ok "run removes the source snapshot roots dead shells left"; else fail "run left $rt_run/vgsh-sources-1"; fi
  if [[ -d $run_state ]]; then ok "run creates the state directory the shell watches"; else fail "run left no $run_state"; fi
  if [[ -d $rt_run/vgs/tui ]]; then ok "run creates the TUI record directory the shell lists"; else fail "run left no $rt_run/vgs/tui"; fi
else
  fail "unlocked run: exit=$status record=$([[ -f $tmp/record ]] && echo present || echo absent) stderr=$(head -n 1 "$tmp/err")"
fi

mutant="$tmp/mutant"; mkdir -p "$mutant/bin" "$mutant/shell"
cp -- "$repo/bin/vgsh" "$mutant/bin/vgsh"; chmod +x "$mutant/bin/vgsh"
python3 - "$mutant/bin/vgsh" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = 'VGSH_RUNNER_PID=$$ QS_DISABLE_FILE_WATCHER=1 QS_NO_RELOAD_POPUP=1 exec qs -p "$shell_dir"'
new = 'VGSH_RUNNER_PID=$$ exec qs -p "$shell_dir"'
count = text.count(old)
if count != 1:
    raise SystemExit(f"watcher-env-control: expected one match, found {count}")
changed = text.replace(old, new)
if changed == text:
    raise SystemExit("watcher-env-control: mutation changed nothing")
path.write_text(changed)
PY
rt_mutant="$tmp/rt-mutant"; mkdir -p "$rt_mutant"
set +e
"${base_env[@]}" XDG_RUNTIME_DIR="$rt_mutant" STUB_RECORD="$tmp/record-mutant" "$mutant/bin/vgsh" run 2>"$tmp/err"
status=$?
set -e
mutant_record=""
[[ -f $tmp/record-mutant ]] && mutant_record="$(cat "$tmp/record-mutant")"
if [[ $status == 0 && -n $mutant_record ]] && ! run_has_file_watcher_env "$mutant_record"; then
  ok "a vgsh run without the watcher environment fails the assertion"
else
  fail "watcher env mutant: exit=$status record=${mutant_record:-absent}"
fi

rt_held="$tmp/rt-held"; mkdir -p "$rt_held/vgsh-sources-2"; : >"$rt_held/vgsh-sources-2/x"; printf '%s\n' "$$" >"$rt_held/vgsh.lock"
exec 8>>"$rt_held/vgsh.lock"
flock 8
set +e
"${base_env[@]}" XDG_RUNTIME_DIR="$rt_held" STUB_RECORD="$tmp/record-held" "$repo/bin/vgsh" run 2>"$tmp/err"
status=$?
set -e
exec 8>&-
if [[ $status == 75 && ! -e $tmp/record-held ]]; then ok "a held lock makes run exit 75 without starting the shell"; else fail "held lock: exit=$status record=$([[ -e $tmp/record-held ]] && echo present || echo absent) stderr=$(head -n 1 "$tmp/err")"; fi
if [[ "$(head -n 1 "$tmp/err")" == "vgsh: refused: lock=$rt_held/vgsh.lock" ]]; then ok "the lock refusal names the lock file"; else fail "lock refusal line: $(head -n 1 "$tmp/err")"; fi
if [[ "$(cat "$rt_held/vgsh.lock")" == "$$" ]]; then ok "a refused run leaves the holder's pid in the lock file"; else fail "lock file after refusal: $(cat "$rt_held/vgsh.lock")"; fi
if [[ -e $rt_held/vgsh-sources-2/x ]]; then ok "a refused run leaves the holder's source snapshot root alone"; else fail "a refused run removed $rt_held/vgsh-sources-2"; fi

# The preflight. A stub node answers --version with STUB_NODE_VERSION, the
# floor unless a row sets it, and hands every other call to the real node.
# A `no-<tool>` PATH holds only what a refused run reaches, bash, readlink,
# dirname, mktemp, rm and the probed tools, less <tool>.
mkdir -p "$tmp/pre-node"
printf '#!/usr/bin/env bash\nif [[ ${1:-} == --version ]]; then printf "%%s\\n" "${STUB_NODE_VERSION:-v18.0.0}"; exit 0; fi\nexec %q "$@"\n' "$node_bin" >"$tmp/pre-node/node"
chmod +x "$tmp/pre-node/node"
for missing in qs hyprctl node python3 git; do
  mkdir -p "$tmp/pre-no-$missing"
  for tool in bash readlink dirname mktemp rm qs hyprctl node python3 git; do
    [[ $tool == "$missing" ]] && continue
    case "$tool" in
      qs|hyprctl) tool_bin="$tmp/$tool" ;;
      node) tool_bin="$tmp/pre-node/node" ;;
      *) tool_bin="$(command -v "$tool")" || { echo "test-vgsh: status=not-measured missing=$tool"; exit 77; } ;;
    esac
    ln -s -- "$tool_bin" "$tmp/pre-no-$missing/$tool"
  done
done
pre_path() { # KIND: full, or no-<tool>
  if [[ $1 == full ]]; then printf '%s\n' "$tmp/pre-node:$base_path"; else printf '%s\n' "$tmp/pre-$1"; fi
}

# One `vgsh run` from BIN in a fresh runtime, configuration, state and
# scratch directory, the runtime one holding a snapshot root, with
# ASSIGNMENT (one VAR=value, or empty) added to the environment.
pre_case=0
pre_run() { # BIN KIND ASSIGNMENT
  local dir
  local -a extra=()
  pre_case=$((pre_case + 1))
  dir="$tmp/pre-case-$pre_case"
  pre_rt="$dir/rt"; pre_cfg="$dir/cfg"; pre_state="$dir/state"; pre_record="$dir/record"; pre_tmp="$dir/tmp"
  mkdir -p -- "$pre_rt/vgsh-sources-1" "$pre_tmp"; : >"$pre_rt/vgsh-sources-1/x"
  [[ -n $3 ]] && extra=("$3")
  set +e
  "${base_env[@]}" PATH="$(pre_path "$2")" TMPDIR="$pre_tmp" XDG_RUNTIME_DIR="$pre_rt" XDG_CONFIG_HOME="$pre_cfg" XDG_STATE_HOME="$pre_state" STUB_RECORD="$pre_record" "${extra[@]}" "$1" run 2>"$tmp/err" </dev/null
  pre_status=$?
  set -e
  pre_err=""
  [[ -s $tmp/err ]] && IFS= read -r pre_err <"$tmp/err"
  return 0
}
# True when the last pre_run exited WANT_EXIT with WANT_ERR first on stderr,
# left its scratch directory empty, and left what that outcome promises: a
# start ran the shell; a refusal started nothing, took no lock file,
# created no directory and left the snapshot root.
pre_held() { # WANT_EXIT WANT_ERR
  local left
  [[ $pre_status == "$1" && $pre_err == "$2" ]] || return 1
  left="$(find "$pre_tmp" -mindepth 1 -print -quit)" || return 1
  [[ -z $left ]] || return 1
  if [[ $1 == 0 ]]; then
    [[ -f $pre_record ]]
  else
    [[ ! -e $pre_record && ! -e $pre_rt/vgsh.lock && -e $pre_rt/vgsh-sources-1/x && ! -e $pre_cfg && ! -e $pre_state ]]
  fi
}

# rows: name | PATH kind | assignment | want exit | want stderr (first line)
while IFS='|' read -r name kind assignment want_exit want_err; do
  [[ -n $name ]] || continue
  pre_run "$repo/bin/vgsh" "$kind" "$assignment"
  if pre_held "$want_exit" "$want_err"; then ok "$name"; else fail "$name: exit=$pre_status want=$want_exit stderr=[$pre_err] want=[$want_err] record=$([[ -e $pre_record ]] && echo present || echo absent) lock=$([[ -e $pre_rt/vgsh.lock ]] && echo present || echo absent)"; fi
done <<'ROWS'
run starts the shell with every tool at or above its floor|full||0|
Quickshell 0.3.0 is below the floor|full|STUB_QS_VERSION=Quickshell 0.3.0 (revision x)|78|vgsh: refused: preflight=quickshell have=0.3.0 need=0.3.1
Quickshell 0.10.0 meets 0.3.1: components compare as numbers|full|STUB_QS_VERSION=Quickshell 0.10.0|0|
a warning qs prints on stderr ahead of its version is not read|full|STUB_QS_STDERR=qt.qpa: warning|0|
a Quickshell version line with no number is unknown|full|STUB_QS_VERSION=Quickshell git|78|vgsh: refused: preflight=quickshell have=unknown need=0.3.1
a failed qs --version is unknown|full|STUB_QS_VERSION_EXIT=1|78|vgsh: refused: preflight=quickshell have=unknown need=0.3.1
no qs on PATH is none|no-qs||78|vgsh: refused: preflight=quickshell have=none need=0.3.1
Hyprland 0.55.9 is below the floor|full|STUB_HYPR_VERSION=0.55.9|78|vgsh: refused: preflight=hyprland have=0.55.9 need=0.56
Hyprland 0.56 meets 0.56: a missing component is 0|full|STUB_HYPR_VERSION=0.56|0|
a Hyprland that does not answer is unknown|full|STUB_HYPR_VERSION_EXIT=4|78|vgsh: refused: preflight=hyprland have=unknown need=0.56
no hyprctl on PATH is none|no-hyprctl||78|vgsh: refused: preflight=hyprland have=none need=0.56
node 17.9.1 is below the floor|full|STUB_NODE_VERSION=v17.9.1|78|vgsh: refused: preflight=node have=17.9.1 need=18
no node on PATH is none|no-node||78|vgsh: refused: preflight=node have=none need=18
no python3 on PATH is none|no-python3||78|vgsh: refused: preflight=python3 have=none need=present
no git on PATH is none|no-git||78|vgsh: refused: preflight=git have=none need=present
with Quickshell below its floor and no node, the refusal names the earlier row|no-node|STUB_QS_VERSION=Quickshell 0.3.0|78|vgsh: refused: preflight=quickshell have=0.3.0 need=0.3.1
with Hyprland below its floor and no git, the refusal names the earlier row|no-git|STUB_HYPR_VERSION=0.55.9|78|vgsh: refused: preflight=hyprland have=0.55.9 need=0.56
ROWS

# A scratch root mktemp cannot write in refuses before any probe starts.
pre_no_tmp="$tmp/pre-no-tmpdir"
pre_run "$repo/bin/vgsh" full "TMPDIR=$pre_no_tmp"
if pre_held 1 "vgsh: refused: scratch=$pre_no_tmp"; then ok "a scratch root mktemp cannot write in refuses the run"; else fail "absent scratch root: exit=$pre_status stderr=[$pre_err]"; fi

# Must-fail controls, one per rule of the preflight, each on a copy of
# bin/vgsh with each NEEDLE replaced once by its REPLACEMENT: the row the
# rule decides must no longer hold on the copy. pre_copy prints the copy.
pre_copies=0
pre_copy() { # NEEDLE REPLACEMENT [NEEDLE REPLACEMENT...]
  local copy
  pre_copies=$((pre_copies + 1))
  copy="$tmp/pre-mutant-$pre_copies"
  mkdir -p -- "$copy/bin" "$copy/shell"
  cp -- "$repo/bin/vgsh" "$copy/bin/vgsh"
  python3 - "$copy/bin/vgsh" "$@" <<'PY' || return 1
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = original = path.read_text()
pairs = sys.argv[2:]
for needle, replacement in zip(pairs[::2], pairs[1::2]):
    if text.count(needle) != 1:
        raise SystemExit(f"preflight-control: expected one match of {needle!r}, found {text.count(needle)}")
    text = text.replace(needle, replacement)
if text == original:
    raise SystemExit("preflight-control: mutation changed nothing")
path.write_text(text)
PY
  printf '%s\n' "$copy/bin/vgsh"
}
pre_control() { # NAME KIND ASSIGNMENT WANT_EXIT WANT_ERR NEEDLE REPLACEMENT [NEEDLE REPLACEMENT...]
  local name="$1" kind="$2" assignment="$3" want_exit="$4" want_err="$5" copy
  shift 5
  if ! copy="$(pre_copy "$@")"; then fail "the $name control could not edit its copy"; return 0; fi
  pre_run "$copy" "$kind" "$assignment"
  if pre_held "$want_exit" "$want_err"; then fail "the $name control still holds: exit=$pre_status stderr=[$pre_err]"; else ok "the $name control fails its row"; fi
}
probe_line='"${argv[@]}" >&"${scratch_fds[i]}" 2>/dev/null </dev/null &'
pre_control "floor row" full STUB_HYPR_VERSION=0.55.9 78 "vgsh: refused: preflight=hyprland have=0.55.9 need=0.56" \
  'hyprland   0.56    "version"' 'hyprland   present "version"'
pre_control "numeric compare" full "STUB_QS_VERSION=Quickshell 0.10.0" 0 "" \
  $'    ((h > w)) && return 0\n' ''
pre_control "failed probe" full STUB_HYPR_VERSION_EXIT=4 78 "vgsh: refused: preflight=hyprland have=unknown need=0.56" \
  '[[ ${statuses[i]} == 0 ]] ||' '[[ ${statuses[i]} == 0 ]] || true ||'
pre_control "stdout only" full "STUB_QS_STDERR=qt.qpa: warning" 0 "" \
  "$probe_line" '"${argv[@]}" >&"${scratch_fds[i]}" 2>&1 </dev/null &'
pre_control "unread version" full "STUB_QS_VERSION=Quickshell git" 78 "vgsh: refused: preflight=quickshell have=unknown need=0.3.1" \
  '[[ ${outs[i]} =~ $pattern ]] ||' '[[ ${outs[i]} =~ $pattern ]] || true ||'
pre_control "absent tool" no-git "" 78 "vgsh: refused: preflight=git have=none need=present" \
  '[[ -n ${pids[i]} ]] ||' '[[ -n ${pids[i]} ]] || true ||'
pre_control "preflight first" full STUB_HYPR_VERSION=0.55.9 78 "vgsh: refused: preflight=hyprland have=0.55.9 need=0.56" \
  $'    preflight\n    # The shell watches' '    # The shell watches' \
  '    VGSH_RUNNER_PID=$$ QS_DISABLE' $'    preflight\n    VGSH_RUNNER_PID=$$ QS_DISABLE'
pre_control "table order" no-node "STUB_QS_VERSION=Quickshell 0.3.0" 78 "vgsh: refused: preflight=quickshell have=0.3.0 need=0.3.1" \
  $'  for i in "${!tools[@]}"; do\n    tool=' $'  for ((i = ${#tools[@]} - 1; i >= 0; i--)); do\n    tool='
pre_control "scratch refused" full "TMPDIR=$pre_no_tmp" 1 "vgsh: refused: scratch=$pre_no_tmp" \
  'scratch="$(mktemp -d 2>&1)" || refuse 1 "scratch=${TMPDIR:-/tmp}" "$scratch"' 'scratch="$(mktemp -d 2>&1)" || true'
pre_control "scratch removed" full "" 0 "" \
  $'  rm -rf -- "$scratch" || refuse 1 "scratch=$scratch"\n' ''

# Restart stops only the recorded pid, waits for the lock to free and asks
# Hyprland to launch the new runner so it inherits the session environment.
cmd="$(printf '%q run' "$repo/bin/vgsh")"
lua_request="hl.dsp.exec_cmd(\"$cmd\")"
classic_request="exec $cmd"

rt_restart_locked="$tmp/rt-restart-locked"; dispatch="$tmp/dispatch-locked"
start_fake_shell "restart locked fixture starts a shell" "$rt_restart_locked" "$tmp/record-locked"
locked_pid="$fake_pid"
run_restart_capture "$rt_restart_locked" "$tmp/record-locked-new" "$dispatch" true
if [[ $restart_status == 4 && -z $restart_out && $restart_err == "vgsh: refused: session=locked" ]]; then ok "restart refuses while the session is locked"; else fail "locked restart: exit=$restart_status out=[$restart_out] stderr=[$restart_err]"; fi
if [[ -d /proc/$locked_pid ]]; then ok "a locked restart leaves the shell running"; else fail "locked restart stopped pid=$locked_pid"; fi
if [[ ! -e $dispatch ]]; then ok "a locked restart never dispatches a relaunch"; else fail "locked restart dispatched: $(cat "$dispatch")"; fi

rt_restart_locked_unanswered="$tmp/rt-restart-locked-unanswered"; dispatch="$tmp/dispatch-locked-unanswered"
start_fake_shell "restart locked-unanswered fixture starts a shell" "$rt_restart_locked_unanswered" "$tmp/record-locked-unanswered"
unanswered_pid="$fake_pid"
run_restart_capture "$rt_restart_locked_unanswered" "$tmp/record-locked-unanswered-new" "$dispatch" false STUB_STATUS=1
if [[ $restart_status == 1 && -z $restart_out && $restart_err == "vgsh: refused: locked=unanswered pid=$unanswered_pid" ]]; then ok "restart refuses when shell.locked is unanswered"; else fail "locked unanswered restart: exit=$restart_status out=[$restart_out] stderr=[$restart_err]"; fi
if [[ -d /proc/$unanswered_pid ]]; then ok "a locked-unanswered restart leaves the shell running"; else fail "locked-unanswered restart stopped pid=$unanswered_pid"; fi
if [[ ! -e $dispatch ]]; then ok "a locked-unanswered restart never dispatches"; else fail "locked-unanswered restart dispatched: $(cat "$dispatch")"; fi

rt_restart_lua="$tmp/rt-restart-lua"; dispatch="$tmp/dispatch-lua"
start_fake_shell "restart lua fixture starts a shell" "$rt_restart_lua" "$tmp/record-lua-old"
old_pid="$fake_pid"
run_restart_capture "$rt_restart_lua" "$tmp/record-lua-new" "$dispatch" false STUB_ARGS="$tmp/args-lua"
wait "$old_pid" 2>/dev/null || true
if [[ $restart_status == 0 && $restart_out =~ ^ok\ pid=([0-9]+)$ ]]; then
  new_pid="${BASH_REMATCH[1]}"; started_pids+=("$new_pid"); ok "restart prints the relaunched pid"
else
  new_pid=""
  fail "lua restart: exit=$restart_status out=[$restart_out] stderr=[$restart_err]"
fi
if [[ -n $new_pid && ! -d /proc/$old_pid && -d /proc/$new_pid ]]; then ok "restart stops the old pid and leaves the new pid running"; else fail "restart pids old_live=$([[ -d /proc/$old_pid ]] && echo yes || echo no) new=$new_pid"; fi
if [[ -n $new_pid && "$(cat "$rt_restart_lua/vgsh.lock")" == "$new_pid" ]]; then ok "restart records the new pid in the lock file"; else fail "restart lock holds [$(cat "$rt_restart_lua/vgsh.lock" 2>/dev/null || echo absent)] want $new_pid"; fi
if [[ "$(cat "$dispatch")" == "$lua_request" ]]; then ok "restart uses the Lua Hyprland exec dialect"; else fail "lua dispatch: $(cat "$dispatch")"; fi
if [[ -n $new_pid && "$(cat "$tmp/args-lua")" == "ipc --pid $new_pid call shell guarded" ]]; then ok "restart waits for the new guarded shell"; else fail "lua guarded check: $(cat "$tmp/args-lua" 2>/dev/null || echo absent)"; fi
new_record="$(cat "$tmp/record-lua-new")"
if [[ $(record_runner "$new_record") == "$new_pid" ]] && run_has_file_watcher_env "$new_record"; then ok "the relaunched shell gets the runner and watcher environment"; else fail "new shell record: $new_record"; fi

rt_restart_guarded_retry="$tmp/rt-restart-guarded-retry"; dispatch="$tmp/dispatch-guarded-retry"; guarded_count="$tmp/guarded-count"
start_fake_shell "restart guarded-retry fixture starts a shell" "$rt_restart_guarded_retry" "$tmp/record-guarded-retry-old"
old_pid="$fake_pid"
run_restart_capture "$rt_restart_guarded_retry" "$tmp/record-guarded-retry-new" "$dispatch" false STUB_GUARDED_FALSE_CALLS=2 STUB_GUARDED_COUNT="$guarded_count"
wait "$old_pid" 2>/dev/null || true
if [[ $restart_status == 0 && $restart_out =~ ^ok\ pid=([0-9]+)$ ]]; then guarded_retry_pid="${BASH_REMATCH[1]}"; started_pids+=("$guarded_retry_pid"); ok "restart waits through guarded=false replies"; else guarded_retry_pid=""; fail "guarded retry restart: exit=$restart_status out=[$restart_out] stderr=[$restart_err]"; fi
guarded_calls=0; [[ -r $guarded_count ]] && IFS= read -r guarded_calls <"$guarded_count"
if (( guarded_calls >= 3 )); then ok "restart retries until guarded answers true"; else fail "guarded retry count: $guarded_calls"; fi

rt_restart_classic="$tmp/rt-restart-classic"; dispatch="$tmp/dispatch-classic"
start_fake_shell "restart classic fixture starts a shell" "$rt_restart_classic" "$tmp/record-classic-old"
old_pid="$fake_pid"
run_restart_capture "$rt_restart_classic" "$tmp/record-classic-new" "$dispatch" false 'STUB_HYPR_STATUS={"configProvider":"hyprlang"}' STUB_ARGS="$tmp/args-classic"
wait "$old_pid" 2>/dev/null || true
if [[ $restart_status == 0 && $restart_out =~ ^ok\ pid=([0-9]+)$ ]]; then classic_pid="${BASH_REMATCH[1]}"; started_pids+=("$classic_pid"); ok "restart succeeds with the classic Hyprland dialect"; else classic_pid=""; fail "classic restart: exit=$restart_status out=[$restart_out] stderr=[$restart_err]"; fi
if [[ "$(cat "$dispatch")" == "$classic_request" ]]; then ok "restart uses the classic Hyprland exec dialect"; else fail "classic dispatch: $(cat "$dispatch")"; fi
if [[ -n $classic_pid && "$(cat "$tmp/args-classic")" == "ipc --pid $classic_pid call shell guarded" ]]; then ok "classic restart waits for the new guarded shell"; else fail "classic guarded check: $(cat "$tmp/args-classic" 2>/dev/null || echo absent)"; fi

rt_restart_unreachable="$tmp/rt-restart-unreachable"; dispatch="$tmp/dispatch-unreachable"
start_fake_shell "restart unreachable fixture starts a shell" "$rt_restart_unreachable" "$tmp/record-unreachable"
unreachable_pid="$fake_pid"
run_restart_capture "$rt_restart_unreachable" "$tmp/record-unreachable-new" "$dispatch" false STUB_HYPR_STATUS_EXIT=1
if [[ $restart_status == 69 && -z $restart_out && $restart_err == "vgsh: refused: hyprland=unreachable" ]]; then ok "restart refuses when Hyprland is unreachable"; else fail "unreachable restart: exit=$restart_status out=[$restart_out] stderr=[$restart_err]"; fi
if [[ -d /proc/$unreachable_pid ]]; then ok "an unreachable Hyprland leaves the shell running"; else fail "unreachable restart stopped pid=$unreachable_pid"; fi
if [[ ! -e $dispatch ]]; then ok "an unreachable Hyprland never dispatches"; else fail "unreachable restart dispatched: $(cat "$dispatch")"; fi

# Below the floor restart refuses as run does, before it stops the shell.
# restart_below LABEL BIN sets below_pid and below_held; the control's copy
# of bin/vgsh has no preflight call in restart and must not hold.
restart_below() { # LABEL BIN
  local rt="$tmp/rt-restart-below-$1" dispatch
  dispatch="$rt/dispatch"
  start_fake_shell "restart below-floor fixture starts a shell" "$rt" "$rt/record-old"
  below_pid="$fake_pid"
  # A refused dispatch ends a restart that got past the floor at once,
  # rather than after its wait for a runner that refused to start.
  RESTART_BIN="$2" run_restart_capture "$rt" "$rt/record-new" "$dispatch" false STUB_HYPR_VERSION=0.55.9 STUB_HYPR_REPLY=nope
  below_held=false
  if [[ $restart_status == 78 && -z $restart_out && $restart_err == "vgsh: refused: preflight=hyprland have=0.55.9 need=0.56" && -d /proc/$below_pid && ! -e $dispatch ]]; then below_held=true; fi
}
restart_below real "$repo/bin/vgsh"
if [[ $below_held == true ]]; then ok "restart below the floor exits 78, leaves the shell running and never dispatches"; else fail "restart below floor: exit=$restart_status out=[$restart_out] stderr=[$restart_err] old_live=$([[ -d /proc/$below_pid ]] && echo yes || echo no)"; fi
if restart_copy="$(pre_copy $'    preflight\n    shell_restart\n' $'    shell_restart\n')"; then
  restart_below mutant "$restart_copy"
  if [[ $below_held == false ]]; then ok "the restart preflight control fails its row"; else fail "the restart preflight control still holds"; fi
else
  fail "the restart preflight control could not edit its copy"
fi

run_restart_capture "$rt_empty" "$tmp/record-not-running" "$tmp/dispatch-not-running" false
if [[ $restart_status == 69 && -z $restart_out && $restart_err == "vgsh: refused: shell=not-running lock=$rt_empty/vgsh.lock" ]]; then ok "restart with no shell exits 69"; else fail "restart not-running: exit=$restart_status out=[$restart_out] stderr=[$restart_err]"; fi

set +e
restart_out="$("${base_env[@]}" XDG_RUNTIME_DIR="$rt_empty" "$repo/bin/vgsh" restart again 2>"$tmp/err")"
restart_status=$?
set -e
restart_err=""; [[ -s $tmp/err ]] && IFS= read -r restart_err <"$tmp/err"
if [[ $restart_status == 2 && -z $restart_out && $restart_err == "vgsh: refused: argument=again" ]]; then ok "restart refuses an argument"; else fail "restart argument: exit=$restart_status out=[$restart_out] stderr=[$restart_err]"; fi

rt_restart_bad_reply="$tmp/rt-restart-bad-reply"; dispatch="$tmp/dispatch-bad-reply"
start_fake_shell "restart dispatch-failure fixture starts a shell" "$rt_restart_bad_reply" "$tmp/record-bad-reply-old"
old_pid="$fake_pid"
run_restart_capture "$rt_restart_bad_reply" "$tmp/record-bad-reply-new" "$dispatch" false STUB_HYPR_REPLY=nope
wait "$old_pid" 2>/dev/null || true
if [[ $restart_status == 1 && -z $restart_out && $restart_err == "vgsh: refused: start=failed reply=nope" ]]; then ok "restart refuses a failed Hyprland dispatch reply"; else fail "restart bad dispatch: exit=$restart_status out=[$restart_out] stderr=[$restart_err]"; fi
if [[ ! -d /proc/$old_pid ]]; then ok "a failed relaunch reports that the old shell stopped"; else fail "failed relaunch left old pid=$old_pid"; fi

rt_restart_exited="$tmp/rt-restart-exited"; dispatch="$tmp/dispatch-exited"
start_fake_shell "restart exited fixture starts a shell" "$rt_restart_exited" "$tmp/record-exited-old"
old_pid="$fake_pid"
run_restart_capture "$rt_restart_exited" "$tmp/record-exited-new" "$dispatch" false STUB_SHELL_HOLD=
wait "$old_pid" 2>/dev/null || true
if [[ $restart_status == 1 && -z $restart_out && $restart_err =~ ^vgsh:\ refused:\ start=exited\ pid=([0-9]+)$ ]]; then exited_pid="${BASH_REMATCH[1]}"; ok "restart refuses a shell that exits before it is guarded"; else exited_pid=""; fail "exited restart: exit=$restart_status out=[$restart_out] stderr=[$restart_err]"; fi
if [[ -n $exited_pid && ! -d /proc/$exited_pid ]]; then ok "the exited restart names a dead replacement pid"; else fail "exited restart pid live=$([[ -n $exited_pid && -d /proc/$exited_pid ]] && echo yes || echo no) pid=${exited_pid:-missing}"; fi

# Install, update and remove, with local bare repositories as the source,
# through the library's `g` and plugin source fixture.
source_repo probe "$(manifest acme.probe 0.1.0)"
source_repo broken "$(manifest acme.broken 0.1.0 ', "requires": []')"
source_repo taken "$(manifest vgs.bar 0.1.0)"

no_residue() { # CONFIG_HOME: nothing staged is left and no plugin landed
  local left
  left="$(find "$1/vgs" -mindepth 1 -maxdepth 2 \( -name '.vgsh-add.*' -o -path "$1/vgs/plugins/*" \) -print)" || return 1
  [[ -z $left ]]
}

# Git hooks are live for every git call from here on: the fixture home's
# global configuration points core.hooksPath at hooks that leave a marker
# beside themselves. A plain git call in the control checkout proves a hook
# fires under this isolation; a vgsh row must leave the marker absent.
hooks="$tmp/hooks"; mkdir -p "$hooks"
for hook in post-checkout post-merge; do
  printf '#!/bin/sh\nprintf "" >"$0.marker"\n' >"$hooks/$hook"
  chmod +x "$hooks/$hook"
done
g config --global core.hooksPath "$hooks"
control="$tmp/control"
g clone -q "$tmp/src/probe.git" "$control"
check "a plain clone under the fixture configuration runs the post-checkout hook" test -e "$hooks/post-checkout.marker"
rm -f -- "${hooks:?}/post-checkout.marker"

cfg="$tmp/cfg-add"; plugin="$cfg/vgs/plugins/acme.probe"
inst "add installs the plugin and reports no running shell" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/probe.git"
check "add runs no post-checkout hook" test ! -e "$hooks/post-checkout.marker"
check "add names the plugin, its path and an unchanged configuration" test "$(head -n 1 "$tmp/out")" == "ok added=acme.probe path=$plugin config=unchanged"
check "add lands the plugin under the user plugin directory" json_is "$plugin/manifest.json" 'd["id"] == "acme.probe"'
check "add leaves no staging directory" test -z "$(find "$cfg/vgs" -maxdepth 1 -name '.vgsh-add.*' -print)"
check "add writes no user file for a plugin the configuration does not enable" test ! -e "$cfg/vgs/shell.json"

# The must-fail control: a copy of vgsh without the hook suppression lets
# the post-checkout hook fire on add. The copy resolves shell, config
# and its bin siblings, bin/lib among them, from its own location, so each
# is linked in.
mutant="$tmp/mutant"; mkdir -p "$mutant/bin"
suppression='-c core.hooksPath=/dev/null '
occurrences="$(grep -o -F -- "$suppression" "$repo/bin/vgsh" | wc -l)" || occurrences=0
check "the hook suppression occurs once in bin/vgsh" test "$occurrences" == 1
sed "s|$suppression||" "$repo/bin/vgsh" >"$mutant/bin/vgsh"
chmod +x "$mutant/bin/vgsh"
check "the mutant differs from bin/vgsh" test "$(cmp -s "$repo/bin/vgsh" "$mutant/bin/vgsh"; echo $?)" == 1
for sibling in shell config; do ln -s "$repo/$sibling" "$mutant/$sibling"; done
for tool in vgsh-scan vgsh-plugin-judge lib; do ln -s "$repo/bin/$tool" "$mutant/bin/$tool"; done
cfg="$tmp/cfg-mutant"
INST_BIN="$mutant/bin/vgsh" inst "the mutant add installs the plugin" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/probe.git"
check "the mutant add runs the post-checkout hook" test -e "$hooks/post-checkout.marker"
rm -f -- "${hooks:?}/post-checkout.marker"

cfg="$tmp/cfg-listed"; mkdir -p "$cfg/vgs"
printf '{ "version": 1, "plugins": [ { "id": "acme.probe", "label": "kept" } ] }\n' >"$cfg/vgs/shell.json"
inst "add of a plugin the configuration lists succeeds" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/probe.git"
check "add of a listed plugin reports the user file written" test "$(head -n 1 "$tmp/out")" == "ok added=acme.probe path=$cfg/vgs/plugins/acme.probe config=written"
check "add lands a listed plugin disabled and keeps its settings row" json_is "$cfg/vgs/shell.json" 'd["disabledPlugins"] == ["acme.probe"] and d["plugins"] == [{"id": "acme.probe", "label": "kept"}]'

cfg="$tmp/cfg-live"
inst "add rescans a running shell" "$cfg" "$rt_live" 0 "shell=rescan-started" "" plugin add "$tmp/src/probe.git"
check "the rescan names the runner's pid and the plugin add installed" test "$(cat "$tmp/args")" == "ipc --pid $$ call shell pluginInstalled acme.probe"
# The plugin landed before the rescan was asked for; a reply the runner does
# not know is a refusal that names it, after the landing line.
cfg="$tmp/cfg-weird"
INST_REPLY=weird inst "add refuses an unknown rescan reply after landing the plugin" "$cfg" "$rt_live" 1 "ok added=acme.probe path=$cfg/vgs/plugins/acme.probe config=unchanged" "vgsh: refused: rescan=weird" plugin add "$tmp/src/probe.git"

cfg="$tmp/cfg-refused"
inst "add refuses a manifest the judge refuses" "$cfg" "$rt_empty" 1 "" "vgsh: refused: manifest=$tmp/src/broken.git" plugin add "$tmp/src/broken.git"
check "a refused manifest leaves no plugin and no staging directory" no_residue "$cfg"
inst "add refuses an id a bundled plugin owns" "$cfg" "$rt_empty" 1 "" "vgsh: refused: id-owned=vgs.bar owner=$repo/shell/plugins/vgs.bar" plugin add "$tmp/src/taken.git"
check "a refused bundled id leaves no plugin and no staging directory" no_residue "$cfg"
inst "add refuses an unreachable source" "$cfg" "$rt_empty" 1 "" "vgsh: refused: clone=$tmp/src/absent.git" plugin add "$tmp/src/absent.git"
check "a refused clone leaves no plugin and no staging directory" no_residue "$cfg"
inst "add without a url is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: url=missing" plugin add

cfg="$tmp/cfg-add"
inst "add refuses an id an installed plugin owns" "$cfg" "$rt_empty" 1 "" "vgsh: refused: id-owned=acme.probe owner=$plugin" plugin add "$tmp/src/probe.git"
cfg="$tmp/cfg-occupied"; mkdir -p "$cfg/vgs/plugins/acme.probe"
inst "add refuses a target directory that holds no plugin" "$cfg" "$rt_empty" 1 "" "vgsh: refused: exists=$cfg/vgs/plugins/acme.probe" plugin add "$tmp/src/probe.git"
# A plugin directory the scan cannot read may hold the id. Permission bits
# bind only a non-root uid.
if [[ $(id -u) != 0 ]]; then
  cfg="$tmp/cfg-locked"; mkdir -p "$cfg/vgs/plugins/locked"; chmod 000 "$cfg/vgs/plugins/locked"
  inst "add refuses when a plugin directory cannot be read" "$cfg" "$rt_empty" 1 "" "vgsh: refused: unreadable=$cfg/vgs/plugins/locked error=cannot read manifest: Permission denied" plugin add "$tmp/src/probe.git"
  chmod 700 "$cfg/vgs/plugins/locked"
fi
cfg="$tmp/cfg-unparseable"; mkdir -p "$cfg/vgs"; printf '{ nope\n' >"$cfg/vgs/shell.json"
inst "add refuses while the user file does not parse" "$cfg" "$rt_empty" 1 "" "vgsh: refused: user-config=unparseable path=$cfg/vgs/shell.json" plugin add "$tmp/src/probe.git"
check "a refused user file leaves no plugin and no staging directory" no_residue "$cfg"
cfg="$tmp/cfg-malformed"; mkdir -p "$cfg/vgs"; printf '{ "version": 1, "plugins": [ { "id": "acme.probe" }, "junk" ] }\n' >"$cfg/vgs/shell.json"
inst "add refuses a user file the config judge refuses" "$cfg" "$rt_empty" 1 "" "vgsh: refused: user-config=malformed path=$cfg/vgs/shell.json error=plugins.1 must be an object with a string id" plugin add "$tmp/src/probe.git"
check "a malformed user file leaves no plugin and no staging directory" no_residue "$cfg"
check "a malformed user file is left as it was" grep -q '"junk"' "$cfg/vgs/shell.json"

# Update against the plugin the first add row installed.
cfg="$tmp/cfg-add"
inst "update with nothing new is up to date" "$cfg" "$rt_empty" 0 "ok up-to-date=acme.probe" "" plugin update acme.probe
source_commit probe "$(manifest acme.probe 0.2.0)"
g -C "$control" fetch -q
g -C "$control" merge -q --ff-only '@{upstream}'
check "a plain fast-forward under the fixture configuration runs the post-merge hook" test -e "$hooks/post-merge.marker"
rm -f -- "${hooks:?}/post-merge.marker"
before="$(head_of "$plugin")"
inst "update without a terminal refuses after the diff" "$cfg" "$rt_empty" 1 "$any_out" "vgsh: refused: no-terminal=acme.probe" plugin update acme.probe
check "the unconfirmed update prints the incoming diff" grep -q '^+.*"version": "0.2.0"' "$tmp/out"
check "an update without a terminal leaves the checkout at its commit" test "$(head_of "$plugin")" == "$before"
on_terminal n plugin update acme.probe
check "an update declined on a terminal is refused" test "$term_status" == 1
check "the declined update names its refusal" grep -qF "vgsh: refused: declined=acme.probe" "$tmp/out"
check "a declined update leaves the checkout at its commit" test "$(head_of "$plugin")" == "$before"
check "a declined update runs no post-merge hook" test ! -e "$hooks/post-merge.marker"

# The must-fail control: a copy of vgsh that never asks fast-forwards both
# without a terminal and on a terminal that answers no.
ask='      confirm_change update "$label" "the checkout stays at ${ff_old:0:12}"'
check "the update asks once in bin/vgsh" test "$(grep -c -x -F -- "$ask" "$repo/bin/vgsh")" == 1
noask="$tmp/noask"; mkdir -p "$noask/bin"
grep -v -x -F -- "$ask" "$repo/bin/vgsh" >"$noask/bin/vgsh" || true
chmod +x "$noask/bin/vgsh"
check "the never-asking mutant differs from bin/vgsh" test "$(cmp -s "$repo/bin/vgsh" "$noask/bin/vgsh"; echo $?)" == 1
for sibling in shell config; do ln -s "$repo/$sibling" "$noask/$sibling"; done
for tool in vgsh-scan vgsh-plugin-judge lib; do ln -s "$repo/bin/$tool" "$noask/bin/$tool"; done
cfg="$tmp/cfg-noask"
inst "add installs a plugin for the never-asking control" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/probe.git"
g -C "$cfg/vgs/plugins/acme.probe" reset -q --hard HEAD~1
INST_BIN="$noask/bin/vgsh" inst "the never-asking mutant updates without a terminal" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin update acme.probe
g -C "$cfg/vgs/plugins/acme.probe" reset -q --hard HEAD~1
INST_BIN="$noask/bin/vgsh" on_terminal n plugin update acme.probe
check "the never-asking mutant updates on a terminal that answers no" test "$term_status" == 0
g -C "$cfg/vgs/plugins/acme.probe" reset -q --hard HEAD~1
on_terminal yes plugin update acme.probe
check "an update confirmed on a terminal succeeds" test "$term_status" == 0
check "a confirmed update fast-forwards to the source" test "$(head_of "$cfg/vgs/plugins/acme.probe")" == "$(head_of "$tmp/src/probe")"

cfg="$tmp/cfg-add"
inst "update --yes fast-forwards a new commit" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin update --yes acme.probe
check "update runs no post-merge hook" test ! -e "$hooks/post-merge.marker"
after="$(head_of "$plugin")"
check "update reports both commits" grep -qx "ok updated=acme.probe from=${before:0:12} to=${after:0:12}" "$tmp/out"
check "update prints the incoming diff" grep -q '^+.*"version": "0.2.0"' "$tmp/out"
check "update leaves the new version installed" json_is "$plugin/manifest.json" 'd["version"] == "0.2.0"'

printf 'local\n' >"$plugin/notes.txt"
inst "update refuses a checkout with an untracked file" "$cfg" "$rt_empty" 1 "" "vgsh: refused: modified=$plugin" plugin update acme.probe
rm -f -- "$plugin/notes.txt"

# A refused update still shows its diff first; its last line ends stdout.
diff_last() { local d; d="$(g -C "$tmp/src/probe" diff "$good" HEAD)" || return 1; printf '%s\n' "${d##*$'\n'}"; }
good="$(head_of "$plugin")"
source_commit probe "$(manifest acme.probe 0.3.0 ', "requires": []')"
inst "update refuses a new manifest the judge refuses" "$cfg" "$rt_empty" 1 "$(diff_last)" "vgsh: refused: manifest=acme.probe rolled-back=${good:0:12}" plugin update --yes acme.probe
check "a refused manifest rolls the checkout back" test "$(head_of "$plugin")" == "$good"
check "a refused manifest leaves the accepted version in place" json_is "$plugin/manifest.json" 'd["version"] == "0.2.0"'
source_commit probe "$(manifest acme.renamed 0.3.0)"
inst "update refuses a new manifest naming another id" "$cfg" "$rt_empty" 1 "$(diff_last)" "vgsh: refused: manifest-id=acme.renamed want=acme.probe rolled-back=${good:0:12}" plugin update --yes acme.probe
check "a renamed id rolls the checkout back" test "$(head_of "$plugin")" == "$good"

# Rewrite the installed commit itself, so the installed head is no ancestor.
g -C "$tmp/src/probe" reset -q --hard "$good"
g -C "$tmp/src/probe" commit -q --amend -m rewritten
g -C "$tmp/src/probe" push -q --force "$tmp/src/probe.git" main
inst "update refuses a source that rewrote its history" "$cfg" "$rt_empty" 1 "" "vgsh: refused: not-fast-forward=acme.probe" plugin update acme.probe
check "a refused rewrite leaves the checkout alone" test "$(head_of "$plugin")" == "$good"

cfg="$tmp/cfg-live"
source_commit probe "$(manifest acme.probe 0.4.0)"
inst "update rescans a running shell" "$cfg" "$rt_live" 0 "shell=rescan-started" "" plugin update --yes acme.probe

# A checkout add did not make: no .git, or a branch with no upstream. Each
# refusal names git's own cause after its key.
cfg="$tmp/cfg-nogit"
inst "add installs a plugin to break" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/probe.git"
rm -rf -- "${cfg:?}/vgs/plugins/acme.probe/.git"
inst "update refuses a plugin directory that is not a checkout" "$cfg" "$rt_empty" 1 "" "vgsh: refused: not-a-checkout=$cfg/vgs/plugins/acme.probe" plugin update acme.probe
check "the not-a-checkout refusal carries git's cause" grep -q '^fatal: not a git repository' "$tmp/err"
cfg="$tmp/cfg-noupstream"
inst "add installs a plugin to detach" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/probe.git"
g -C "$cfg/vgs/plugins/acme.probe" branch --unset-upstream
inst "update refuses a checkout with no upstream" "$cfg" "$rt_empty" 1 "" "vgsh: refused: upstream=missing path=$cfg/vgs/plugins/acme.probe" plugin update acme.probe
check "the upstream refusal carries git's cause" grep -q '^fatal: no upstream configured' "$tmp/err"

# Remove.
cfg="$tmp/cfg-add"
inst "remove refuses a bundled id" "$cfg" "$rt_empty" 1 "" "vgsh: refused: bundled=vgs.bar" plugin remove vgs.bar
inst "update refuses a bundled id" "$cfg" "$rt_empty" 1 "" "vgsh: refused: bundled=vgs.bar" plugin update vgs.bar
inst "update refuses --yes after the id" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=--yes" plugin update acme.probe --yes
inst "remove refuses an unknown id" "$cfg" "$rt_empty" 1 "" "vgsh: refused: unknown=acme.absent" plugin remove acme.absent
inst "remove refuses a path that leaves the plugin directory" "$cfg" "$rt_empty" 1 "" "vgsh: refused: outside=$cfg/vgs" plugin remove ..
inst "remove deletes the installed plugin" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin remove --yes acme.probe
check "remove leaves no plugin directory" test ! -e "$plugin"
cfg="$tmp/cfg-link"; mkdir -p "$cfg/vgs/plugins" "$tmp/elsewhere/acme.probe"
manifest acme.probe 0.1.0 >"$tmp/elsewhere/acme.probe/manifest.json"
ln -s "$tmp/elsewhere/acme.probe" "$cfg/vgs/plugins/acme.probe"
inst "remove refuses a symlinked plugin directory" "$cfg" "$rt_empty" 1 "" "vgsh: refused: symlink=$cfg/vgs/plugins/acme.probe" plugin remove acme.probe
check "a refused symlink leaves its target" test -f "$tmp/elsewhere/acme.probe/manifest.json"
# A plugin present under the user directory but not the way add lands one: a
# directory named differently from its id owns the id and is not installed;
# a directory named for the id whose manifest names another id is refused.
cfg="$tmp/cfg-misnamed"; mkdir -p "$cfg/vgs/plugins/elsewhere"
manifest acme.probe 0.1.0 >"$cfg/vgs/plugins/elsewhere/manifest.json"
inst "remove refuses a plugin whose directory is not named for its id" "$cfg" "$rt_empty" 1 "" "vgsh: refused: not-installed=acme.probe owner=$cfg/vgs/plugins/elsewhere" plugin remove acme.probe
cfg="$tmp/cfg-renamed"; mkdir -p "$cfg/vgs/plugins/acme.probe"
manifest acme.other 0.1.0 >"$cfg/vgs/plugins/acme.probe/manifest.json"
inst "remove refuses a directory whose manifest names another id" "$cfg" "$rt_empty" 1 "" "vgsh: refused: manifest-id=acme.other path=$cfg/vgs/plugins/acme.probe" plugin remove acme.probe
check "a refused id mismatch leaves the directory" test -f "$cfg/vgs/plugins/acme.probe/manifest.json"
cfg="$tmp/cfg-live"
inst "remove rescans a running shell" "$cfg" "$rt_live" 0 "shell=rescan-started" "" plugin remove --yes acme.probe
INST_REPLY=busy inst "add while a scan runs says the rescan is queued" "$cfg" "$rt_live" 0 "shell=rescan-queued" "" plugin add "$tmp/src/probe.git"

# Theme list and apply, against the tree copy theme_tree makes, holding one
# more shipped package. The targets directory beside the shipped packages
# is no package: the exact package rows below list none for it. $stubs'
# commands record a run and exit 1: detection never runs one. No
# application of the host is found, and the tree holds foot alone of the
# shipped targets.
theme_tree foot
for stub in foot vgs-probe-app; do
  printf '#!/bin/sh\n: >"%s/ran-$(basename "$0")"\nexit 1\n' "$tmp" >"$stubs/$stub"
  chmod +x "$stubs/$stub"
done
cfg="$tmp/cfg-theme"; themes="$cfg/vgs/themes"; file="$cfg/vgs/theme.json"
theme_pkg "$tree/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#111111" } } }'
# Key order and whitespace no serialiser writes, so only a byte copy keeps them.
theme_pkg "$themes/dusk" $'{"tokens" :{"palette":{"accent":"#222222"}},\n\n    "name":"dusk",   "schemaVersion":1}\n\n'
theme_pkg "$themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": {} }' "$(slots_json '#010203')"
theme_pkg "$themes/broken" '{ "schemaVersion": 1, "name": "other", "tokens": {} }'
theme_pkg "$themes/vgs" '{ "schemaVersion": 1, "name": "vgs", "tokens": { "palette": { "accent": "#333333" } } }'
# The shipped defaults sort last in every list here, with the table's palette.
vgs_row="theme=vgs source=shipped state=ok current=false palette=background:#000000ff,foreground:#d7d7d9ff,accent:#ff5a36ff,success:#b4c96fff,warning:#ffb000ff,danger:#f43f5eff,info:#74a7f7ff"

tinst "theme list succeeds with no theme file" "$cfg" "$rt_empty" 0 "$vgs_row" "" theme list
check "theme list reports an absent theme file as unmodified" has_line "file path=$file state=absent name=- modified=false"
check "an installed package is listed with its resolved palette" has_prefix "theme=dusk source=installed state=ok current=false palette=background:#000000ff,foreground:#d7d7d9ff,accent:#222222ff,"
check "an installed package shadows the shipped package of its name" has_line "theme=dusk source=shipped state=shadowed current=false"
check "a refused package is listed with its reason" has_line "theme=broken source=installed state=refused reason=name-mismatch current=false"
check "an installed vgs is refused for its reserved name" has_line "theme=vgs source=installed state=refused reason=reserved-name current=false"
tinst "theme list --json succeeds" "$cfg" "$rt_empty" 0 "$any_out" "" theme list --json
tail -n 1 "$tmp/out" >"$tmp/list.json"
check "theme list --json carries the same rows" json_is "$tmp/list.json" 'd["file"] == {"path": "'"$file"'", "state": "absent", "name": None, "modified": False} and [(p["name"], p["source"], p["state"], p["reason"]) for p in d["packages"]] == [("broken", "installed", "refused", "name-mismatch"), ("dusk", "installed", "ok", None), ("dusk", "shipped", "shadowed", None), ("light", "shipped", "ok", None), ("nord", "installed", "ok", None), ("vgs", "installed", "refused", "reserved-name"), ("vgs", "shipped", "ok", None)] and d["packages"][1]["palette"]["accent"] == "#222222ff" and d["packages"][2]["palette"] is None'

tinst "theme apply takes the installed package over the shipped one" "$cfg" "$rt_empty" 0 "ok theme=dusk state=applied shell=applied" "" theme apply dusk
check "apply copies the package's theme.json to the theme file byte for byte" cmp -s "$themes/dusk/theme.json" "$file"
check "apply renders the package's theme.json into the state directory" cmp -s "$themes/dusk/theme.json" "$state/theme/theme.json"
check "a package without terminal.json takes the shipped vgs slots" cmp -s "$repo/themes/vgs/terminal.json" "$state/theme/terminal.json"
check "apply writes theme.name" test "$(cat "$state/theme.name")" == dusk
check "the swap leaves no next-theme/ behind" test ! -e "$state/next-theme"
tinst "theme list after an apply" "$cfg" "$rt_empty" 0 "$vgs_row" "" theme list
check "the byte copy reads back as the named package, unmodified" has_line "file path=$file state=loaded name=dusk modified=false"
check "the applied package is the file's named theme" has_prefix "theme=dusk source=installed state=ok current=true "
tinst "applying the file's own package again changes nothing" "$cfg" "$rt_empty" 0 "ok theme=dusk state=unchanged shell=unchanged" "" theme apply dusk
printf '\n' >>"$file"
tinst "theme list after a hand edit" "$cfg" "$rt_empty" 0 "$any_out" "" theme list --json
tail -n 1 "$tmp/out" >"$tmp/list.json"
check "a hand edit of the theme file reports it modified" json_is "$tmp/list.json" 'd["file"]["state"] == "loaded" and d["file"]["name"] == "dusk" and d["file"]["modified"] is True'

tinst "theme apply --json prints the structured result" "$cfg" "$rt_empty" 0 '{"state":"applied","shell":"applied","targets":[{"name":"foot","state":"skipped","reason":"not-detected","dropped":[]}],"theme":"nord","reason":null}' "" theme apply --json nord
check "a package's own terminal.json is rendered as it is" cmp -s "$themes/nord/terminal.json" "$state/theme/terminal.json"

# A stage a crashed apply left behind is removed, never carried into theme/.
mkdir -p "$state/next-theme"; : >"$state/next-theme/stale"
tinst "theme apply vgs restores the shipped defaults over a reserved installed vgs" "$cfg" "$rt_empty" 0 "ok theme=vgs state=applied shell=applied" "" theme apply vgs
check "apply vgs writes the shipped defaults' bytes" cmp -s "$repo/themes/vgs/theme.json" "$file"
check "apply vgs writes theme.name vgs" test "$(cat "$state/theme.name")" == vgs
check "apply removes a stale next-theme/" test ! -e "$state/next-theme"
check "the state directory's theme/ holds the two rendered files and nothing stale" test "$(find "$state/theme" -mindepth 1 -printf '%f\n' | sort | tr '\n' ' ')" == "terminal.json theme.json "

tinst "theme apply refuses a refused package" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=broken reason=name-mismatch path=$themes/broken" theme apply broken
tinst "theme apply --json prints a refusal's result" "$cfg" "$rt_empty" 1 '{"state":"failed","shell":"unchanged","targets":[],"theme":"broken","reason":"name-mismatch"}' "vgsh: refused: theme=broken reason=name-mismatch path=$themes/broken" theme apply --json broken
tinst "theme apply refuses an unknown name" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=absent reason=unknown" theme apply absent
tinst "theme apply refuses a name that is no directory name" "$cfg" "$rt_empty" 1 "" 'vgsh: refused: theme="../dusk" reason=malformed-name' theme apply ../dusk
check "refused applies leave the theme file alone" cmp -s "$repo/themes/vgs/theme.json" "$file"
tinst "theme apply without a name is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: name=missing" theme apply
tinst "theme apply with a second name is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=nord" theme apply dusk nord
tinst "theme list with an argument is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=dusk" theme list dusk
tinst "an unknown theme subcommand is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: theme-subcommand=frobnicate" theme frobnicate

# The lock: held here the way a concurrent apply holds it.
lockfile="$cfg/vgs/theme.lock"
check "apply leaves the theme lock file in place" test -f "$lockfile"
exec 7>>"$lockfile"
flock 7
tinst "a concurrent theme apply is refused as busy" "$cfg" "$rt_empty" 75 '{"state":"failed","shell":"unchanged","targets":[],"theme":"dusk","reason":"busy"}' "vgsh: refused: theme=dusk reason=busy" theme apply --json dusk
check "a busy apply leaves the theme file alone" cmp -s "$repo/themes/vgs/theme.json" "$file"
# The must-fail control: a copy of vgsh that never takes the lock applies
# under the held lock.
mutant="$tmp/tree-nolock"; cp -R -- "$tree" "$mutant"
take='flock -n -E 75 9 || status=$?'
check "the theme lock is taken once in bin/vgsh" test "$(grep -o -F -- "$take" "$repo/bin/vgsh" | wc -l)" == 1
sed -i "s/$take/true/" "$mutant/bin/vgsh"
check "the lockless mutant differs from bin/vgsh" test "$(cmp -s "$repo/bin/vgsh" "$mutant/bin/vgsh"; echo $?)" == 1
THEME_BIN="$mutant/bin/vgsh" tinst "the lockless mutant applies while the lock is held" "$cfg" "$rt_empty" 0 "ok theme=dusk state=applied shell=applied" "" theme apply dusk
exec 7>&-
cfg_ro="$tmp/cfg-theme-ro"; mkdir -p "$cfg_ro/vgs"; chmod 500 "$cfg_ro/vgs"
tinst "theme apply refuses when the lock file cannot be made" "$cfg_ro" "$rt_empty" 1 "" "vgsh: refused: theme=vgs reason=lock-failed path=$cfg_ro/vgs/theme.lock" theme apply vgs
chmod 700 "$cfg_ro/vgs"

# The byte copy's must-fail control: a judge copy that re-serialises the
# document reports its own apply as modified.
mutant="$tmp/tree-reserialise"; cp -R -- "$tree" "$mutant"
copy='replaceFile(file.path, row.files.theme, key);'
check "the theme file is written once in bin/vgsh-theme-judge" test "$(grep -o -F -- "$copy" "$repo/bin/vgsh-theme-judge" | wc -l)" == 1
sed -i "s/$copy/replaceFile(file.path, JSON.stringify(JSON.parse(row.files.theme)), key);/" "$mutant/bin/vgsh-theme-judge"
check "the re-serialising mutant differs from bin/vgsh-theme-judge" test "$(cmp -s "$repo/bin/vgsh-theme-judge" "$mutant/bin/vgsh-theme-judge"; echo $?)" == 1
cfg="$tmp/cfg-theme-mutant"; mkdir -p "$cfg/vgs"; cp -R -- "$themes" "$cfg/vgs/themes"
THEME_BIN="$mutant/bin/vgsh" tinst "the re-serialising mutant applies" "$cfg" "$rt_empty" 0 "ok theme=dusk state=applied shell=applied" "" theme apply dusk
tinst "theme list after the mutant's apply" "$cfg" "$rt_empty" 0 "$vgs_row" "" theme list
check "the re-serialising mutant's apply reads back as modified" has_line "file path=$cfg/vgs/theme.json state=loaded name=dusk modified=true"

# The file's state, read from disk with the shell's own judge.
cfg="$tmp/cfg-theme-file"; file="$cfg/vgs/theme.json"; mkdir -p "$cfg/vgs"
printf '{ "schemaVersion": 1, "name": "mine", "tokens": {} }\n' >"$file"
tinst "theme list with a file no package names" "$cfg" "$rt_empty" 0 "$vgs_row" "" theme list
check "a file naming no package is loaded and modified" has_line "file path=$file state=loaded name=mine modified=true"
printf '{ "schemaVersion": 1, "name": "vgs", "tokens": { "palette": { "acent": "#fff" } } }\n' >"$file"
tinst "theme list with a refused file" "$cfg" "$rt_empty" 0 "$vgs_row" "" theme list
check "a file the judge refuses is refused and modified" has_line "file path=$file state=refused name=- modified=true"
chmod 000 "$file"
tinst "theme list with an unreadable file" "$cfg" "$rt_empty" 0 "$vgs_row" "" theme list
check "an unreadable file is unreadable and not compared" has_line "file path=$file state=unreadable name=- modified=null"
chmod 600 "$file"

# An installed vgs whose files cannot be read is still refused for its
# name, so it never hides the shipped defaults or their terminal slots.
cfg="$tmp/cfg-theme-locked"; themes="$cfg/vgs/themes"; file="$cfg/vgs/theme.json"
theme_pkg "$themes/vgs" '{ "schemaVersion": 1, "name": "vgs", "tokens": {} }'
theme_pkg "$themes/plain" '{ "schemaVersion": 1, "name": "plain", "tokens": {} }'
chmod 000 "$themes/vgs/theme.json"
tinst "theme list with an unreadable installed vgs" "$cfg" "$rt_empty" 0 "$vgs_row" "" theme list
check "an unreadable installed vgs is refused for its reserved name" has_line "theme=vgs source=installed state=refused reason=reserved-name current=false"
tinst "theme apply plain beside an unreadable installed vgs" "$cfg" "$rt_empty" 0 "ok theme=plain state=applied shell=applied" "" theme apply plain
check "a package without terminal.json takes the shipped vgs slots beside an unreadable installed vgs" cmp -s "$repo/themes/vgs/terminal.json" "$state/theme/terminal.json"
tinst "theme apply vgs beside an unreadable installed vgs" "$cfg" "$rt_empty" 0 "ok theme=vgs state=applied shell=applied" "" theme apply vgs
check "apply vgs beside an unreadable installed vgs writes the shipped defaults' bytes" cmp -s "$repo/themes/vgs/theme.json" "$file"
chmod 600 "$themes/vgs/theme.json"

# A state directory apply cannot write refuses with the structured result
# and the keyed line, never an fs exception from the stage's cleanup. foot is
# disabled, so no carried file is read from theme/ before the stage.
printf '{ "disabledTargets": ["foot"] }\n' >"$cfg/vgs/shell.json"
chmod 500 "$state"
tinst "theme apply --json refuses a state directory it cannot write" "$cfg" "$rt_empty" 1 '{"state":"failed","shell":"unchanged","targets":[],"theme":"plain","reason":"unwritable"}' "vgsh: refused: theme=plain reason=unwritable path=$state/next-theme error=EACCES" theme apply --json plain
chmod 700 "$state"
check "the unwritable refusal is its one stderr line" test "$(wc -l <"$tmp/err")" == 1
check "an unwritable state directory leaves the theme file alone" cmp -s "$repo/themes/vgs/theme.json" "$file"
# An undetected foot carries what it landed before, so a theme/ that cannot
# be listed refuses the apply before anything moves.
printf '{}\n' >"$cfg/vgs/shell.json"
chmod 000 "$state/theme"
tinst "theme apply --json refuses a theme/ it cannot list for a carried target" "$cfg" "$rt_empty" 1 '{"state":"failed","shell":"unchanged","targets":[],"theme":"plain","reason":"unreadable"}' "vgsh: refused: theme=plain reason=unreadable path=$state/theme error=EACCES" theme apply --json plain
chmod 700 "$state/theme"

# Theme add, update and remove, from local bare repositories as the plugin
# rows install, against the tree copy, whose shipped `dusk` an installed
# package can shadow. The fixture home's hooks stay live.
unstaged() { test -z "$(find "$1/vgs" -maxdepth 1 -name '.vgsh-theme-add.*' -print)"; }
src="$tmp/tsrc"
theme_source moss "$(doc moss)"
theme_source dusk "$(doc dusk '{ "palette": { "accent": "#444444" } }')"
theme_source fern "$(doc fern)"
theme_source slotty "$(doc slotty)" "$(slots_json '#nothex')"
theme_source reserved "$(doc vgs)"
theme_source targets "$(doc targets)"
theme_source catalog "$(doc catalog)"
theme_source thumbnails "$(doc thumbnails)"
theme_source spaced "$(doc 'My Theme')"
theme_source typo "$(doc typo '{ "palette": { "acent": "#ffffff" } }')"
theme_source bare ""

cfg="$tmp/cfg-theme-add"; themes="$cfg/vgs/themes"; moss="$themes/moss"
tinst "theme add installs a package under its document's name" "$cfg" "$rt_empty" 0 "ok added=moss path=$moss" "" theme add "$src/moss.git"
check "theme add runs no post-checkout hook" test ! -e "$hooks/post-checkout.marker"
check "theme add lands the package's files" cmp -s "$src/moss/theme.json" "$moss/theme.json"
check "theme add leaves no staging directory" unstaged "$cfg"
tinst "theme list after an add" "$cfg" "$rt_empty" 0 "$vgs_row" "" theme list
check "the added package is listed as installed and accepted" has_prefix "theme=moss source=installed state=ok current=false "
tinst "theme add of a shipped package's name shadows it" "$cfg" "$rt_empty" 0 "ok added=dusk path=$themes/dusk shadows=$tree/themes/dusk" "" theme add "$src/dusk.git"
tinst "theme list after a shadowing add" "$cfg" "$rt_empty" 0 "$vgs_row" "" theme list
check "the shipped package an add shadows is listed shadowed" has_line "theme=dusk source=shipped state=shadowed current=false"
tinst "theme add refuses a name an installed package holds" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=moss reason=exists path=$moss" theme add "$src/moss.git"
check "a refused occupied name leaves no staging directory" unstaged "$cfg"

# Every refusal before landing leaves no staging directory and no package.
cfg="$tmp/cfg-theme-refused"
while IFS='|' read -r name source want; do
  tinst "theme add refuses $name" "$cfg" "$rt_empty" 1 "" "vgsh: refused: $want" theme add "$src/$source" </dev/null
  check "theme add of $name leaves nothing behind" test -z "$(find "$cfg/vgs" -mindepth 1 -maxdepth 2 \( -name '.vgsh-theme-add.*' -o -path "$cfg/vgs/themes/*" \) -print)"
done <<EOF
a package the judge refuses|slotty.git|package=$src/slotty.git reason=terminal-colour token=terminal.color0 value="#nothex"
a document the judge refuses|typo.git|package=$src/typo.git reason=unknown-token token=palette.acent
the reserved name vgs|reserved.git|package=$src/reserved.git reason=reserved-name name=vgs
the targets directory's name|targets.git|package=$src/targets.git reason=reserved-name name=targets
the catalog directory's name|catalog.git|package=$src/catalog.git reason=reserved-name name=catalog
the thumbnails directory's name|thumbnails.git|package=$src/thumbnails.git reason=reserved-name name=thumbnails
a document name that is no directory name|spaced.git|package=$src/spaced.git reason=package-name got="My Theme"
a source without theme.json|bare.git|package=$src/bare.git reason=absent file=theme.json
an unreachable source|absent.git|clone=$src/absent.git
EOF
tinst "theme add without a url is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: url=missing" theme add
tinst "theme add with a second url is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=x" theme add "$src/fern.git" x
tinst "theme add --json is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=--json" theme add --json "$src/fern.git"

# Update against the package the first add row installed.
cfg="$tmp/cfg-theme-add"
tinst "theme update with nothing new is up to date" "$cfg" "$rt_empty" 0 "ok up-to-date=moss" "" theme update moss

# No git call inherits the theme lock's descriptor, since a gc git detaches
# would hold the lock after vgsh exits. A git first on PATH that records
# whether descriptor 9 is open stands in for that gc; the must-fail control
# is a vgsh copy whose git calls keep the descriptor.
spy="$tmp/git-spy"; mkdir -p "$spy"
real_git="$(command -v git)" || { fail "git resolves on PATH"; real_git=git; }
printf '#!/bin/sh\n: >"%s/ran"\n[ -e /proc/self/fd/9 ] && : >"%s/fd9-open"\nexec "%s" "$@"\n' "$spy" "$spy" "$real_git" >"$spy/git"
chmod +x "$spy/git"
spied_update() { # VGSH
  rm -f -- "$spy/ran" "$spy/fd9-open"
  "${base_env[@]}" PATH="$spy:$tmp:$(dirname -- "$node_bin"):$PATH" XDG_CONFIG_HOME="$cfg" XDG_RUNTIME_DIR="$rt_empty" "$1" theme update moss >/dev/null 2>&1
}
closing='"$@" 9>&-; }'
check "git calls close the lock descriptor once in bin/vgsh" test "$(grep -o -F -- "$closing" "$repo/bin/vgsh" | wc -l)" == 1
check "a spied update succeeds" spied_update "$tree/bin/vgsh"
check "the spied update ran git through the spy" test -e "$spy/ran"
check "no git call of an update holds descriptor 9" test ! -e "$spy/fd9-open"
mutant="$tmp/tree-git-keeps-lock"; cp -R -- "$tree" "$mutant"
sed -i "s/ 9>&-; }/; }/" "$mutant/bin/vgsh"
check "the descriptor-keeping mutant differs from bin/vgsh" test "$(cmp -s "$repo/bin/vgsh" "$mutant/bin/vgsh"; echo $?)" == 1
spied_update "$mutant/bin/vgsh" || true
check "the descriptor-keeping mutant's git holds descriptor 9" test -e "$spy/fd9-open"
before="$(head_of "$moss")"
theme_commit moss theme.json "$(doc moss '{ "palette": { "accent": "#123456" } }')"
after="$(head_of "$src/moss")"
tinst "theme update without a terminal refuses after the diff" "$cfg" "$rt_empty" 1 "$any_out" "vgsh: refused: no-terminal=moss" theme update moss
check "an unconfirmed theme update leaves the checkout at its commit" test "$(head_of "$moss")" == "$before"
tinst "theme update --yes fast-forwards a new commit" "$cfg" "$rt_empty" 0 "ok follow=none theme=- state=unchanged" "" theme update --yes moss
check "theme update reports both commits" has_line "ok updated=moss from=${before:0:12} to=${after:0:12}"
check "theme update runs no post-merge hook" test ! -e "$hooks/post-merge.marker"
check "theme update prints the incoming diff" grep -q '^+.*#123456' "$tmp/out"
check "theme update leaves the new version installed" cmp -s "$src/moss/theme.json" "$moss/theme.json"

printf 'local\n' >"$moss/notes.txt"
tinst "theme update refuses a checkout with an untracked file" "$cfg" "$rt_empty" 1 "" "vgsh: refused: modified=$moss" theme update moss
rm -f -- "$moss/notes.txt"
good="$(head_of "$moss")"
theme_commit moss terminal.json "$(slots_json '#nothex')"
tinst "theme update refuses a new version the judge refuses" "$cfg" "$rt_empty" 1 "$any_out" "vgsh: refused: theme=moss reason=terminal-colour token=terminal.color0 value=\"#nothex\" rolled-back=${good:0:12}" theme update --yes moss
check "a refused version rolls the checkout back" test "$(head_of "$moss")" == "$good"
check "a refused version leaves no file of it" test ! -e "$moss/terminal.json"
theme_commit moss terminal.json "$(slots_json '#010203')"
theme_commit moss theme.json "$(doc renamed)"
tinst "theme update refuses a new version naming another package" "$cfg" "$rt_empty" 1 "$any_out" "vgsh: refused: theme=moss reason=name-mismatch directory=moss document=renamed rolled-back=${good:0:12}" theme update --yes moss
check "a renamed package rolls the checkout back" test "$(head_of "$moss")" == "$good"
g -C "$src/moss" reset -q --hard "$good"
g -C "$src/moss" commit -q --amend -m rewritten
g -C "$src/moss" push -q --force "$src/moss.git" main
tinst "theme update refuses a source that rewrote its history" "$cfg" "$rt_empty" 1 "" "vgsh: refused: not-fast-forward=moss" theme update moss
check "a refused rewrite leaves the checkout alone" test "$(head_of "$moss")" == "$good"

tinst "theme update refuses a shipped package" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=vgs reason=shipped path=$tree/themes/vgs" theme update vgs
tinst "theme update refuses an unknown name" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=absent reason=unknown" theme update absent
tinst "theme update refuses a name that is no directory name" "$cfg" "$rt_empty" 1 "" 'vgsh: refused: theme="../moss" reason=malformed-name' theme update ../moss
tinst "theme update refuses the targets directory" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=targets reason=reserved-name" theme update targets
tinst "theme update refuses the catalog directory" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=catalog reason=reserved-name" theme update catalog
tinst "theme update refuses the thumbnails directory" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=thumbnails reason=reserved-name" theme update thumbnails
# The must-fail control: a judge copy that reserves only targets takes the
# catalog for an unknown package.
judge_control catalog-unreserved 'if (logic.RESERVED_DIRECTORIES.includes(name)) refuse(' 'if (name === TARGETS) refuse('
tinst "the catalog-unreserved mutant does not refuse the catalog as reserved" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=catalog reason=unknown" theme update catalog
unset THEME_BIN
tinst "theme update without a name is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: name=missing" theme update

# The lock, held the way a running apply holds it: add, update and remove
# each refuse busy and change nothing.
exec 7>>"$cfg/vgs/theme.lock"
flock 7
tinst "theme add while the theme lock is held is refused as busy" "$cfg" "$rt_empty" 75 "" "vgsh: refused: theme=fern reason=busy" theme add "$src/fern.git"
check "a busy add lands nothing" test ! -e "$themes/fern"
check "a busy add leaves no staging directory" unstaged "$cfg"
tinst "theme update while the theme lock is held is refused as busy" "$cfg" "$rt_empty" 75 "" "vgsh: refused: theme=moss reason=busy" theme update moss
tinst "theme remove while the theme lock is held is refused as busy" "$cfg" "$rt_empty" 75 "" "vgsh: refused: theme=moss reason=busy" theme remove moss
check "a busy remove leaves the package" test -f "$moss/theme.json"
# The must-fail control: a copy of vgsh whose install verbs never take the
# lock removes the package under the held lock.
mutant="$tmp/tree-install-nolock"; cp -R -- "$tree" "$mutant"
take='flock "${@:2}" -n -E 75 9 || rc=$?'
check "the install verbs take the theme lock once in bin/vgsh" test "$(grep -o -F -- "$take" "$repo/bin/vgsh" | wc -l)" == 1
sed -i "s/$take/true/" "$mutant/bin/vgsh"
check "the install lockless mutant differs from bin/vgsh" test "$(cmp -s "$repo/bin/vgsh" "$mutant/bin/vgsh"; echo $?)" == 1
cfg_mutant="$tmp/cfg-theme-install-mutant"; mkdir -p "$cfg_mutant/vgs"; cp -R -- "$themes" "$cfg_mutant/vgs/themes"
exec 6>>"$cfg_mutant/vgs/theme.lock"
flock 6
THEME_BIN="$mutant/bin/vgsh" tinst "the install lockless mutant removes under the held lock" "$cfg_mutant" "$rt_empty" 0 "ok removed=moss" "" theme remove moss
exec 6>&-
exec 7>&-

# Remove.
cfg_link="$tmp/cfg-theme-link"; mkdir -p "$cfg_link/vgs/themes" "$tmp/elsewhere-theme/moss"
doc moss >"$tmp/elsewhere-theme/moss/theme.json"
ln -s "$tmp/elsewhere-theme/moss" "$cfg_link/vgs/themes/moss"
: >"$cfg_link/vgs/themes/plain-file"
tinst "theme remove refuses a symlinked package directory" "$cfg_link" "$rt_empty" 1 "" "vgsh: refused: theme=moss reason=symlink path=$cfg_link/vgs/themes/moss" theme remove moss
check "a refused symlink leaves its target" test -f "$tmp/elsewhere-theme/moss/theme.json"
tinst "theme remove refuses a file that is no package directory" "$cfg_link" "$rt_empty" 1 "" "vgsh: refused: theme=plain-file reason=not-a-directory path=$cfg_link/vgs/themes/plain-file" theme remove plain-file
tinst "theme remove refuses a shipped package" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=vgs reason=shipped path=$tree/themes/vgs" theme remove vgs
tinst "theme remove deletes a shadowing package" "$cfg" "$rt_empty" 0 "ok removed=dusk" "" theme remove dusk
tinst "theme list after removing a shadowing package" "$cfg" "$rt_empty" 0 "$vgs_row" "" theme list
check "removing a shadowing package uncovers the shipped one" has_prefix "theme=dusk source=shipped state=ok current=false "
theme_pkg "$themes/vgs" "$(doc vgs)"
tinst "theme remove deletes an installed vgs, which hides nothing" "$cfg" "$rt_empty" 0 "ok removed=vgs" "" theme remove vgs
check "removing an installed vgs leaves the shipped defaults" test -f "$tree/themes/vgs/theme.json" -a ! -e "$themes/vgs"
tinst "theme remove deletes the installed package" "$cfg" "$rt_empty" 0 "ok removed=moss" "" theme remove moss
check "theme remove leaves no package directory" test ! -e "$moss"
tinst "theme remove refuses a removed package as unknown" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=moss reason=unknown" theme remove moss

# Targets in the apply: the shipped foot target, detected, and fixture
# targets beside it in the tree copy. `fails` names no token, `off` is
# listed in disabledTargets and `probe` wires a file it never creates.
# `dusk` has no terminal.json, so every slot is the shipped vgs slot: color1 is #f43f5e.
cfg="$tmp/cfg-targets"; file="$cfg/vgs/theme.json"; live="$state/theme"
mkdir -p "$cfg/vgs"; cp -R -- "$tmp/cfg-theme/vgs/themes" "$cfg/vgs/themes"
printf '{ "disabledTargets": ["off"] }\n' >"$cfg/vgs/shell.json"
target_dir probe "$(target_json probe hex8 '["vgs-probe-app"]' 'source = @{state}/probe.conf' false)" $'accent=@{palette.accent} slot1=@{terminal.color1}\n'
target_dir fails "$(target_json fails hex6 '[]' 'include=@{state}/fails.conf' true)" 'x=@{palette.nope}'
target_dir off "$(target_json off hex6 '[]' 'include=@{state}/off.conf' true)" 'x=@{palette.accent}'
with_stubs="$stubs:$theme_path"
foot_line="include=$live/foot.ini"

THEME_PATH="$with_stubs" tinst "an apply a target fails in is partial with exit 3" "$cfg" "$rt_empty" 3 '{"state":"partial","shell":"applied","targets":[{"name":"fails","state":"failed","reason":"placeholder","dropped":[]},{"name":"foot","state":"written","reason":null,"dropped":[]},{"name":"off","state":"skipped","reason":"disabled","dropped":[]},{"name":"probe","state":"skipped","reason":"wiring-file-absent","dropped":[]}],"theme":"dusk","reason":null}' 'vgsh: refused: target=fails reason=placeholder template=fails.conf placeholder="palette.nope"' theme apply --json dusk
check "the partial apply's shell took the theme" cmp -s "$cfg/vgs/themes/dusk/theme.json" "$file"
check "foot's file lands in the state directory with the hex6 encoder" grep -qxF 'urls=222222' "$live/foot.ini"
check "foot's file takes the shipped slots" grep -qxF 'regular1=f43f5e' "$live/foot.ini"
check "only the landed target's file is in theme/" test "$(find "$live" -mindepth 1 -printf '%f\n' | sort | tr '\n' ' ')" == "foot.ini terminal.json theme.json "
check "an absent foot.ini is created holding the include line" test "$(cat "$cfg/foot/foot.ini")" == "$foot_line"
check "a failed, disabled or unwired target writes no application file" test ! -e "$cfg/fails" -a ! -e "$cfg/off" -a ! -e "$cfg/probe"

# A dotfile manager's link: the configuration file is a symlink into another
# tree, and the edit goes through it.
mkdir -p "$tmp/dotfiles" "$cfg/probe"
printf '[general]\nx=1\n' >"$tmp/dotfiles/probe.conf"; chmod 640 "$tmp/dotfiles/probe.conf"
ln -s -- "$tmp/dotfiles/probe.conf" "$cfg/probe/probe.conf"
rm -r -- "$tree/themes/targets/fails"
THEME_PATH="$with_stubs" tinst "a wired probe lands and unchanged foot bytes stay unchanged" "$cfg" "$rt_empty" 0 '{"state":"applied","shell":"unchanged","targets":[{"name":"foot","state":"unchanged","reason":null,"dropped":[]},{"name":"off","state":"skipped","reason":"disabled","dropped":[]},{"name":"probe","state":"written","reason":null,"dropped":[]}],"theme":"dusk","reason":null}' "" theme apply --json dusk
check "the probe's file is rendered with the hex8 encoder" test "$(cat "$live/probe.conf")" == "accent=222222ff slot1=f43f5eff"
check "the wiring edits a symlinked file through its link" test -L "$cfg/probe/probe.conf"
check "the include line goes first and the file's own text is kept" test "$(cat "$tmp/dotfiles/probe.conf")" == "source = $live/probe.conf"$'\n[general]\nx=1'
check "the edited file keeps its mode" test "$(stat -c %a "$tmp/dotfiles/probe.conf")" == 640

# A hand edit that drops the include line is repaired though no byte of the
# theme changed.
printf '[main]\nfont=x\n' >"$cfg/foot/foot.ini"
THEME_PATH="$with_stubs" tinst "an apply with unchanged bytes is unchanged" "$cfg" "$rt_empty" 0 "ok theme=dusk state=unchanged shell=unchanged" "" theme apply dusk
check "text mode prints one line per target" has_line "target=foot state=unchanged"
check "the wiring is asserted on unchanged bytes" test "$(cat "$cfg/foot/foot.ini")" == "$foot_line"$'\n[main]\nfont=x'
THEME_PATH="$with_stubs" tinst "a wired file is not written again" "$cfg" "$rt_empty" 0 "ok theme=dusk state=unchanged shell=unchanged" "" theme apply dusk
check "the include line is kept once" test "$(grep -cxF -- "$foot_line" "$cfg/foot/foot.ini")" == 1
check "detection never ran a detected command" test -z "$(find "$tmp" -maxdepth 1 -name 'ran-*' -print)"

printf '{ "disabledTargets": "off" }\n' >"$cfg/vgs/shell.json"
tinst "a user file the config judge refuses refuses the apply" "$cfg" "$rt_empty" 1 '{"state":"failed","shell":"unchanged","targets":[],"theme":"dusk","reason":"malformed"}' "vgsh: refused: theme=dusk reason=malformed path=$cfg/vgs/shell.json error=disabledTargets must be a list" theme apply --json dusk
inst "plugin add refuses the same malformed user file" "$cfg" "$rt_empty" 1 "" "vgsh: refused: user-config=malformed path=$cfg/vgs/shell.json error=disabledTargets must be a list" plugin add "$tmp/src/probe.git"
printf '{ "disabledTargets": ["off"] }\n' >"$cfg/vgs/shell.json"

# Must-fail controls: a copy of the shared file helper, bin/lib/judge-files.js,
# that replaces the symlink instead of the file it names, and a judge copy
# that wires written targets only.
ln -sfn -- "$tmp/dotfiles/probe.conf" "$cfg/probe/probe.conf"
tree_control symlink bin/lib/judge-files.js 'real = fs.realpathSync(file);' 'real = file;'
printf 'x=1\n' >"$tmp/dotfiles/probe.conf"
THEME_PATH="$with_stubs" tinst "the symlink-replacing mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the symlink-replacing mutant breaks the link" test ! -L "$cfg/probe/probe.conf"
printf '[main]\n' >"$cfg/foot/foot.ini"
judge_control written-only 'entry.state === "written" || entry.state === "unchanged" ? wire(' 'entry.state === "written" ? wire('
THEME_PATH="$with_stubs" tinst "the written-only mutant applies unchanged bytes" "$cfg" "$rt_empty" 0 "ok theme=dusk state=unchanged shell=unchanged" "" theme apply dusk
check "the written-only mutant leaves the dropped include line out" test "$(cat "$cfg/foot/foot.ini")" == "[main]"
unset THEME_BIN

# A landed target that then fails to render carries the file it landed, so
# its include line keeps naming a file; the apply is partial. nord's accent
# differs from dusk's, so a render would have changed the bytes.
probe_template=$'accent=@{palette.accent} slot1=@{terminal.color1}\n'
probe_error='vgsh: refused: target=probe reason=placeholder template=probe.conf placeholder="palette.nope"'
cp -- "$live/probe.conf" "$tmp/probe-landed"
printf 'x=@{palette.nope}' >"$tree/themes/targets/probe/probe.conf"
THEME_PATH="$with_stubs" tinst "a landed target that fails to render is partial" "$cfg" "$rt_empty" 3 "$any_out" "$probe_error" theme apply --json nord
tail -n 1 "$tmp/out" >"$tmp/apply.json"
check "the failing target is failed beside a written foot" json_is "$tmp/apply.json" 'd["state"] == "partial" and [(t["name"], t["state"], t["reason"]) for t in d["targets"]] == [("foot", "written", None), ("off", "skipped", "disabled"), ("probe", "failed", "placeholder")]'
check "the failing target's landed file is carried into theme/ byte for byte" cmp -s "$tmp/probe-landed" "$live/probe.conf"
check "the failing target's include line stays" grep -qxF "source = $live/probe.conf" "$cfg/probe/probe.conf"
# The must-fail control: a judge copy that carries nothing drops the file.
judge_control no-carry 'return Object.assign({}, entry, { files: landedFiles(live, entry.name, key) });' 'return entry;'
THEME_PATH="$with_stubs" tinst "the no-carry mutant applies" "$cfg" "$rt_empty" 3 "$any_out" "$probe_error" theme apply dusk
check "the no-carry mutant drops the failing target's landed file" test ! -e "$live/probe.conf"
unset THEME_BIN
printf '%s' "$probe_template" >"$tree/themes/targets/probe/probe.conf"

# A target disabled after it landed: its include line leaves the file in
# place, through a symlink with its mode, the rest kept byte for byte, and
# its file leaves theme/.
printf '# mine\n[main]\nfont=x' >"$tmp/dotfiles/foot.ini"; chmod 640 "$tmp/dotfiles/foot.ini"
cp -- "$tmp/dotfiles/foot.ini" "$tmp/foot-own"
ln -sfn -- "$tmp/dotfiles/foot.ini" "$cfg/foot/foot.ini"
disable_foot() { printf '{ "disabledTargets": [%s] }\n' "$1" >"$cfg/vgs/shell.json"; }
THEME_PATH="$with_stubs" tinst "foot lands through a symlinked foot.ini" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
check "the symlinked foot.ini takes the include line first" test "$(head -n 1 "$tmp/dotfiles/foot.ini")" == "$foot_line"
disable_foot '"off", "foot"'
THEME_PATH="$with_stubs" tinst "an apply with foot disabled after it landed" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json dusk
tail -n 1 "$tmp/out" >"$tmp/apply.json"
check "the disabled foot is skipped" json_is "$tmp/apply.json" '[t for t in d["targets"] if t["name"] == "foot"] == [{"name": "foot", "state": "skipped", "reason": "disabled", "dropped": []}]'
check "disabling foot removes its include line and keeps the rest byte for byte" cmp -s "$tmp/foot-own" "$tmp/dotfiles/foot.ini"
check "the unwired foot.ini stays a symlink" test -L "$cfg/foot/foot.ini"
check "the unwired foot.ini keeps its mode" test "$(stat -c %a "$tmp/dotfiles/foot.ini")" == 640
check "a disabled foot's file leaves theme/" test ! -e "$live/foot.ini"
# A removal that cannot be written keeps the line and carries the file.
disable_foot '"off"'
THEME_PATH="$with_stubs" tinst "foot lands again once enabled" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
cp -- "$live/foot.ini" "$tmp/foot-landed"
disable_foot '"off", "foot"'
chmod 500 "$tmp/dotfiles"
THEME_PATH="$with_stubs" tinst "an unwritable removal fails the disabled target" "$cfg" "$rt_empty" 3 "$any_out" "vgsh: refused: target=foot reason=unwritable path=$tmp/dotfiles/foot.ini error=EACCES" theme apply --json dusk
chmod 700 "$tmp/dotfiles"
tail -n 1 "$tmp/out" >"$tmp/apply.json"
check "the unremoved target is failed unwritable" json_is "$tmp/apply.json" 'd["state"] == "partial" and [t for t in d["targets"] if t["name"] == "foot"] == [{"name": "foot", "state": "failed", "reason": "unwritable", "dropped": []}]'
check "an unremoved include line keeps its file in theme/" cmp -s "$tmp/foot-landed" "$live/foot.ini"
check "an unremoved include line stays" grep -qxF -- "$foot_line" "$tmp/dotfiles/foot.ini"
# The must-fail control: a judge copy that never removes the line leaves it
# naming the file the swap drops.
judge_control keeps-line 'editWiring(name, target, configHome, live, render.unwiredText)' 'null'
THEME_PATH="$with_stubs" tinst "the line-keeping mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
check "the line-keeping mutant leaves the include line" grep -qxF -- "$foot_line" "$tmp/dotfiles/foot.ini"
check "the line-keeping mutant's line names a dropped file" test ! -e "$live/foot.ini"
unset THEME_BIN
disable_foot '"off"'

# --help prints the header comment of the script itself on stderr and exits
# 0; the expected first line is read from the script, not restated here.
set +e
help_out="$("${base_env[@]}" XDG_RUNTIME_DIR="$rt_empty" "$repo/bin/vgsh" --help 2>"$tmp/err")"
status=$?
set -e
help_first=""; IFS= read -r help_first <"$tmp/err" || true
want_first="$(sed -n '2{s/^# \{0,1\}//;p}' "$repo/bin/vgsh")"
if [[ $status == 0 && -z $help_out && -n $want_first && $help_first == "$want_first" ]]; then ok "help prints the script header on stderr and exits 0"; else fail "help: exit=$status stdout=[$help_out] first=[$help_first] want=[$want_first]"; fi

rows_done test-vgsh
