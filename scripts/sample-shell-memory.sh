#!/usr/bin/env bash
# Sample the live shell's memory read-only and report growth per class.
#
# Every read is /proc. Nothing here signals, restarts or drives the shell, so it
# is safe to leave running across a whole session. It is a diagnostic tool, not a
# validation check: scripts/validate exercises only its --report mode, through
# scripts/test-sample-shell-memory.sh.
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
# line. Refusals exit 2 for a bad invocation and 1 for a log that cannot be read
# as one session. --report reads the header for its column positions, reports the
# newest session in the log alone, and emits one mark= line for each of 1 h, 8 h,
# 24 h of uptime and the last sample, then one rate= line for each consecutive
# pair of marks that both exist and span at least the rate floor.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
# shellcheck source=scripts/lib/session-snapshot.sh
source "$repo_root/scripts/lib/session-snapshot.sh"

INTERVAL=60
HOURS=0
LOG=""
REPORT=""
SHELL_PATH="$repo_root/quickshell/vshell/shell.qml"

# The shortest span that can carry a rate. Per-minute deltas swing between
# negative and several megabytes, so anything shorter reports sampling noise.
RATE_FLOOR_S=600
# A mark is filled only by a sample this close to it, so a mark is never answered
# by a sample hours earlier. Widened to twice the log's own sampling gap when it
# was taken at a coarser interval than this.
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
                              [--shell-path PATH]
       sample-shell-memory.sh --report FILE

  --interval    seconds between samples (default 60)
  --hours       stop after N hours (default: run until interrupted)
  --log         where to append samples (default ~/.cache/vshell/memory-samples.tsv)
  --shell-path  shell entrypoint whose running instance to sample
                (default: this checkout's quickshell/vshell/shell.qml)
  --report      summarise an existing log and exit
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval | --hours | --log | --shell-path | --report)
      [[ $# -ge 2 ]] || refuse 2 "missing-value=$1" "This option takes a value."
      case "$1" in
        --interval) INTERVAL="$2" ;;
        --hours) HOURS="$2" ;;
        --log) LOG="$2" ;;
        --shell-path) SHELL_PATH="$2" ;;
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

# Report from a finished log. Reads nothing from the live process, so it works
# after the sampled session has ended.
report_baseline() {
  local log="$1"
  [[ -r "$log" ]] || refuse 2 "unreadable-log=$log" "The report reads an existing sample log."
  awk -F'\t' -v floor="$RATE_FLOOR_S" -v tol="$MARK_TOLERANCE_S" '
    # Column positions come from the header, so a column added or moved in the
    # writer becomes a named miss here rather than a mislabelled number.
    NR == 1 {
      for (i = 1; i <= NF; i++) col[$i] = i
      split("epoch pid session uptime_s rss_kb anon_kb thp_kb", need, " ")
      for (i in need)
        if (!(need[i] in col)) missing = missing (missing == "" ? "" : ",") need[i]
      if (missing != "") {
        printf "sample-shell-memory: header-missing-column=%s\n", missing > "/dev/stderr"
        print "  The log header must name every column the report reads." > "/dev/stderr"
        # awk runs END after exit, and END would replace this status with its
        # own. The flag makes END stand aside instead.
        refused = 2
        exit refused
      }
      next
    }
    {
      # pid alone does not identify a session: the kernel reuses pids, and
      # vshell.service restarts the shell. The start time separates them.
      key = $(col["pid"]) ":" $(col["session"])
      if (!(key in seen)) { seen[key] = 1; keys[++nk] = key }
      n = ++count[key]
      up[key, n] = $(col["uptime_s"]) + 0
      rss[key, n] = $(col["rss_kb"]) + 0
      anon[key, n] = $(col["anon_kb"]) + 0
      thp[key, n] = $(col["thp_kb"]) + 0
      if ("hwm_kb" in col) hwm[key, n] = $(col["hwm_kb"]) + 0
      ep = $(col["epoch"]) + 0
      if (!(key in lastep) || ep > lastep[key]) lastep[key] = ep
      rows++
    }
    function mib(kb) { return sprintf("%.0f", kb / 1024) }
    # The latest sample at or before target, but only when the session actually
    # reached the mark and a sample landed within tolerance of it. Without both
    # tests a log ending at 0.5 h fills 1 h, 8 h and 24 h from one sample.
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
    # A rate needs two real marks and a span no shorter than the floor. Naming
    # the uptimes it spans keeps a label from implying a span it did not measure.
    function raterow(la, ia, lb, ib,   d) {
      d = u[ib] - u[ia]
      if (d < floor) {
        printf "rate=%s..%s status=span-under-floor span_s=%d floor_s=%d\n", la, lb, d, floor
        return
      }
      printf "rate=%s..%s from_uptime_s=%d to_uptime_s=%d span_s=%d rss_mib_h=%.1f anon_mib_h=%.1f\n",
        la, lb, u[ia], u[ib], d,
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
        a[i] = anon[pick, i]; t[i] = thp[pick, i]
        h[i] = hwm[pick, i]
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
      # A log taken at a coarser interval than the tolerance would never fill a
      # mark, so widen the tolerance to twice its own sampling gap.
      if (n > 1) {
        gap = (u[n] - u[1]) / (n - 1)
        if (2 * gap > tol) tol = 2 * gap
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
      if (h[n] > 0) printf "high-water=%s\n", mib(h[n])
      previ = 0
      for (i = 1; i <= 4; i++) {
        if (idx[i] < 0) continue
        if (previ > 0) raterow(prevl, previ, lab[i], idx[i])
        prevl = lab[i]; previ = idx[i]
      }
    }
  ' "$log"
}

if [[ -n "$REPORT" ]]; then
  report_baseline "$REPORT"
  exit 0
fi

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

# Resolve the live shell through the instance registry that bin/vshell owns, so
# this script states no second opinion on what a running shell is. The listing is
# scoped to one shell entrypoint; --shell-path addresses a shell launched from
# another checkout. Any count but one is a refusal: a wrong pid yields a
# plausible log that describes nothing.
resolve_pid() {
  local listing rc=0 count
  listing="$(vgs_snapshot_instances "$SHELL_PATH")" || rc=$?
  if [[ "$rc" == 2 ]]; then
    refuse 2 "no-registry=quickshell" "Quickshell is not installed, so there is no instance registry."
  fi
  [[ "$rc" == 0 ]] ||
    refuse 2 "registry-unreadable=$SHELL_PATH" "The registry error is above."
  # grep -c exits 1 on a listing with no lines, which is the real answer "none
  # running", so the count is read in condition position rather than assigned
  # bare: under errexit a bare assignment would end the run before the refusal
  # below could name the count.
  if ! count="$(printf '%s' "$listing" | grep -c .)"; then
    count=0
  fi
  [[ "$count" == 1 ]] ||
    refuse 2 "instance-count=$count path=$SHELL_PATH" \
      "Exactly one running instance can be sampled." \
      "Pass --shell-path for a shell launched from another checkout."
  printf '%s\n' "${listing%% *}"
}

PID="$(resolve_pid)"
mapfile -t FIELDS < <(stat_fields "$PID")
[[ ${#FIELDS[@]} -ge 20 ]] ||
  refuse 2 "pid-gone=$PID" "The process left before the first sample."
SESSION="${FIELDS[19]}"
CLK_TCK="$(getconf CLK_TCK)"

if [[ -z "$LOG" ]]; then
  LOG="${XDG_CACHE_HOME:-$HOME/.cache}/vshell/memory-samples.tsv"
fi
mkdir -p -- "$(dirname -- "$LOG")"
if [[ -s "$LOG" ]]; then
  # Appending a second session's rows to a foreign log is how a 100 MiB/h leak
  # reports as 0.0 MiB/h. Refuse rather than extend someone else's series.
  if ! last_id="$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
                              { id = $(c["pid"]) ":" $(c["session"]) } END { print id }' "$LOG")"; then
    refuse 2 "unreadable-log=$LOG" "The existing log could not be read to check whose session it holds."
  fi
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
  local cpu_ticks threads fds maps hwm uptime_s
  local -a f=()
  mapfile -t f < <(stat_fields "$PID")
  [[ ${#f[@]} -ge 20 ]] || return 1
  cpu_ticks=$((f[11] + f[12]))
  # Uptime from the same start time the identity column carries, so the two
  # cannot disagree. /proc/uptime is the system clock this is measured against.
  uptime_s="$(awk -v st="${f[19]}" -v hz="$CLK_TCK" '{printf "%d", $1 - st / hz; exit}' /proc/uptime)"
  threads="$(awk '/^Threads:/ {print $2}' "/proc/$PID/status")" || return 1
  hwm="$(awk '/^VmHWM:/ {print $2}' "/proc/$PID/status")" || return 1
  # An unreadable descriptor directory writes an empty field. Reporting 0 there
  # would be indistinguishable from a process holding no descriptors.
  if fds="$(find "/proc/$PID/fd" -mindepth 1 -maxdepth 1 2>/dev/null)"; then
    fds="$(printf '%s' "$fds" | grep -c . || true)"
  else
    fds=""
  fi
  maps="$(grep -c . "/proc/$PID/maps")" || return 1
  awk -v ts="$(date +%s)" -v pid="$PID" -v sess="$SESSION" -v up="$uptime_s" \
    -v cpu="$cpu_ticks" -v thr="$threads" -v hwm="$hwm" -v fds="$fds" -v maps="$maps" '
    /^[0-9a-f]+-[0-9a-f]+ / { name = $6; next }
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
      printf "%d\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\n",
        ts, pid, sess, up, rss, anon, file, swap, thp, hwm, js, jit, gpu, thr, fds, maps, cpu
    }
  ' "/proc/$PID/smaps"
}

deadline=0
if [[ "$HOURS" -gt 0 ]]; then
  deadline=$(($(date +%s) + HOURS * 3600))
fi

printf 'sample-shell-memory: sampling=%s:%s interval_s=%s log=%s\n' \
  "$PID" "$SESSION" "$INTERVAL" "$LOG" >&2

exited=0
while true; do
  # A row that fails because the shell exited mid-read ends the loop, not the
  # script: the closing report is the point of the run.
  if ! row="$(sample_row)"; then
    exited=1
    break
  fi
  printf '%s\n' "$row" >>"$LOG"
  if [[ "$deadline" -gt 0 && "$(date +%s)" -ge "$deadline" ]]; then
    break
  fi
  sleep "$INTERVAL"
  if [[ ! -d "/proc/$PID" ]]; then
    exited=1
    break
  fi
done

if [[ "$exited" == 1 ]]; then
  printf 'sample-shell-memory: pid-exited=%s\n' "$PID" >&2
fi
report_baseline "$LOG"
