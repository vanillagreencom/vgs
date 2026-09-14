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
# Only pid resolution is out of reach here: it reads the instance registry, so
# it needs a running shell. Everything sample_row does is /proc reads against
# whatever pid it holds, so the row builder is driven below against a process
# this file spawns. The log-path refusals sit past pid resolution, so they are
# untested here and were verified by hand against the live shell; their keys are
# unwritable-log= for a path that cannot be written and unreadable-log= for a log
# that cannot be read, the latter raised from a different call than the report's.
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

# A bad header has one cause, and the report must name only that one. When the
# prelude shared awk's own status for an unopenable input, a perfectly readable
# log with a bad header also drew an unreadable-log= refusal, telling the reader
# the file could not be read when it could.
report_case "a bad header is reported as one cause, not two" no-rss-column err "header-missing-column=rss_kb" 2
expect_absent "$err" "unreadable-log=" "a bad header is reported as one cause, not two"
ok "a bad header is reported as one cause, not two"

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

# Drive the row builder itself. sample_row needs no shell and no registry: it
# reads /proc for whatever pid it holds. The two functions are lifted out of the
# script under test rather than restated here, so a change to either is what
# this case runs.
row_builder="$tmp/row-builder.sh"
extract_functions() {
  awk '/^(stat_fields|sample_row)\(\) \{/ { keep = 1 } keep { print } /^\}$/ { keep = 0 }' "$1"
}

drive_sample_row() {
  local script="$1"
  local victim rc=0
  sleep 120 &
  victim=$!
  # The subshell keeps PID, SESSION and CLK_TCK out of the suite's own scope and
  # lets a failed row return without ending the run.
  row="$(
    set -euo pipefail
    # A planted defect makes the copy complain here; that is the control's
    # evidence, not a suite failure, so it stays out of the run's output.
    exec 2>"$tmp/row-stderr"
    # 3 is the liveness status the controls read: a copy that could not be
    # lifted or parsed proves nothing, and bash parses a function body when it
    # sources it, so a mutation that is a syntax error lands here rather than
    # looking like the row builder refusing a row.
    extract_functions "$script" >"$row_builder" || exit 3
    # shellcheck source=/dev/null
    source "$row_builder" || exit 3
    declare -F stat_fields >/dev/null || exit 3
    declare -F sample_row >/dev/null || exit 3
    PID="$victim"
    CLK_TCK="$(getconf CLK_TCK)"
    mapfile -t f < <(stat_fields "$PID")
    SESSION="${f[19]}"
    export PID SESSION CLK_TCK
    sample_row
  )" || rc=$?
  kill "$victim" 2>/dev/null || true
  wait "$victim" 2>/dev/null || true
  return "$rc"
}

label="the row builder reads a live process and writes one full row"
rc=0
drive_sample_row "$sampler" || rc=$?
if [[ "$rc" != 0 ]]; then
  fail "$label" "sample_row exited $rc against a process the test owns"
else
  # The row must carry exactly the columns the header names; the leading mapping
  # count is stripped before the row is returned.
  if ! row_fields="$(awk -F'\t' '{print NF; exit}' <<<"$row")"; then
    row_fields="unreadable"
  fi
  [[ "$row_fields" == "$head_count" ]] ||
    fail "$label" "row carries $row_fields fields, the header names $head_count"
fi
ok "$label"

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

# Apply one substitution to a copy of the script. Non-zero when the text is not
# there exactly once, so a control whose anchor has drifted reports itself as
# unproven rather than passing on a copy it never changed.
mutate() {
  python3 - "$1" "$2" "$3" <<'MUTATE_PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
if text.count(old) != 1:
    sys.exit(1)
open(path, "w").write(text.replace(old, new))
MUTATE_PY
}

# One liveness verdict for every control, whichever surface it plants into. A
# mutation that did not apply and a copy that did not run both prove nothing,
# and saying so is what keeps a dead mutant from satisfying a control's pass
# condition. Statuses 2 and 3 are reserved for those two; no surface under test
# returns either.
UNPROVEN_MUTATION="the mutation did not apply, so the rule is unproven"
UNPROVEN_MUTANT="the mutant did not run, so the rule is unproven"

# Build a mutated copy from a list of from/to pairs. 2 when a pair did not apply.
build_mutant() {
  local mutant="$1"
  shift
  cp "$sampler" "$mutant"
  while [[ $# -ge 2 ]]; do
    mutate "$mutant" "$1" "$2" || return 2
    shift 2
  done
  chmod +x "$mutant"
}

# A control on the report surface. WANT says what the owning case asserts:
# `present` for a case that expects EXPECT in its stream, `absent` for one that
# expects it to stay away. Either way the control requires the defect to move
# the case, so a control that changes nothing fails.
# ALIVE is the clause that proves THIS control's rule was reached, named per
# control rather than shared. A token any refusal satisfies lets a mutation that
# refuses before the rule runs pass without ever reaching it, so each control
# names a clause its own fixture produces only by getting that far.
report_control() {
  local label="$1" want="$2" alive="$3" fixture="$4" stream="$5" expect="$6" status="$7"
  shift 7
  local mutant="$tmp/mutant.sh" rcm=0
  build_mutant "$mutant" "$@" || { fail "$label" "$UNPROVEN_MUTATION"; return; }
  local log="$tmp/log.tsv"
  rm -f -- "${tmp:?}/log.tsv"
  build_fixture "$fixture" "$log"
  run_report "$mutant" "$log"
  if [[ "$out" != *"$alive"* && "$err" != *"$alive"* ]]; then
    fail "$label" "$UNPROVEN_MUTANT"
    return
  fi
  local body="$out"
  [[ "$stream" == err ]] && body="$err"
  case "$want" in
    present)
      [[ "$rc" == "$status" && "$body" == *"$expect"* ]] &&
        fail "$label" "the defect did not redden its case: still saw $expect at exit $status" ;;
    absent)
      [[ "$body" == *"$expect"* ]] ||
        fail "$label" "the defect did not redden its case: $expect stayed away" ;;
  esac
  ok "$label"
}

# A control on the row builder. WANT is what the owning case asserts about the
# builder: `rejects` for a case where sample_row must refuse the row, `accepts`
# for the inverted control that shows which test did the refusing.
row_control() {
  local label="$1" want="$2"
  shift 2
  local mutant="$tmp/row-mutant.sh" rcm=0
  build_mutant "$mutant" "$@" || { fail "$label" "$UNPROVEN_MUTATION"; return; }
  drive_sample_row "$mutant" || rcm=$?
  if [[ "$rcm" == 3 ]]; then
    fail "$label" "$UNPROVEN_MUTANT"
    return
  fi
  case "$want" in
    rejects)
      [[ "$rcm" != 0 ]] ||
        fail "$label" "the defect did not redden its case: the row builder still accepted the row" ;;
    accepts)
      [[ "$rcm" == 0 ]] ||
        fail "$label" "the control could not show which test refused the row: still refused, exit $rcm" ;;
  esac
  ok "$label"
}

# The control of the controls. An UNMUTATED copy through the report path must
# still produce its case's expected line: if it does not, every control above
# passes for the wrong reason and proves nothing.
unmutated_check() {
  local label="a copy with nothing planted still passes its case"
  local mutant="$tmp/mutant.sh"
  build_mutant "$mutant" || { fail "$label" "$UNPROVEN_MUTATION"; return; }
  local log="$tmp/log.tsv"
  rm -f -- "${tmp:?}/log.tsv"
  build_fixture spans-8h "$log"
  run_report "$mutant" "$log"
  [[ "$rc" == 0 ]] || fail "$label" "expected exit 0 from an unmutated copy, got $rc"
  expect_contains "$out" "mark=1h uptime_s=3600" "$label"
  ok "$label"
}
unmutated_check

report_control "removing the mark-reached test reddens the not-reached case" \
  present 'session=' short out "mark=1h status=not-reached" 0 \
  'if (u[n] < target) return -1' 'if (0) return -1'

report_control "removing the mark tolerance reddens the gap case" \
  present 'session=' hole out "mark=1h status=no-sample-within tolerance_s=300" 0 \
  'if (target - u[best] > tol) return -2' 'if (0) return -2'

# shellcheck disable=SC2016  # awk source: $ is awk's field operator, not shell expansion
report_control "merging sessions reddens the newest-session case" \
  present 'session=' two-sessions out "session=200:22 samples=481" 0 \
  'function session_key() { return $(col["pid"]) ":" $(col["session"]) }' \
  'function session_key() { return "merged" }'

report_control "removing the order test reddens the uptime-backwards case" \
  present 'session=' backwards err "uptime-backwards=0 after=240 row=6" 1 \
  'if (u[i] < u[i - 1]) {' 'if (0) {'

report_control "removing the rate floor reddens the span-under-floor case" \
  present 'session=' under-floor out "rate=1h..last status=span-under-floor" 0 \
  'if (d < floor) {' 'if (0) {'

# shellcheck disable=SC2016  # awk source: $ is awk's field operator, not shell expansion
report_control "shifting the header map reddens the column-by-name case" \
  present 'session=' spans-8h out "mark=1h uptime_s=3600" 0 \
  'for (i = 1; i <= NF; i++) col[$i] = i' 'for (i = 1; i <= NF; i++) col[$i] = i + 1'

report_control "drifting the 24 h target reddens the far-mark case" \
  present 'session=' spans-24h out "mark=24h uptime_s=86400" 0 \
  'idx[3] = at(24 * 3600)' 'idx[3] = at(25 * 3600)'

report_control "dropping the window rate reddens the joined-late case" \
  present 'session=' late-start out "rate=window from_uptime_s=273600" 0 \
  'raterow("window", 1, n)' ''

# Putting the prelude back on awk's own status makes a bad header also report a
# cause that is not true, so the case asserting that second refusal stays away
# is what this control must move.
report_control "putting the prelude back on awk's status reddens the one-cause case" \
  absent 'header-missing-column=rss_kb' no-rss-column err "unreadable-log=" 2 \
  'refused = 3' 'refused = 2'

# Stand in for the tab escape failing to expand: a pattern that cannot match
# leaves the mapping count in the row, so the arithmetic test rejects every one.
# shellcheck disable=SC2016  # bash source of the script under test, quoted verbatim as its anchor
row_control "breaking the field split reddens the row-builder case" rejects \
  'counted="${row%%$'"'"'\t'"'"'*}"' 'counted="${row%%NO_SUCH_SEPARATOR*}"'

# The truncation floor guards a short read, which cannot be staged against a
# healthy process: /proc hands back the whole file. Making the counter
# under-report stands in for the truncation, and with it the floor must reject
# the row. That is the guarantee, so its control removes the floor as well: with
# both gone the under-counted row is accepted, which is what must not happen.
row_control "an under-counted mapping read is rejected" rejects \
  'nmaps++; next' 'next'

# shellcheck disable=SC2016  # bash source of the script under test, quoted verbatim as its anchor
row_control "removing the truncation floor reddens the under-counted case" accepts \
  'nmaps++; next' 'next' \
  '[[ "$counted" -ge "$floor" ]] || return 1' ':'

if [[ $failures -ne 0 ]]; then
  printf '\ntest-sample-shell-memory: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'test-sample-shell-memory: all checks passed (%d report cases)\n' "$cases"
