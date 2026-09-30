#!/usr/bin/env bash
# Controls for vgs.lock's before-sleep hook, shell/plugins/vgs.lock/bin/
# sleep-watch: the budget it derives from logind's InhibitDelayMaxUSec, the
# lines it prints, a preparation already under way when it subscribes, the
# release on `secure`, `refused`, the budget's end and a closed stdin, and
# its refusals when dbus-monitor stays silent or ends. Stand-in busctl and
# dbus-monitor, first on PATH, answer from STUB_WINDOW and STUB_PREPARING;
# the monitor prints the bus's NameAcquired, then one PrepareForSleep
# unless STUB_NO_SIGNAL or STUB_QUIET is set, nothing with STUB_SILENT. No
# row reaches logind or the system bus. Expected values are computed by
# hand from Omarchy's rule.
set -euo pipefail

TMP_ROOT="$(mktemp -d)" || { echo "test-lock-sleep-watch: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "test-lock-sleep-watch: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "test-lock-sleep-watch: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

repo="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
script="$repo/shell/plugins/vgs.lock/bin/sleep-watch"
stub="$TMP_ROOT/stub"
mkdir -p "$stub"
cat >"$stub/busctl" <<'SH'
#!/usr/bin/env bash
case "${5:-}" in
  InhibitDelayMaxUSec) [[ -n ${STUB_WINDOW:-} ]] || exit 1; echo "t $STUB_WINDOW" ;;
  PreparingForSleep) echo "b ${STUB_PREPARING:-false}" ;;
  *) exit 1 ;;
esac
SH
cat >"$stub/dbus-monitor" <<'SH'
#!/usr/bin/env bash
[[ -n ${STUB_SILENT:-} ]] && exec sleep 3
echo "signal time=1 sender=org.freedesktop.DBus -> destination=:1.9 serial=4294967295 path=/org/freedesktop/DBus; interface=org.freedesktop.DBus; member=NameAcquired"
# A resume, PrepareForSleep(false), is no sleep.
[[ -n ${STUB_QUIET:-} ]] && { echo "   boolean false"; exit 3; }
[[ -n ${STUB_NO_SIGNAL:-} ]] && exec sleep 30
echo "signal time=2 sender=:1.1 member=PrepareForSleep"
echo "   boolean true"
exec sleep 30
SH
chmod 755 "$stub/busctl" "$stub/dbus-monitor"

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# watch_row NAME WANT_EXIT WANT_STDOUT WANT_STDERR STDIN [NAME=VALUE...]: the
# script's stdout lines joined by `|`. STDIN `secure` or `other` is written
# once the script announces the sleep; `closed` closes stdin at once;
# `silent` holds it open and writes nothing.
run_watch() { # SCRIPT STDIN [NAME=VALUE...]
  local path="$1" input="$2"
  shift 2
  case "$input" in
    closed) env -i PATH="$stub:/usr/bin:/bin" "$@" "$path" </dev/null ;;
    silent) sleep 2 | env -i PATH="$stub:/usr/bin:/bin" "$@" "$path" ;;
    *) { sleep 0.5; echo "$input"; } | env -i PATH="$stub:/usr/bin:/bin" "$@" "$path" ;;
  esac
}
watch_row() {
  local name="$1" want_exit="$2" want_out="$3" want_err="$4" input="$5" status=0 out err=""
  shift 5
  out="$(run_watch "${WATCH_SCRIPT:-$script}" "$input" "$@" 2>"$TMP_ROOT/err")" || status=$?
  out="${out//$'\n'/|}"
  [[ -s $TMP_ROOT/err ]] && IFS= read -r err <"$TMP_ROOT/err"
  if [[ $status == "$want_exit" && $out == "$want_out" && $err == "$want_err" ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit out=[$out] want=[$want_out] err=[$err] want=[$want_err]"; fi
}

# Omarchy's rule: the window less a fifth of it, at least 1000 ms, capped at
# 12000 ms, 5 s when unreadable. A row's writer answers half a second after
# the script starts, once it announced the sleep; a silent one holds stdin
# open past the budget.
watch_row "logind's 5 s default leaves 4000 ms" 0 "ready budget_ms=4000|sleep budget_ms=4000|released reason=secure" "" secure STUB_WINDOW=5000000
watch_row "a 15 s window leaves 12000 ms" 0 "ready budget_ms=12000|sleep budget_ms=12000|released reason=secure" "" secure STUB_WINDOW=15000000
watch_row "a 30 s window is capped at 12000 ms" 0 "ready budget_ms=12000|sleep budget_ms=12000|released reason=secure" "" secure STUB_WINDOW=30000000
watch_row "a 2 s window keeps a second for logind" 0 "ready budget_ms=1000|sleep budget_ms=1000|released reason=secure" "" secure STUB_WINDOW=2000000
watch_row "an unreadable window reads as 5 s" 0 "ready budget_ms=4000|sleep budget_ms=4000|released reason=secure" "" secure
watch_row "a refusal releases the sleep as refused" 0 "ready budget_ms=4000|sleep budget_ms=4000|released reason=refused" "" refused STUB_WINDOW=5000000
watch_row "a preparation under way before the listener is a sleep" 0 "ready budget_ms=4000|sleep budget_ms=4000|released reason=secure" "" secure STUB_WINDOW=5000000 STUB_PREPARING=true STUB_NO_SIGNAL=1
watch_row "a silent dbus-monitor is refused" 1 "" "sleep-watch: refused: monitor=silent" closed STUB_WINDOW=5000000 STUB_SILENT=1
watch_row "a line other than secure is no confirmation" 0 "ready budget_ms=4000|sleep budget_ms=4000|released reason=timeout" "" other STUB_WINDOW=5000000
watch_row "the budget's end releases the sleep" 0 "ready budget_ms=250|sleep budget_ms=250|released reason=timeout" "" silent STUB_WINDOW=1250000
watch_row "a closed stdin releases the sleep" 0 "ready budget_ms=4000|sleep budget_ms=4000|released reason=closed" "" closed STUB_WINDOW=5000000
watch_row "dbus-monitor ending is refused" 1 "ready budget_ms=4000" "sleep-watch: refused: monitor=exited status=3" closed STUB_WINDOW=5000000 STUB_QUIET=1

# Must-fail controls, one per rule, each on a copy of the script.
control() { # NAME NEEDLE REPLACEMENT
  local copy="$TMP_ROOT/control-$1"
  python3 - "$script" "$copy" "$2" "$3" <<'PY'
import sys
source, target, needle, replacement = sys.argv[1:]
text = open(source).read()
assert text.count(needle) == 1, "control needle must occur once: " + needle
open(target, "w").write(text.replace(needle, replacement))
PY
  chmod 755 "$copy"
  WATCH_CONTROL="$copy"
}
control_row() { # NAME WANT_STDOUT STDIN [NAME=VALUE...]: passes when the copy misses WANT_STDOUT
  local name="$1" want_out="$2" input="$3" out
  shift 3
  out="$(run_watch "$WATCH_CONTROL" "$input" "$@" 2>/dev/null)" || true
  out="${out//$'\n'/|}"
  if [[ $out != "$want_out" ]]; then ok "control: $name"; else fail "control: $name passed the row"; fi
}
control no-cap 'if ((window < budget_cap_ms)); then echo "$window"; else echo "$budget_cap_ms"; fi' 'echo "$window"'
control_row "a copy with no cap" "ready budget_ms=12000|sleep budget_ms=12000|released reason=secure" secure STUB_WINDOW=30000000
control no-reserve 'window=$((window - (window / 5 > 1000 ? window / 5 : 1000)))' 'window=$((window - window / 5))'
control_row "a copy that keeps no second for logind" "ready budget_ms=1000|sleep budget_ms=1000|released reason=secure" secure STUB_WINDOW=2000000
control no-default '|| window=5000000' '|| window=1000000'
control_row "a copy with another default window" "ready budget_ms=4000|sleep budget_ms=4000|released reason=secure" secure
control any-reply '      *) echo "released reason=timeout" ;;' '      *) echo "released reason=secure" ;;'
control_row "a copy that takes any line for the confirmation" "ready budget_ms=4000|sleep budget_ms=4000|released reason=timeout" other STUB_WINDOW=5000000
control no-bound 'IFS= read -r -t "$budget_s" reply' 'IFS= read -r reply'
control_row "a copy with no bound on the wait" "ready budget_ms=250|sleep budget_ms=250|released reason=timeout" silent STUB_WINDOW=1250000
control no-preparing '[[ $preparing != "b true" ]] || sleep_once' ':'
control_row "a copy that ignores a preparation under way" "ready budget_ms=4000|sleep budget_ms=4000|released reason=secure" secure STUB_WINDOW=5000000 STUB_PREPARING=true STUB_NO_SIGNAL=1
control no-subscribe-wait 'if ! IFS= read -r -t 2 line <&"$monitor_fd"; then' 'if false; then'
control_row "a copy that reports ready before the listener answers" "" closed STUB_WINDOW=5000000 STUB_SILENT=1
control no-refused '      refused) echo "released reason=refused" ;;' '      refused) echo "released reason=timeout" ;;'
control_row "a copy that takes a refusal for a timeout" "ready budget_ms=4000|sleep budget_ms=4000|released reason=refused" refused STUB_WINDOW=5000000
control any-signal '[[ $line == *"boolean true"* ]] || continue' ':'
control_row "a copy that takes any bus line for a sleep" "ready budget_ms=4000" closed STUB_WINDOW=5000000 STUB_QUIET=1

if ((failures > 0)); then echo "test-lock-sleep-watch: failed=$failures"; exit 1; fi
echo "test-lock-sleep-watch: ok"
