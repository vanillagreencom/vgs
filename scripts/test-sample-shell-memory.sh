#!/usr/bin/env bash
# Drive scripts/sample-shell-memory.sh --report and its argument refusals. The
# report mode needs no live shell: it reads a TSV and prints keyed lines, so every
# case here is a fixture log. Sampling itself needs a running shell and is not
# exercised; scripts/check-validation-inventory.py records that exemption.
#
# Each case pins the refusal or report key, the value it carries, and the exit
# status. The controls at the end plant one defect per report rule and require
# the case that rule owns to go red.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
sampler="$repo_root/scripts/sample-shell-memory.sh"

tmp="$(mktemp -d)" || {
  printf 'test-sample-shell-memory: could not create a temporary directory\n' >&2
  exit 1
}
trap 'rm -rf "${tmp:?}"' EXIT INT TERM

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
    # Starts at 76 h, so every mark is long past and no sample sits near one.
    late-start) write_log "$2" 100 11 273600 60 20 ;;
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
a mark the session passed with no sample near it is not filled|late-start|out|mark=1h status=no-sample-within|0
a span under the rate floor carries no rate|under-floor|out|rate=1h..last status=span-under-floor|0
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

# The negative of the session rule: a single-session log excludes nothing.
report_case "a single-session log excludes nothing" spans-8h out "excluded=0 rows=0" 0
ok "a single-session log excludes nothing"

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

# The report names the process high-water mark separately from the peak among
# logged samples, which starts only when the operator starts sampling. The
# fixture's hwm_kb is 3000000 kB while its logged peak is far below that, so a
# report printing one for the other cannot pass both assertions.
report_case "the report separates the high-water mark from the logged peak" spans-8h out "high-water=2930" 0
expect_contains "$out" "logged-peak=773" "the report separates the high-water mark from the logged peak"
ok "the report separates the high-water mark from the logged peak"

# The writer states the column order twice: the header constant and the printf
# in its awk block. Both are read out of the script under test rather than
# restated here, so a column added to one and not the other is caught. This pins
# the count only; the order within it is not checked.
header_body="$(sed -n "s/^COLUMNS_HEADER+*=\\\$'\(.*\)'$/\1/p" "$sampler" | tr -d '\n')"
head_count="$(( $(grep -o '\\t' <<<"$header_body" | grep -c .) + 1 ))"
if ! fmt_count="$(awk '/printf "%d\\t%s\\t%s/ { print; exit }' "$sampler" | grep -o '%[ds]' | grep -c .)"; then
  fmt_count=0
fi
[[ "$head_count" == "$fmt_count" ]] ||
  fail "the header and the row writer declare the same column count" \
    "header names $head_count columns, the row printf writes $fmt_count"
[[ "$head_count" -gt 1 ]] ||
  fail "the header and the row writer declare the same column count" \
    "the extractor read $head_count columns from the header, so it is broken rather than the script sparse"
ok "the header and the row writer declare the same column count"

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

# Each control keeps the matched text and removes the behaviour behind it, then
# requires the case that rule owns to go red. A control that cannot be planted is
# a failure: it would leave its rule unproven.
control() {
  local label="$1" from="$2" to="$3" fixture="$4" stream="$5" expect="$6" status="$7"
  local mutant="$tmp/mutant.sh"
  cp "$sampler" "$mutant"
  python3 - "$mutant" "$from" "$to" <<'PY' || { fail "$label" "the mutation did not apply"; return; }
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
if text.count(old) != 1:
    sys.exit(1)
open(path, "w").write(text.replace(old, new))
PY
  chmod +x "$mutant"
  local log="$tmp/log.tsv"
  rm -f -- "${tmp:?}/log.tsv"
  build_fixture "$fixture" "$log"
  run_report "$mutant" "$log"
  local body="$out"
  [[ "$stream" == err ]] && body="$err"
  if [[ "$rc" == "$status" && "$body" == *"$expect"* ]]; then
    fail "$label" "the defect did not redden its case: still saw $expect at exit $status"
  else
    printf '  ok    %s\n' "$label"
  fi
}

control "removing the mark-reached test reddens the not-reached case" \
  'if (u[n] < target) return -1' 'if (0) return -1' \
  short out "mark=1h status=not-reached" 0

control "removing the mark tolerance reddens the no-sample-within case" \
  'if (target - u[best] > tol) return -2' 'if (0) return -2' \
  late-start out "mark=1h status=no-sample-within" 0

# shellcheck disable=SC2016  # awk source: $ is awk's field operator, not shell expansion
control "merging sessions reddens the newest-session case" \
  'key = $(col["pid"]) ":" $(col["session"])' 'key = "merged"' \
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

if [[ $failures -ne 0 ]]; then
  printf '\ntest-sample-shell-memory: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'test-sample-shell-memory: all checks passed (%d report cases)\n' "$cases"
