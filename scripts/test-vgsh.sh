#!/usr/bin/env bash
# Controls for bin/vgsh against a stub qs on PATH. Each row pins a reply,
# an exit status or a keyed refusal the header promises. No shell starts:
# `run` execs the stub, which records the identity it was handed.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp:?}"' EXIT

# The stub answers `qs ipc ... call <target> <fn> ...` from STUB_REPLY and
# STUB_STATUS, prints STUB_NOISE on stdout before the reply (as qs does with
# its log) and STUB_STDERR on stderr after it. Invoked as the shell (no
# `ipc` argument) it records its pid, VGSH_RUNNER_PID and its arguments in
# STUB_RECORD and exits 0.
cat >"$tmp/qs" <<'EOF2'
#!/usr/bin/env bash
if [[ ${1:-} != ipc && ${1:-} != log ]]; then
  printf 'pid=%s runner=%s args=%s\n' "$$" "${VGSH_RUNNER_PID:-unset}" "$*" >"${STUB_RECORD:?}"
  exit 0
fi
printf '%s\n' "$*" >"${STUB_ARGS:-/dev/null}"
[[ -n ${STUB_NOISE:-} ]] && printf '%s\n' "$STUB_NOISE"
printf '%s\n' "${STUB_REPLY:-ok}"
[[ -n ${STUB_STDERR:-} ]] && printf '%s\n' "$STUB_STDERR" >&2
exit "${STUB_STATUS:-0}"
EOF2
chmod +x "$tmp/qs"

# Every row runs with this environment and nothing else. The runtime dir
# holds the lock file; `live` names a lock file recording this process,
# which is alive, so the CLI addresses it.
rt_live="$tmp/rt-live"; mkdir -p "$rt_live"; printf '%s\n' "$$" >"$rt_live/vgsh.lock"
rt_empty="$tmp/rt-empty"; mkdir -p "$rt_empty"
base_env=(env -i PATH="$tmp:$PATH" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config")

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# rows: name | runtime dir | env | args | want stdout (last line) | want exit
run_row() { # NAME RT ENVSTR ARGS WANT_OUT WANT_EXIT
  local name="$1" rt="$2" envstr="$3" args="$4" want_out="$5" want_exit="$6" out status
  set +e
  # shellcheck disable=SC2086
  out="$("${base_env[@]}" XDG_RUNTIME_DIR="$rt" $envstr "$repo/bin/vgsh" $args 2>"$tmp/err")"
  status=$?
  set -e
  local last="${out##*$'\n'}"
  if [[ $status == "$want_exit" && $last == "$want_out" ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit last=[$last] want=[$want_out] stderr=$(head -n 1 "$tmp/err")"; fi
}

list_json='{"plugins":[{"id":"vgs.bar","version":"0.1.0","kinds":["bar"],"enabled":true,"dir":"/x"}],"errors":[],"collisions":[],"scanError":"","scanned":true}'

run_row "enable prints ok" "$rt_live" "STUB_REPLY=ok" "plugin enable vgs.clock" "ok" 0
run_row "reply is the last stdout line, log noise ahead of it is ignored" "$rt_live" "STUB_REPLY=ok STUB_NOISE=INFO:something" "plugin enable vgs.clock" "ok" 0
run_row "stderr after the reply does not become the reply" "$rt_live" "STUB_REPLY=ok STUB_STDERR=WARN:late" "plugin enable vgs.clock" "ok" 0
run_row "an unexpected reply is a refusal" "$rt_live" "STUB_REPLY=ok_hidden" "plugin disable vgs.bar" "" 1
run_row "a guard refusal from the shell is a refusal with exit 1" "$rt_live" "STUB_REPLY=refused:_guard=unowned" "plugin enable vgs.clock" "" 1
run_row "unknown id is a refusal with exit 1" "$rt_live" "STUB_REPLY=unknown:_x" "plugin enable x" "" 1
run_row "an ipc failure exits 69 on enable" "$rt_live" "STUB_STATUS=1 STUB_REPLY=none" "plugin enable vgs.clock" "" 69
run_row "an ipc failure exits 69 on list" "$rt_live" "STUB_STATUS=1 STUB_REPLY=none" "plugin list" "" 69
run_row "no lock file exits 69 without calling qs" "$rt_empty" "STUB_REPLY=ok" "plugin enable vgs.clock" "" 69
run_row "no lock file exits 69 on ipc" "$rt_empty" "STUB_REPLY=ok" "ipc call shell ping" "" 69
run_row "list formats one row per plugin" "$rt_live" "STUB_REPLY=$list_json" "plugin list" "vgs.bar                      0.1.0    enabled   kinds=bar" 0
run_row "missing id is exit 2" "$rt_live" "" "plugin enable" "" 2
run_row "unknown subcommand is exit 2" "$rt_live" "" "plugin frobnicate" "" 2
run_row "unknown command is exit 2" "$rt_live" "" "frobnicate" "" 2
run_row "run refuses an argument" "$rt_live" "STUB_RECORD=$tmp/never" "run --daemonize" "" 2
if [[ ! -e $tmp/never ]]; then ok "a refused run never started the shell"; else fail "a refused run started the shell"; fi

# The recorded pid must be a dead process for the not-running refusal, and
# a pid nothing can own is the one past the kernel's maximum.
rt_dead="$tmp/rt-dead"; mkdir -p "$rt_dead"; printf '%s\n' "$(( $(cat /proc/sys/kernel/pid_max) + 1 ))" >"$rt_dead/vgsh.lock"
run_row "a lock file naming a dead pid exits 69" "$rt_dead" "STUB_REPLY=ok" "plugin list" "" 69
rt_junk="$tmp/rt-junk"; mkdir -p "$rt_junk"; printf 'x\n' >"$rt_junk/vgsh.lock"
run_row "a lock file holding no pid exits 69" "$rt_junk" "STUB_REPLY=ok" "plugin list" "" 69

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
rt_run="$tmp/rt-run"; mkdir -p "$rt_run"
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
  if [[ "$(cat "$rt_run/vgsh.lock")" == "$pid" ]]; then ok "run records the shell's pid in the lock file"; else fail "lock file holds [$(cat "$rt_run/vgsh.lock")] want $pid"; fi
  if [[ $args == "-p $repo/shell" ]]; then ok "run passes qs the shell path and nothing else"; else fail "run args: $args"; fi
else
  fail "unlocked run: exit=$status record=$([[ -f $tmp/record ]] && echo present || echo absent) stderr=$(head -n 1 "$tmp/err")"
fi

rt_held="$tmp/rt-held"; mkdir -p "$rt_held"; printf '%s\n' "$$" >"$rt_held/vgsh.lock"
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

# Help ends with the last header line, not a stray shell line.
help_last="$("$repo/bin/vgsh" --help 2>&1 | tail -n 1)"
if [[ $help_last == *"69 when the shell is not running."* ]]; then ok "help ends with the exit-code line"; else fail "help last line: $help_last"; fi

if [[ $failures -gt 0 ]]; then echo "test-vgsh: failed=$failures"; exit 1; fi
echo "test-vgsh: ok"
