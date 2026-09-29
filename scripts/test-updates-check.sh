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
cat >"$root/bin/vgsh" <<'VGSH'
#!/usr/bin/env bash
record="$XDG_STATE_HOME/vgs/updates-test"
mkdir -p -- "$record"
(sleep 60) &
echo "$!" >>"$record/grandchildren"
wait
VGSH
chmod 755 "$root/bin/vgsh"
set +e
"${run_env[@]}" "$check" --vgsh "$root/bin/vgsh" >/dev/null 2>"$root/signal.err" &
check_pid=$!
for _ in $(seq 1 50); do [[ -s "$root/state/vgs/updates-test/grandchildren" ]] && break; sleep 0.1; done
kill -TERM "$check_pid"
wait "$check_pid"
status=$?
set -e
if [[ $status -eq 143 ]]; then ok "TERM exits as 128 plus the signal"; else fail "TERM exits as 128 plus the signal: $status"; fi
left=0
while read -r pid; do [[ -n $pid && -d /proc/$pid ]] && left=$((left + 1)); done <"$root/state/vgs/updates-test/grandchildren"
if [[ $left -eq 0 ]]; then ok "TERM kills probe grandchildren"; else fail "TERM kills probe grandchildren: left=$left"; fi
mutant="$root/check-no-rewait"
python3 - "$check" "$mutant" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
old = '''while true; do
    wait "${pids[$i]}" || status=$?
    if [[ -z $stop_status || ! -d /proc/${pids[$i]} ]]; then break; fi
    status=0
  done'''
new = '''if [[ -n $stop_status ]]; then break; fi
  wait "${pids[$i]}" || status=$?'''
assert source.count(old) == 1
pathlib.Path(sys.argv[2]).write_text(source.replace(old, new))
PY
chmod 755 "$mutant"
cat >"$root/bin/vgsh" <<'VGSH'
#!/usr/bin/env bash
record="$XDG_STATE_HOME/vgs/updates-test"
mkdir -p -- "$record"
echo "$$" >>"$record/slow-children"
trap 'sleep 3; exit 143' TERM
sleep 60
VGSH
chmod 755 "$root/bin/vgsh"
set +e
"${run_env[@]}" "$mutant" --vgsh "$root/bin/vgsh" >/dev/null 2>"$root/mutant.err" &
mutant_pid=$!
for _ in $(seq 1 50); do [[ -s "$root/state/vgs/updates-test/slow-children" ]] && break; sleep 0.1; done
started="$(tail -n 1 "$root/state/vgs/updates-test/slow-children")"
kill -TERM "$mutant_pid"
wait "$mutant_pid"
set -e
if [[ -d /proc/$started ]]; then
  ok "control: without the re-wait loop a probe can outlive bin/check"
  kill -TERM "$started" 2>/dev/null || true
else
  fail "control: without the re-wait loop a probe can outlive bin/check"
fi
if [[ $failures -gt 0 ]]; then echo "test-updates-check: failed=$failures"; exit 1; fi
echo "test-updates-check: ok"
