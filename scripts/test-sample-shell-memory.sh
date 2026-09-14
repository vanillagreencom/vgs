#!/usr/bin/env bash
# Drive scripts/sample-shell-memory.sh --report and its argument refusals. The
# report mode needs no live shell: it reads a TSV and prints keyed lines, so every
# case here is a fixture log. Sampling itself needs a running shell and is not
# exercised; scripts/check-validation-inventory.py records that exemption.
#
# Each case pins the refusal or report key, the value it carries, and the exit
# status. The controls at the end plant one defect per report rule and require
# the case that rule owns to go red.
#
# The sampling path is out of reach here: it resolves a pid through the instance
# registry, so reaching it needs a running shell. Its own unreadable-log refusal
# raises the same key this file pins on the report side, from the same call.
#
# Every copy of the script under test runs from a plain temporary directory with
# no repository beside it. --report must work there: the sampler sources its
# instance-registry library only on the sampling path. Staging a checkout-shaped
# tree here would hand a copy that dependency back and no case would see the
# source line return to the preamble, so the copies stay bare on purpose.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

tmp="$(mktemp -d)" || {
  printf 'test-sample-shell-memory: could not create a temporary directory\n' >&2
  exit 1
}
trap 'rm -rf "${tmp:?}"' EXIT INT TERM

sampler="$tmp/sampler.sh"
cp "$repo_root/scripts/sample-shell-memory.sh" "$sampler"
chmod +x "$sampler"

failures=0
case_failed=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
  case_failed=1
}
ok() {
  [[ $case_failed -eq 0 ]] && printf '  ok    %s\n' "$1"
  case_failed=0
}
expect_contains() { [[ "$1" == *"$2"* ]] || fail "$3" "expected to contain: $2 (got: $1)"; }
expect_absent() { [[ "$1" != *"$2"* ]] || fail "$3" "expected NOT to contain: $2 (got: $1)"; }

header=$'epoch\tpid\tsession\tuptime_s\trss_kb\tanon_kb\tfile_kb\tswap_kb'
header+=$'\tthp_kb\thwm_kb\tjsheap_kb\tjit_kb\tgpu_kb\tthreads\tfds\tmaps\tcpu_ticks'

# Write a log. $1 path, $2 pid, $3 session, $4 first uptime, $5 step, $6 count,
# $7 whether to write the header. Resident size climbs 1 MiB a minute so a rate
# is non-zero and a session mix-up is visible as a sign change.
write_log() {
  local path="$1" pid="$2" sess="$3" first="$4" step="$5" count="$6" head="${7:-yes}"
  [[ "$head" == yes ]] && printf '%s\n' "$header" >"$path"
  awk -v pid="$pid" -v sess="$sess" -v first="$first" -v step="$step" -v n="$count" '
    BEGIN {
      for (i = 0; i < n; i++) {
        up = first + i * step
        rss = 300000 + up / 60 * 1024
        printf "%d\t%s\t%s\t%d\t%d\t%d\t100000\t0\t%d\t3000000\t27000\t2500\t150000\t43\t250\t3300\t%d\n",
          1789000000 + up, pid, sess, up, rss, rss - 200000, rss / 2, up
      }
    }' >>"$path"
}

# Run --report against a given script copy. Sets out, err and rc.
run_report() {
  local script="$1" log="$2"
  rc=0
  err="$tmp/stderr"
  out="$("$script" --report "$log" 2>"$err")" || rc=$?
  err="$(cat "$err")"
}

echo "=== sample-shell-memory --report ==="

# One case per report rule. FIXTURE names the builder below; EXPECT is the key
# the case owns; STREAM says which stream carries it; STATUS is the exit code.
build_fixture() {
  case "$1" in
    # 31 samples a minute apart ending at 0.50 h: the session never reached 1 h.
    short) write_log "$2" 100 11 0 60 31 ;;
    # 481 samples a minute apart from 0 h: 1 h and 8 h land on real samples.
    spans-8h) write_log "$2" 100 11 0 60 481 ;;
    # 25 h at the same spacing, so 24 h lands on a real sample too and both
    # rates that end or begin there are produced.
    spans-24h) write_log "$2" 100 11 0 60 1501 ;;
    # Starts at 76 h, so every mark is long past and no sample sits near one.
    late-start) write_log "$2" 100 11 273600 60 20 ;;
    # One session, sampled at 60 s to 3000 s, then again from 7200 s. The 1 h
    # mark falls in the hole: the nearest earlier sample is 600 s away.
    hole)
      write_log "$2" 100 11 0 60 51
      write_log "$2" 100 11 7200 60 11 no
      ;;
    # 1 h then a 3 s step: the 1 h-to-last span is under the rate floor.
    under-floor) write_log "$2" 100 11 3600 3 20 ;;
    # A restart: session 11 ran to 0.5 h, session 22 starts again from zero.
    two-sessions)
      write_log "$2" 100 11 0 60 31
      write_log "$2" 200 22 0 60 481 no
      ;;
    # One session whose rows were interleaved, so uptime steps backwards.
    backwards)
      write_log "$2" 100 11 0 60 5
      write_log "$2" 100 11 0 60 3 no
      ;;
    header-only) printf '%s\n' "$header" >"$2" ;;
    no-rss-column)
      printf '%s\n' "${header/rss_kb/resident_kb}" >"$2"
      write_log "$tmp/spill" 100 11 0 60 5
      tail -n +2 "$tmp/spill" >>"$2"
      ;;
    *) fail "fixture" "unknown fixture $1" ;;
  esac
}

report_case() {
  local label="$1" fixture="$2" stream="$3" expect="$4" status="$5" script="${6:-$sampler}"
  local log="$tmp/log.tsv"
  rm -f -- "${tmp:?}/log.tsv"
  build_fixture "$fixture" "$log"
  run_report "$script" "$log"
  [[ "$rc" == "$status" ]] || fail "$label" "expected exit $status, got $rc"
  if [[ "$stream" == out ]]; then
    expect_contains "$out" "$expect" "$label"
  else
    expect_contains "$err" "$expect" "$label"
  fi
}

cases=0
while IFS='|' read -r label fixture stream expect status; do
  [[ -n "$label" ]] || continue
  cases=$((cases + 1))
  report_case "$label" "$fixture" "$stream" "$expect" "$status"
  ok "$label"
done <<'CASES'
a log ending before a mark says the mark was not reached|short|out|mark=1h status=not-reached|0
a log ending before a mark does not report a later mark either|short|out|mark=24h status=not-reached|0
a log spanning the mark reports that sample's uptime|spans-8h|out|mark=1h uptime_s=3600|0
a log spanning two marks rates the span and names both uptimes|spans-8h|out|rate=1h..8h from_uptime_s=3600 to_uptime_s=28800 span_s=25200|0
a mark the session passed with no sample near it is not filled|late-start|out|mark=1h status=no-sample-within tolerance_s=300|0
a mark inside a gap in the log is not filled from the sample before it|hole|out|mark=1h status=no-sample-within tolerance_s=300|0
a span under the rate floor carries no rate|under-floor|out|rate=1h..last status=span-under-floor|0
a session the sampler joined late still gets a window rate|late-start|out|rate=window from_uptime_s=273600 to_uptime_s=274740 span_s=1140|0
a log past 24 h fills the far mark from a real sample|spans-24h|out|mark=24h uptime_s=86400|0
a log past 24 h rates the span into the far mark|spans-24h|out|rate=8h..24h from_uptime_s=28800 to_uptime_s=86400 span_s=57600|0
a log past 24 h rates the span out of the far mark|spans-24h|out|rate=24h..last from_uptime_s=86400|0
the report names the span of the session it picked|spans-8h|out|span=0..28800|0
a two-session log reports the newest session alone|two-sessions|out|session=200:22 samples=481|0
a two-session log names what it left out|two-sessions|out|excluded=1 rows=31|0
uptime going backwards refuses every mark and rate|backwards|err|uptime-backwards=0 after=240 row=6|1
a log with no sample rows refuses|header-only|err|no-samples=0|1
a header missing a column the report reads refuses|no-rss-column|err|header-missing-column=rss_kb|2
CASES

# The negative of the rate rule: a span at or over the floor reports fields, not
# a status. Asserting only the status line would pass with rates never emitted.
report_case "a span over the floor reports rate fields" spans-8h out "rss_mib_h=" 0
expect_absent "$out" "rate=1h..8h status=" "a span over the floor reports rate fields"
ok "a span over the floor reports rate fields"

# The negative of the window rate: a window under the floor reports the refusal.
report_case "a window under the floor reports the refusal" under-floor out "rate=window status=span-under-floor span_s=57" 0
ok "a window under the floor reports the refusal"

# The negative of the gap rule: a mark the log really covers is still filled.
report_case "a mark inside the sampled stretch is still filled" hole out "mark=last uptime_s=7800" 0
ok "a mark inside the sampled stretch is still filled"

# The negative of the session rule: a single-session log excludes nothing.
report_case "a single-session log excludes nothing" spans-8h out "excluded=0 rows=0" 0
ok "a single-session log excludes nothing"

# The high-water mark is reported and is not the peak among logged samples. The
# fixture's hwm_kb is 3000000 kB while its logged peak is far below that.
report_case "the report separates the high-water mark from the logged peak" spans-8h out "high-water=2930" 0
expect_contains "$out" "logged-peak=773" "the report separates the high-water mark from the logged peak"
ok "the report separates the high-water mark from the logged peak"

# The report reads columns by name. Swapping two names in the header alone, with
# every data row untouched, must swap the reported values: reading by position
# would report them unchanged. At 1 h the unswapped log holds rss 353 MiB and
# anon 158 MiB, so the swap must report those two the other way round.
swapped="$tmp/swapped.tsv"
write_log "$swapped" 100 11 0 60 481
python3 - "$swapped" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
head = lines[0].split("\t")
i, j = head.index("rss_kb"), head.index("anon_kb")
head[i], head[j] = head[j], head[i]
lines[0] = "\t".join(head)
open(path, "w").write("\n".join(lines) + "\n")
PY
run_report "$sampler" "$swapped"
expect_contains "$out" "mark=1h uptime_s=3600 rss_mib=158 anon_mib=353" "the report reads columns by header name"
ok "the report reads columns by header name"

# The writer states the column order twice: the header constant and the printf
# in its awk block. Both are read out of the script under test rather than
# restated here, so a column added to one and not the other is caught. This pins
# the count only; the order within it is not checked. The row printf carries one
# extra leading conversion for the mapping count the shell strips.
header_body="$(sed -n "s/^COLUMNS_HEADER+*=\\\$'\(.*\)'$/\1/p" "$sampler" | tr -d '\n')"
head_count="$(( $(grep -o '\\t' <<<"$header_body" | grep -c .) + 1 ))"
if ! fmt_count="$(awk '/printf "%d\\t%d\\t%s\\t%s/ { print; exit }' "$sampler" | grep -o '%[ds]' | grep -c .)"; then
  fmt_count=0
fi
[[ "$head_count" == "$((fmt_count - 1))" ]] ||
  fail "the header and the row writer declare the same column count" \
    "header names $head_count columns, the row printf writes $fmt_count including its leading mapping count"
[[ "$head_count" -gt 1 ]] ||
  fail "the header and the row writer declare the same column count" \
    "the extractor read $head_count columns from the header, so it is broken rather than the script sparse"
ok "the header and the row writer declare the same column count"

# The property the sampler's header states: --report runs from a copy with no
# repository beside it, because the instance-registry library is sourced only on
# the sampling path. Every case above already runs from such a copy; this one
# names the property so moving that source line back to the preamble fails here
# with its own reason rather than only as collateral.
bare="$tmp/bare/sampler.sh"
mkdir -p "$tmp/bare"
cp "$repo_root/scripts/sample-shell-memory.sh" "$bare"
chmod +x "$bare"
rm -f -- "${tmp:?}/log.tsv"
build_fixture spans-8h "$tmp/log.tsv"
run_report "$bare" "$tmp/log.tsv"
[[ "$rc" == 0 ]] ||
  fail "--report runs from a copy with no repository beside it" \
    "expected exit 0 from a bare copy, got $rc (stderr: $err)"
expect_contains "$out" "mark=1h uptime_s=3600" "--report runs from a copy with no repository beside it"
ok "--report runs from a copy with no repository beside it"

echo "=== argument refusals ==="

arg_case() {
  local label="$1" expect="$2" status="$3"
  shift 3
  local rc=0 err_file="$tmp/arg-stderr"
  "$sampler" "$@" >/dev/null 2>"$err_file" || rc=$?
  [[ "$rc" == "$status" ]] || fail "$label" "expected exit $status, got $rc"
  expect_contains "$(cat "$err_file")" "$expect" "$label"
  ok "$label"
}

arg_case "an unknown argument is refused by name" "unknown-argument=--bogus" 2 --bogus
arg_case "an option with no value is refused by name" "missing-value=--interval" 2 --interval
arg_case "a non-numeric interval is refused with its value" "bad-interval=abc" 2 --interval abc
arg_case "a zero interval is refused with its value" "bad-interval=0" 2 --interval 0
arg_case "a non-numeric hours is refused with its value" "bad-hours=soon" 2 --hours soon
arg_case "an unreadable log is refused with its path" "unreadable-log=$tmp/missing.tsv" 2 --report "$tmp/missing.tsv"


echo "=== must-fail controls ==="

# Build a copy of the sampler beside a real library, apply one substitution, and
# report what --report then does. A mutation that does not apply, or a copy that
# does not start, is a fixture defect rather than a verdict: run_control returns
# non-zero for both so the callers below can say which.
run_control() {
  local from="$1" to="$2" fixture="$3"
  local mutant="$tmp/mutant.sh"
  cp "$sampler" "$mutant"
  if [[ -n "$from" ]]; then
    python3 - "$mutant" "$from" "$to" <<'PY' || return 2
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
if text.count(old) != 1:
    sys.exit(1)
open(path, "w").write(text.replace(old, new))
PY
  fi
  chmod +x "$mutant"
  local log="$tmp/log.tsv"
  rm -f -- "${tmp:?}/log.tsv"
  build_fixture "$fixture" "$log"
  run_report "$mutant" "$log"
  # A mutant that died in its preamble emits neither stream and judges nothing.
  # Every fixture here yields at least one session line from a script that ran.
  [[ "$out" == *"session="* ]] || return 3
  return 0
}

control() {
  local label="$1" from="$2" to="$3" fixture="$4" stream="$5" expect="$6" status="$7"
  local rcc=0
  run_control "$from" "$to" "$fixture" || rcc=$?
  case "$rcc" in
    2) fail "$label" "the mutation did not apply, so the rule is unproven" ; return ;;
    3) fail "$label" "the mutant did not run (no session= line), so the rule is unproven" ; return ;;
  esac
  local body="$out"
  [[ "$stream" == err ]] && body="$err"
  if [[ "$rc" == "$status" && "$body" == *"$expect"* ]]; then
    fail "$label" "the defect did not redden its case: still saw $expect at exit $status"
  else
    printf '  ok    %s\n' "$label"
  fi
}

# The control of the controls. An UNMUTATED copy through the same path must
# still produce its case's expected line: if it does not, every control above
# passes for the wrong reason and proves nothing.
unmutated_check() {
  local label="a copy with nothing planted still passes its case"
  local rcc=0
  run_control "" "" spans-8h || rcc=$?
  case "$rcc" in
    3) fail "$label" "the unmutated copy did not run, so every control below is vacuous" ; return ;;
    0) ;;
    *) fail "$label" "the unmutated copy could not be built (status $rcc)" ; return ;;
  esac
  [[ "$rc" == 0 ]] || fail "$label" "expected exit 0 from an unmutated copy, got $rc"
  expect_contains "$out" "mark=1h uptime_s=3600" "$label"
  ok "$label"
}
unmutated_check

control "removing the mark-reached test reddens the not-reached case" \
  'if (u[n] < target) return -1' 'if (0) return -1' \
  short out "mark=1h status=not-reached" 0

control "removing the mark tolerance reddens the gap case" \
  'if (target - u[best] > tol) return -2' 'if (0) return -2' \
  hole out "mark=1h status=no-sample-within tolerance_s=300" 0

# shellcheck disable=SC2016  # awk source: $ is awk's field operator, not shell expansion
control "merging sessions reddens the newest-session case" \
  'function session_key() { return $(col["pid"]) ":" $(col["session"]) }' \
  'function session_key() { return "merged" }' \
  two-sessions out "session=200:22 samples=481" 0

control "removing the order test reddens the uptime-backwards case" \
  'if (u[i] < u[i - 1]) {' 'if (0) {' \
  backwards err "uptime-backwards=0 after=240 row=6" 1

control "removing the rate floor reddens the span-under-floor case" \
  'if (d < floor) {' 'if (0) {' \
  under-floor out "rate=1h..last status=span-under-floor" 0

# shellcheck disable=SC2016  # awk source: $ is awk's field operator, not shell expansion
control "shifting the header map reddens the column-by-name case" \
  'for (i = 1; i <= NF; i++) col[$i] = i' 'for (i = 1; i <= NF; i++) col[$i] = i + 1' \
  spans-8h out "mark=1h uptime_s=3600" 0

control "drifting the 24 h target reddens the far-mark case" \
  'idx[3] = at(24 * 3600)' 'idx[3] = at(25 * 3600)' \
  spans-24h out "mark=24h uptime_s=86400" 0

control "dropping the window rate reddens the joined-late case" \
  'raterow("window", 1, n)' '' \
  late-start out "rate=window from_uptime_s=273600" 0

if [[ $failures -ne 0 ]]; then
  printf '\ntest-sample-shell-memory: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'test-sample-shell-memory: all checks passed (%d report cases)\n' "$cases"
