#!/usr/bin/env bash
# Sample the live shell's memory read-only and report growth per class.
#
# Resolving which process is the shell reads the runner's lock file and the
# Quickshell instance list once. Every sample after that is /proc alone. Nothing
# here signals, restarts or drives the shell, so it is safe to leave running
# across a whole session. It is a diagnostic tool, not a validation check:
# scripts/validate drives it through scripts/test-sample-shell-memory.sh, whose
# --report cases read a TSV and need no running shell and whose pid-resolution
# cases run against a lock file and an instance list the test writes.
#
#   scripts/sample-shell-memory.sh                 sample until interrupted
#   scripts/sample-shell-memory.sh --hours 26      sample for 26 hours
#   scripts/sample-shell-memory.sh --report FILE   summarise an existing log
#
# The log is one TSV row per sample. Every row carries the sampled pid with the
# process start time that tells one session from the next reusing that pid.
#
# Output protocol, pinned by scripts/test-sample-shell-memory.sh: every refusal
# and every report line begins with a key=value field, English follows on its own
# line. Refusals exit 2 for a bad invocation, an unusable header or a shell that
# cannot be resolved, and 1 for a log that cannot be read as one session.
# Resolution refuses shell=not-running when $XDG_RUNTIME_DIR/vgsh.lock is
# missing, holds no pid on its first line or names a pid with no process, and
# shell=unlisted when `qs list` does not list that pid under this checkout's
# shell. --report reports the newest session in
# the log alone and emits, for that session: one mark= line for each of 1 h, 8 h,
# 24 h of uptime and the last sample; one rate=window line over the session's
# whole logged span; and one rate= line for each consecutive pair of marks. Every
# rate names the uptimes it spans and is gated on the rate floor.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2

INTERVAL=60
HOURS=0
LOG=""
REPORT=""
SHELL_DIR="$repo_root/shell"
LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vgsh.lock"

# The shortest span that can carry a rate. Per-minute deltas swing between
# negative and several megabytes, so anything shorter reports sampling noise.
RATE_FLOOR_S=600
# A mark is filled only by a sample this close to it, so a mark is never answered
# by a sample hours away. Fixed: a tolerance derived from the log's own spacing
# grows without bound around a gap, which is exactly when it must not.
MARK_TOLERANCE_S=300

# Every refusal in one place. $1 is the key=value first line, the rest is English.
refuse() {
  local status="$1" first="$2"
  shift 2
  printf 'sample-shell-memory: %s\n' "$first" >&2
  if [[ $# -gt 0 ]]; then
    printf '  %s\n' "$@" >&2
  fi
  exit "$status"
}

usage() {
  cat <<'USAGE'
Usage: sample-shell-memory.sh [--interval SECONDS] [--hours N] [--log FILE]
       sample-shell-memory.sh --report FILE

  --interval    seconds between samples (default 60)
  --hours       stop after N hours (default: run until interrupted)
  --log         where to append samples (default ~/.cache/vgs/memory-samples.tsv)
  --report      summarise an existing log and exit

The sampled process is the shell bin/vgsh run started in this session: the pid
in $XDG_RUNTIME_DIR/vgsh.lock, confirmed against `qs list` for this checkout.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval | --hours | --log | --report)
      [[ $# -ge 2 ]] || refuse 2 "missing-value=$1" "This option takes a value."
      case "$1" in
        --interval) INTERVAL="$2" ;;
        --hours) HOURS="$2" ;;
        --log) LOG="$2" ;;
        --report) REPORT="$2" ;;
      esac
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) refuse 2 "unknown-argument=$1" "See --help for the accepted options." ;;
  esac
done

[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -gt 0 ]] ||
  refuse 2 "bad-interval=$INTERVAL" "Seconds between samples must be a positive integer."
[[ "$HOURS" =~ ^[0-9]+$ ]] ||
  refuse 2 "bad-hours=$HOURS" "Hours to sample for must be a non-negative integer."

COLUMNS_HEADER=$'epoch\tpid\tsession\tuptime_s\trss_kb\tanon_kb\tfile_kb\tswap_kb'
COLUMNS_HEADER+=$'\tthp_kb\thwm_kb\tjsheap_kb\tjit_kb\tgpu_kb\tthreads\tfds\tmaps\tcpu_ticks'

# Both readers of a log share this prelude, so neither can resolve a column name
# the header does not carry. Composing the session key here keeps one definition
# of what identifies a session. Each program's END must honour `refused`, because
# awk runs END after exit and END would otherwise replace the status.
# shellcheck disable=SC2016  # awk source: $ is awk's field operator, not shell expansion
AWK_PRELUDE='
  NR == 1 {
    for (i = 1; i <= NF; i++) col[$i] = i
    split("epoch pid session uptime_s rss_kb anon_kb thp_kb hwm_kb", need, " ")
    for (i in need)
      if (!(need[i] in col)) missing = missing (missing == "" ? "" : ",") need[i]
    if (missing != "") {
      printf "sample-shell-memory: header-missing-column=%s\n", missing > "/dev/stderr"
      print "  The log header must name every column this reads." > "/dev/stderr"
      # 3, not 2: awk exits 2 on an input it cannot open, and a caller that
      # cannot tell the two apart must either swallow one or invent a guard.
      refused = 3
      exit refused
    }
    next
  }
  function session_key() { return $(col["pid"]) ":" $(col["session"]) }
'

# Report from a finished log. Reads nothing from the live process, so it works
# after the sampled session has ended and needs no lock file or instance list.
report_baseline() {
  local log="$1" rc=0
  # -f as well as -r: a directory is readable and would reach awk as an input it
  # cannot use.
  [[ -f "$log" && -r "$log" ]] ||
    refuse 2 "unreadable-log=$log" "The report reads an existing sample log."
  awk -F'\t' -v floor="$RATE_FLOOR_S" -v tol="$MARK_TOLERANCE_S" "$AWK_PRELUDE"'
    {
      # pid alone does not identify a session: the kernel reuses pids, and
      # the runner restarts the shell. The start time separates them.
      key = session_key()
      if (!(key in seen)) { seen[key] = 1; keys[++nk] = key }
      n = ++count[key]
      up[key, n] = $(col["uptime_s"]) + 0
      rss[key, n] = $(col["rss_kb"]) + 0
      anon[key, n] = $(col["anon_kb"]) + 0
      thp[key, n] = $(col["thp_kb"]) + 0
      hwm[key, n] = $(col["hwm_kb"]) + 0
      ep = $(col["epoch"]) + 0
      if (!(key in lastep) || ep > lastep[key]) lastep[key] = ep
      rows++
    }
    function mib(kb) { return sprintf("%.0f", kb / 1024) }
    # The latest sample at or before target, but only when the session actually
    # reached the mark and a sample landed within the fixed tolerance of it.
    # Without both tests a log ending at 0.5 h fills 1 h, 8 h and 24 h from one
    # sample, and a log with a hole fills two marks from the sample beside it.
    function at(target,   i, best) {
      if (u[n] < target) return -1
      best = 0
      for (i = 1; i <= n; i++)
        if (u[i] <= target && (best == 0 || u[i] > u[best])) best = i
      if (best == 0) return -2
      if (target - u[best] > tol) return -2
      return best
    }
    function markrow(label, idx) {
      if (idx == -1) { printf "mark=%s status=not-reached\n", label; return }
      if (idx == -2) { printf "mark=%s status=no-sample-within tolerance_s=%d\n", label, tol; return }
      printf "mark=%s uptime_s=%d rss_mib=%s anon_mib=%s thp_mib=%s\n",
        label, u[idx], mib(r[idx]), mib(a[idx]), mib(t[idx])
    }
    # Naming the uptimes a rate spans keeps a label from implying a span it did
    # not measure. A span under the floor reports the refusal rather than a
    # number, at every label.
    function raterow(label, ia, ib,   d) {
      d = u[ib] - u[ia]
      if (d < floor) {
        printf "rate=%s status=span-under-floor span_s=%d floor_s=%d\n", label, d, floor
        return
      }
      printf "rate=%s from_uptime_s=%d to_uptime_s=%d span_s=%d rss_mib_h=%.1f anon_mib_h=%.1f\n",
        label, u[ia], u[ib], d,
        (r[ib] - r[ia]) / 1024 / (d / 3600), (a[ib] - a[ia]) / 1024 / (d / 3600)
    }
    END {
      if (refused) exit refused
      if (rows == 0) {
        print "sample-shell-memory: no-samples=0" > "/dev/stderr"
        print "  The log holds a header and no sample rows." > "/dev/stderr"
        exit 1
      }
      # Newest session by its last sample. Reporting every session as one series
      # reads the uptime reset at a restart as a huge negative rate.
      pick = keys[1]
      for (i = 2; i <= nk; i++) if (lastep[keys[i]] > lastep[pick]) pick = keys[i]
      n = count[pick]
      for (i = 1; i <= n; i++) {
        u[i] = up[pick, i]; r[i] = rss[pick, i]
        a[i] = anon[pick, i]; t[i] = thp[pick, i]; h[i] = hwm[pick, i]
      }
      printf "session=%s samples=%d\n", pick, n
      printf "excluded=%d rows=%d\n", nk - 1, rows - n
      # Two samples of one session can only run forward. Anything else means the
      # rows were interleaved or edited, and every rate below would be fiction.
      for (i = 2; i <= n; i++)
        if (u[i] < u[i - 1]) {
          printf "sample-shell-memory: uptime-backwards=%d after=%d row=%d\n",
            u[i], u[i - 1], i > "/dev/stderr"
          print "  Refusing every mark and rate: the session rows are not in order." > "/dev/stderr"
          exit 1
        }
      printf "span=%d..%d\n", u[1], u[n]
      idx[1] = at(3600); idx[2] = at(8 * 3600); idx[3] = at(24 * 3600); idx[4] = n
      split("1h|8h|24h|last", lab, "|")
      for (i = 1; i <= 4; i++) markrow(lab[i], idx[i])
      peak = 0
      for (i = 1; i <= n; i++) if (r[i] > peak) { peak = r[i]; pi = i }
      # The logged peak is not VmHWM: sampling starts when the operator starts it
      # and can miss the high-water mark entirely. VmHWM is the hwm_kb column.
      printf "logged-peak=%s at_uptime_s=%d\n", mib(peak), u[pi]
      printf "high-water=%s\n", mib(h[n])
      # One rate over the session span the log actually covers. A session the
      # sampler joined late fills only the last mark, so mark-to-mark rates alone
      # would leave such a log with no rate at all.
      raterow("window", 1, n)
      previ = 0
      for (i = 1; i <= 4; i++) {
        if (idx[i] < 0) continue
        if (previ > 0) raterow(prevl ".." lab[i], previ, idx[i])
        prevl = lab[i]; previ = idx[i]
      }
    }
  ' "$log" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) exit 2 ;;                      # header refusal, named by the prelude
    1) exit 1 ;;                      # no samples, or rows out of order
    *) refuse 2 "unreadable-log=$log" "The report could not read this sample log." ;;
  esac
}

if [[ -n "$REPORT" ]]; then
  report_baseline "$REPORT"
  exit 0
fi

# Everything below is the sampling path. It is the only part that reads the
# lock file, runs qs or touches the checkout, so --report stays runnable from a
# copy that has no repository beside it.

# /proc/<pid>/stat's comm field holds spaces and parens, so fields are counted
# after the last ')': index 1 is field 3, so field 22 (starttime) is index 20 and
# utime/stime (fields 14, 15) are indices 12 and 13.
stat_fields() {
  local stat
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  stat="${stat##*") "}"
  # shellcheck disable=SC2086  # deliberate word splitting of a numeric field list
  set -- $stat
  [[ $# -ge 20 ]] || return 1
  printf '%s\n' "$@"
}

# Resolve the live shell from the runner's lock file. bin/vgsh run holds the
# lock for the life of the shell and writes its own pid as the file's only line;
# it execs qs, so that pid is the shell's. The pid must then appear in the
# Quickshell instance list for this checkout's shell: a stale lock whose pid the
# kernel reused, or a shell started from another checkout, would otherwise yield
# a plausible log that describes nothing. The instance list is stdout JSON; when
# no instance runs, qs prints a sentence there instead, which reads as an empty
# list and refuses the same way.
resolve_pid() {
  local first="" listing rc=0 verdict
  [[ -f "$LOCK" ]] ||
    refuse 2 "shell=not-running lock=$LOCK" "No runner lock file. Start the shell with bin/vgsh run."
  [[ -r "$LOCK" ]] ||
    refuse 2 "lock-unreadable=$LOCK" "The runner lock file cannot be read."
  # read returns non-zero on an empty file; the pattern test is what judges the line.
  IFS= read -r first <"$LOCK" || true
  [[ "$first" =~ ^[0-9]+$ ]] ||
    refuse 2 "shell=not-running lock=$LOCK" "The lock file's first line is not a pid."
  [[ -d "/proc/$first" ]] ||
    refuse 2 "shell=not-running lock=$LOCK" "Pid $first from the lock file has no process."
  command -v qs >/dev/null 2>&1 ||
    refuse 2 "qs=missing" "Quickshell is not installed, so no instance list can confirm the pid."
  listing="$(qs list -p "$SHELL_DIR" -j)" || rc=$?
  [[ "$rc" == 0 ]] ||
    refuse 2 "qs-list-failed=$rc path=$SHELL_DIR" "The instance list could not be read; its error is above."
  verdict="$(LISTING="$listing" WANT="$first" python3 -c '
import json, os
try:
    entries = json.loads(os.environ["LISTING"])
except ValueError:
    entries = []
if not isinstance(entries, list):
    entries = []
pids = {str(e.get("pid")) for e in entries if isinstance(e, dict)}
print("listed" if os.environ["WANT"] in pids else "unlisted")
')" || refuse 2 "qs-list-unjudged=$SHELL_DIR" "The instance list could not be judged; the error is above."
  case "$verdict" in
    listed) ;;
    unlisted)
      refuse 2 "shell=unlisted pid=$first path=$SHELL_DIR" \
        "The lock names pid $first, but qs list does not list it under this checkout's shell." \
        "The listing was:" "$listing" ;;
    *) refuse 2 "internal=verdict value=$verdict" "The listing judge printed neither listed nor unlisted." ;;
  esac
  printf '%s\n' "$first"
}

PID="$(resolve_pid)"
mapfile -t FIELDS < <(stat_fields "$PID")
[[ ${#FIELDS[@]} -ge 20 ]] ||
  refuse 2 "pid-gone=$PID" "The process left before the first sample."
SESSION="${FIELDS[19]}"
CLK_TCK="$(getconf CLK_TCK)"

if [[ -z "$LOG" ]]; then
  LOG="${XDG_CACHE_HOME:-$HOME/.cache}/vgs/memory-samples.tsv"
fi
# The log path is an argument, so every way it can be unusable is a bad
# invocation and refuses with a key, not a raw mkdir, redirection or awk error.
# The append guard below keeps its own refusal as the fallback for a read that
# fails after these tests.
if ! log_dir="$(dirname -- "$LOG")"; then
  refuse 2 "unwritable-log=$LOG" "Its directory name could not be resolved."
fi
mkdir -p -- "$log_dir" 2>/dev/null ||
  refuse 2 "unwritable-log=$LOG" "Its directory $log_dir could not be created."
[[ -w "$log_dir" ]] ||
  refuse 2 "unwritable-log=$LOG" "Its directory $log_dir cannot be written to."
if [[ -e "$LOG" ]]; then
  [[ -f "$LOG" ]] ||
    refuse 2 "unwritable-log=$LOG" "The log path exists and is not a regular file."
  [[ -w "$LOG" ]] ||
    refuse 2 "unwritable-log=$LOG" "The existing log cannot be appended to."
  # Readability belongs here beside the other two: the append guard's awk does
  # refuse an unreadable log, but only after printing its own fatal error, and
  # every refusal this script makes opens with its key.
  [[ -r "$LOG" ]] ||
    refuse 2 "unreadable-log=$LOG" "The existing log could not be read to check whose session it holds."
fi
if [[ -s "$LOG" ]]; then
  # Appending a second session's rows to a foreign log is how a 100 MiB/h leak
  # reports as 0.0 MiB/h. Refuse rather than extend someone else's series. The
  # shared prelude means a log whose header this cannot read is refused by name
  # here too, rather than comparing field zero against itself.
  guard_rc=0
  last_id="$(awk -F'\t' "$AWK_PRELUDE"'
               { id = session_key() }
               END { if (refused) exit refused; print id }' "$LOG")" || guard_rc=$?
  case "$guard_rc" in
    0) ;;
    3) exit 2 ;;                      # header refusal, named by the prelude
    *) refuse 2 "unreadable-log=$LOG" \
         "The existing log could not be read to check whose session it holds." ;;
  esac
  [[ -z "$last_id" || "$last_id" == "$PID:$SESSION" ]] ||
    refuse 2 "foreign-log=$last_id this=$PID:$SESSION path=$LOG" \
      "Pass --log for a new file rather than extending another session's series."
else
  printf '%s\n' "$COLUMNS_HEADER" >"$LOG"
fi

# One row of /proc reads. Classifying smaps by mapping name separates the QML
# JavaScript heap and the GPU driver's mappings from plain anonymous memory,
# which is what the native heap grows into. Everything else Qt maps through a
# memfd, and every bracketed kernel mapping, falls in the file column.
sample_row() {
  local cpu_ticks threads fds maps_before maps_after hwm uptime_s row counted floor
  local -a f=()
  mapfile -t f < <(stat_fields "$PID")
  [[ ${#f[@]} -ge 20 ]] || return 1
  cpu_ticks=$((f[11] + f[12]))
  # Uptime from the same start time the identity column carries, so the two
  # cannot disagree. /proc/uptime is the system clock this is measured against.
  uptime_s="$(awk -v st="${f[19]}" -v hz="$CLK_TCK" '{printf "%d", $1 - st / hz; exit}' /proc/uptime)" || return 1
  threads="$(awk '/^Threads:/ {print $2}' "/proc/$PID/status")" || return 1
  hwm="$(awk '/^VmHWM:/ {print $2}' "/proc/$PID/status")" || return 1
  # An unreadable descriptor directory writes an empty field. Reporting 0 there
  # would be indistinguishable from a process holding no descriptors.
  if fds="$(find "/proc/$PID/fd" -mindepth 1 -maxdepth 1 2>/dev/null)"; then
    fds="$(printf '%s' "$fds" | grep -c . || true)"
  else
    fds=""
  fi
  maps_before="$(grep -c . "/proc/$PID/maps")" || return 1
  # The smaps read exits 0 on a truncated file, so a process dying partway
  # through yields a plausible short row whose totals report a leak as
  # shrinkage. The row carries its own mapping count for the check below.
  row="$(awk -v ts="$(date +%s)" -v pid="$PID" -v sess="$SESSION" -v up="$uptime_s" \
    -v cpu="$cpu_ticks" -v thr="$threads" -v hwm="$hwm" -v fds="$fds" '
    /^[0-9a-f]+-[0-9a-f]+ / { name = $6; nmaps++; next }
    /^Rss:/ {
      rss += $2
      if (name == "") anon += $2
      else if (name ~ /JSGCHeap/) js += $2
      else if (name ~ /JITCode|JSVMStack/) jit += $2
      else if (name ~ /nvidia|renderD|\/dri\//) gpu += $2
      else file += $2
      next
    }
    /^Swap:/ { swap += $2; next }
    /^AnonHugePages:/ { thp += $2; next }
    END {
      printf "%d\t%d\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\n",
        nmaps, ts, pid, sess, up, rss, anon, file, swap, thp, hwm, js, jit, gpu, thr, fds, nmaps, cpu
    }
  ' "/proc/$PID/smaps")" || return 1
  maps_after="$(grep -c . "/proc/$PID/maps")" || return 1
  counted="${row%%$'\t'*}"
  # The shell maps and unmaps while this reads, so the two bracketing counts
  # differ legitimately by a few. Truncation is not a few: require the counted
  # mappings to reach the smaller bracket.
  floor="$maps_before"
  [[ "$maps_after" -lt "$floor" ]] && floor="$maps_after"
  [[ "$counted" -ge "$floor" ]] || return 1
  printf '%s\n' "${row#*$'\t'}"
}

deadline=0
if [[ "$HOURS" -gt 0 ]]; then
  deadline=$(($(date +%s) + HOURS * 3600))
fi

printf 'sample-shell-memory: sampling=%s:%s interval_s=%s log=%s\n' \
  "$PID" "$SESSION" "$INTERVAL" "$LOG" >&2

stopped=0
while true; do
  # A row that fails ends the loop, not the script: the closing report is the
  # point of the run. Why it failed is decided below, not here, because the
  # process exiting and a row that would not hold together are different events
  # and reporting one as the other hides the real reason.
  if ! row="$(sample_row)"; then
    stopped=1
    break
  fi
  printf '%s\n' "$row" >>"$LOG"
  if [[ "$deadline" -gt 0 && "$(date +%s)" -ge "$deadline" ]]; then
    break
  fi
  sleep "$INTERVAL"
  if [[ ! -d "/proc/$PID" ]]; then
    stopped=1
    break
  fi
done

if [[ "$stopped" == 1 ]]; then
  if [[ ! -d "/proc/$PID" ]]; then
    printf 'sample-shell-memory: pid-exited=%s\n' "$PID" >&2
  else
    printf 'sample-shell-memory: row-rejected=%s\n' "$PID" >&2
    printf '  A sample could not be read whole while the process is still running; the log ends before it.\n' >&2
  fi
fi
report_baseline "$LOG"
