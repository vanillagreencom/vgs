#!/usr/bin/env bash
# Controls for vgs.updates/bin/check: required argv, concurrent probes and
# signal cleanup of probe process groups.
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
check="$repo/shell/plugins/vgs.updates/bin/check"
root="$repo/tmp/test-updates-check-$$"
rm -rf -- "$root"
mkdir -p -- "$root/bin" "$root/state" "$root/runtime" "$root/home"
mkdir -p -- "$root/bin/lib"
ln -s -- "$repo/bin/lib/qml-library.js" "$root/bin/lib/qml-library.js"
trap 'chmod -R u+rwx -- "${root:?}" 2>/dev/null; rm -rf -- "${root:?}"' EXIT
failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }
node_dir="$(dirname -- "$(node -e 'process.stdout.write(process.execPath)')")"
run_env=(env -i HOME="$root/home" PATH="$node_dir:/usr/bin:/bin" XDG_STATE_HOME="$root/state" XDG_RUNTIME_DIR="$root/runtime" LC_ALL=C)
cat >"$root/bin/vgsh" <<'VGSH'
#!/usr/bin/env bash
record="$XDG_STATE_HOME/vgs/updates-test"
mkdir -p -- "$record"
printf '%s %s at=%s\n' "$1" "$2" "$(date +%s%N)" >>"$record/calls"
case "$1 $2" in
  'pkg check') sleep "${VGS_UPDATES_TEST_SLEEP:-0}"; printf '[]\n' ;;
  'self status') sleep "${VGS_UPDATES_TEST_SLEEP:-0}"; printf '{"version":"0.1.0","method":"checkout","package":null,"current":"0.1.0","latest":"0.1.0","behind":false,"error":null}\n' ;;
  'plugin outdated') sleep "${VGS_UPDATES_TEST_SLEEP:-0}"; printf '[]\n' ;;
  'theme outdated') sleep "${VGS_UPDATES_TEST_SLEEP:-0}"; printf '[]\n' ;;
  *) exit 2 ;;
esac
VGSH
chmod 755 "$root/bin/vgsh"
if "${run_env[@]}" "$check" >/dev/null 2>"$root/missing.err"; then
  fail "check refuses without --vgsh"
elif grep -q 'updates-check: refused: vgsh=missing' "$root/missing.err"; then
  ok "check refuses without --vgsh"
else
  fail "missing --vgsh refusal text"
fi
start_ms=$(( $(date +%s%N) / 1000000 ))
"${run_env[@]}" VGS_UPDATES_TEST_SLEEP=1 "$check" --vgsh "$root/bin/vgsh" >/dev/null
elapsed=$(( $(date +%s%N) / 1000000 - start_ms ))
if [[ $elapsed -lt 3000 ]]; then ok "check runs independent probes concurrently"; else fail "check runs independent probes concurrently: elapsed=${elapsed}ms"; fi
if [[ $(wc -l <"$root/state/vgs/updates-test/calls") -eq 4 ]]; then ok "check runs four probes once"; else fail "check runs four probes once"; fi
# Process groups: each probe's vgsh leaves a grandchild in its group. TERM
# to bin/check must reach it; the control signals each probe's pid alone
# and leaves the grandchild running.
cat >"$root/bin/vgsh" <<'VGSH'
#!/usr/bin/env bash
record="$XDG_STATE_HOME/vgs/updates-test"
mkdir -p -- "$record"
(sleep 60) &
echo "$!" >>"$record/grandchildren-$RUN"
wait
VGSH
chmod 755 "$root/bin/vgsh"
# grandchild_run LABEL CHECK: TERM CHECK once its four probes started a
# grandchild; print CHECK's status and how many grandchildren outlived it.
grandchild_run() {
  local label="$1" helper="$2" pid status left=0 child log="$root/state/vgs/updates-test/grandchildren-$1"
  set +e
  "${run_env[@]}" RUN="$label" "$helper" --vgsh "$root/bin/vgsh" >/dev/null 2>"$root/$label.err" &
  pid=$!
  for _ in $(seq 1 50); do [[ -f $log && $(wc -l <"$log") -eq 4 ]] && break; sleep 0.1; done
  kill -TERM "$pid"
  wait "$pid"
  status=$?
  set -e
  sleep 0.2
  while read -r child; do [[ -n $child && -d /proc/$child ]] && left=$((left + 1)); done <"$log"
  echo "$status $left"
  while read -r child; do kill -KILL "$child" 2>/dev/null || true; done <"$log"
}
read -r status left <<<"$(grandchild_run groups "$check")"
if [[ $status -eq 143 ]]; then ok "TERM exits as 128 plus the signal"; else fail "TERM exits as 128 plus the signal: $status"; fi
if [[ $left -eq 0 ]]; then ok "TERM kills probe grandchildren"; else fail "TERM kills probe grandchildren: left=$left"; fi
pid_only="$root/check-pid-only"
python3 - "$check" "$pid_only" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
old = 'kill -"$sig" -- "-$pid" 2>/dev/null || kill -"$sig" -- "$pid" 2>/dev/null || true'
new = 'kill -"$sig" -- "$pid" 2>/dev/null || true'
assert source.count(old) == 1
pathlib.Path(sys.argv[2]).write_text(source.replace(old, new))
PY
chmod 755 "$pid_only"
read -r _ left <<<"$(grandchild_run pid-only "$pid_only")"
if [[ $left -gt 0 ]]; then ok "control: signalling each probe's pid alone leaves its grandchild"; else fail "control: signalling each probe's pid alone leaves its grandchild"; fi
# Delayed shutdown: the package probe, the first bin/check waits on, takes
# three seconds to end after TERM; the other probes end at once. bin/check
# must wait again for a probe whose wait the signal interrupted, so no
# probe outlives it. The control is bin/check with only that re-wait
# removed, which returns while the package probe still runs.
cat >"$root/bin/vgsh" <<'VGSH'
#!/usr/bin/env bash
record="$XDG_STATE_HOME/vgs/updates-test"
mkdir -p -- "$record"
echo "$$" >>"$record/delayed-$RUN"
if [[ $1 == pkg ]]; then trap 'sleep 3; exit 143' TERM; else trap 'exit 143' TERM; fi
sleep 60 &
wait
VGSH
chmod 755 "$root/bin/vgsh"
# delayed_run LABEL CHECK: run CHECK until its four probes recorded
# themselves, TERM it, and print how many probes outlived it.
delayed_run() {
  local label="$1" helper="$2" pid left=0 probe log="$root/state/vgs/updates-test/delayed-$1"
  set +e
  "${run_env[@]}" RUN="$label" "$helper" --vgsh "$root/bin/vgsh" >/dev/null 2>"$root/$label.err" &
  pid=$!
  for _ in $(seq 1 50); do [[ -f $log && $(wc -l <"$log") -eq 4 ]] && break; sleep 0.1; done
  kill -TERM "$pid"
  wait "$pid"
  set -e
  while read -r probe; do [[ -n $probe && -d /proc/$probe ]] && left=$((left + 1)); done <"$log"
  echo "$left"
  while read -r probe; do kill -KILL "$probe" 2>/dev/null || true; done <"$log"
}
shipped_left="$(delayed_run shipped "$check")"
if [[ $shipped_left -eq 0 ]]; then ok "TERM waits for a probe's delayed shutdown"; else fail "TERM waits for a probe's delayed shutdown: left=$shipped_left"; fi
mutant="$root/check-no-rewait"
python3 - "$check" "$mutant" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
old = """  while true; do
    wait "${pids[$i]}" || status=$?
    if [[ -z $stop_status || ! -d /proc/${pids[$i]} ]]; then break; fi
    status=0
  done"""
new = """  wait "${pids[$i]}" || status=$?"""
assert source.count(old) == 1
pathlib.Path(sys.argv[2]).write_text(source.replace(old, new))
PY
chmod 755 "$mutant"
mutant_left="$(delayed_run mutant "$mutant")"
if [[ $mutant_left -gt 0 ]]; then ok "control: without the re-wait a probe outlives bin/check"; else fail "control: without the re-wait a probe outlives bin/check"; fi
# SIGINT: each probe starts in the background of bin/check, so with SIGINT
# ignored, and a bash probe cannot trap it; a check stopped by INT still
# sends every probe group TERM. The stand-in probe notes each TERM it gets.
# The control forwards INT, which the probes ignore until their 3 s sleep
# ends.
cat >"$root/bin/vgsh" <<'VGSH'
#!/usr/bin/env bash
record="$XDG_STATE_HOME/vgs/updates-test"
mkdir -p -- "$record"
echo "$$" >>"$record/int-$RUN"
trap ': >"$record/termed-$RUN-$$"; exit 143' TERM
sleep 3 &
wait
VGSH
chmod 755 "$root/bin/vgsh"
# int_run LABEL CHECK: run CHECK with SIGINT at its default, as a terminal's
# foreground job has it, until its four probes recorded themselves, INT
# it, and print its status and how many probes got TERM.
int_run() {
  local label="$1" helper="$2" pid status log="$root/state/vgs/updates-test/int-$1"
  set +e
  "${run_env[@]:0:2}" --default-signal=INT "${run_env[@]:2}" RUN="$label" "$helper" --vgsh "$root/bin/vgsh" >/dev/null 2>"$root/$label.err" &
  pid=$!
  for _ in $(seq 1 50); do [[ -f $log && $(wc -l <"$log") -eq 4 ]] && break; sleep 0.1; done
  kill -INT "$pid"
  wait "$pid"
  status=$?
  set -e
  echo "$status $(find "$root/state/vgs/updates-test" -name "termed-$label-*" | wc -l)"
}
read -r status termed <<<"$(int_run int "$check")"
if [[ $status -eq 130 ]]; then ok "INT exits as 128 plus the signal"; else fail "INT exits as 128 plus the signal: $status"; fi
if [[ $termed -eq 4 ]]; then ok "INT sends every probe TERM"; else fail "INT sends every probe TERM: termed=$termed"; fi
int_mutant="$root/check-forwards-int"
python3 - "$check" "$int_mutant" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
old = '  signal_groups TERM\n'
new = '  signal_groups INT\n'
assert source.count(old) == 1
pathlib.Path(sys.argv[2]).write_text(source.replace(old, new))
PY
chmod 755 "$int_mutant"
read -r _ termed <<<"$(int_run int-mutant "$int_mutant")"
if [[ $termed -eq 0 ]]; then ok "control: forwarding INT stops no probe"; else fail "control: forwarding INT stops no probe: termed=$termed"; fi
if [[ $failures -gt 0 ]]; then echo "test-updates-check: failed=$failures"; exit 1; fi
echo "test-updates-check: ok"
