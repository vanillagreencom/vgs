#!/usr/bin/env bash
# Sample the live shell's memory read-only and report growth per class.
#
# Every read is /proc plus ps. Nothing here signals, restarts or drives the
# shell, so it is safe to leave running across a whole session. It is a
# diagnostic tool, not a validation check: scripts/validate never runs it.
#
#   scripts/sample-shell-memory.sh                 sample until interrupted
#   scripts/sample-shell-memory.sh --hours 26      sample for 26 hours
#   scripts/sample-shell-memory.sh --report FILE   summarise an existing log
#
# The log is one TSV row per sample. --report prints the session baseline the
# diagnosis in docs/architecture/memory.md asks for: resident size at 1 h, 8 h
# and 24 h of uptime, plus the growth rate between consecutive marks.
set -euo pipefail

INTERVAL=60
HOURS=0
LOG=""
REPORT=""

die() {
  printf 'sample-shell-memory: %s\n' "$*" >&2
  exit 2
}

usage() {
  cat <<'USAGE'
Usage: sample-shell-memory.sh [--interval SECONDS] [--hours N] [--log FILE]
       sample-shell-memory.sh --report FILE

  --interval  seconds between samples (default 60)
  --hours     stop after N hours (default: run until interrupted)
  --log       where to append samples (default ~/.cache/vshell/memory-samples.tsv)
  --report    print the 1 h / 8 h / 24 h baseline from an existing log and exit
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      [[ $# -ge 2 ]] || die "--interval needs a value"
      INTERVAL="$2"
      shift 2
      ;;
    --hours)
      [[ $# -ge 2 ]] || die "--hours needs a value"
      HOURS="$2"
      shift 2
      ;;
    --log)
      [[ $# -ge 2 ]] || die "--log needs a value"
      LOG="$2"
      shift 2
      ;;
    --report)
      [[ $# -ge 2 ]] || die "--report needs a value"
      REPORT="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -gt 0 ]] || die "--interval must be a positive integer"
[[ "$HOURS" =~ ^[0-9]+$ ]] || die "--hours must be a non-negative integer"

COLUMNS_HEADER=$'epoch\tuptime_s\trss_kb\tanon_kb\tfile_kb\tswap_kb\tthp_kb'
COLUMNS_HEADER+=$'\tjsheap_kb\tjit_kb\tgpu_kb\tthreads\tfds\tmaps\tcpu_ticks'

# Report from a finished log. Reads nothing from the live process, so it works
# after the sampled session has ended.
report_baseline() {
  local log="$1"
  [[ -r "$log" ]] || die "cannot read $log"
  awk -F'\t' '
    BEGIN { n = 0 }
    NR == 1 { next }
    { up[n] = $2; rss[n] = $3; anon[n] = $4; thp[n] = $7; n++ }
    function mib(kb) { return sprintf("%.0f", kb / 1024) }
    function at(target,   i, best) {
      best = -1
      for (i = 0; i < n; i++)
        if (up[i] <= target && (best < 0 || up[i] > up[best])) best = i
      return best
    }
    function mark(label, target,   i) {
      i = at(target)
      if (i < 0) { printf "%-6s  not reached\n", label; return -1 }
      printf "%-6s  uptime %6.2f h   rss %6s MiB   anon %6s MiB   thp %6s MiB\n",
        label, up[i] / 3600, mib(rss[i]), mib(anon[i]), mib(thp[i])
      return i
    }
    END {
      if (n == 0) { print "no samples in log"; exit 1 }
      printf "samples: %d   covering %.2f h to %.2f h of uptime\n\n", n, up[0] / 3600, up[n - 1] / 3600
      h1 = mark("1 h", 3600)
      h8 = mark("8 h", 8 * 3600)
      h24 = mark("24 h", 24 * 3600)
      printf "%-6s  uptime %6.2f h   rss %6s MiB   anon %6s MiB   thp %6s MiB\n",
        "last", up[n - 1] / 3600, mib(rss[n - 1]), mib(anon[n - 1]), mib(thp[n - 1])
      print ""
      peak = 0
      for (i = 0; i < n; i++) if (rss[i] > peak) { peak = rss[i]; peaki = i }
      printf "peak resident %s MiB at %.2f h; resident size is %s MiB at the last sample\n",
        mib(peak), up[peaki] / 3600, mib(rss[n - 1])
      # A rate over a short window is sampling noise, not a trend: one purge or
      # one popup moves it by more than the signal. State the refusal instead.
      d = up[n - 1] - up[0]
      if (d < 600)
        printf "logged window is %.0f s; too short to state a growth rate (needs 600 s)\n", d
      else
        printf "mean growth over the logged window: %.1f MiB/h anonymous, %.1f MiB/h resident\n",
          (anon[n - 1] - anon[0]) / 1024 / (d / 3600), (rss[n - 1] - rss[0]) / 1024 / (d / 3600)
      if (h1 >= 0 && h8 >= 0 && up[h8] > up[h1])
        printf "1 h to 8 h: %.1f MiB/h resident\n", (rss[h8] - rss[h1]) / 1024 / ((up[h8] - up[h1]) / 3600)
      if (h8 >= 0 && h24 >= 0 && up[h24] > up[h8])
        printf "8 h to 24 h: %.1f MiB/h resident\n", (rss[h24] - rss[h8]) / 1024 / ((up[h24] - up[h8]) / 3600)
    }
  ' "$log"
}

if [[ -n "$REPORT" ]]; then
  report_baseline "$REPORT"
  exit 0
fi

# Resolve the live shell from the service's own main PID, so a second shell or a
# stale PID file cannot be sampled by mistake. An ambiguous answer is a refusal:
# a wrong PID produces a plausible log that describes nothing.
resolve_pid() {
  local pid="" children=() candidates=() candidate
  if pid="$(systemctl --user show -p MainPID --value vshell.service 2>/dev/null)"; then
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 && -d "/proc/$pid" ]]; then
      # The unit's main process is the launcher; the QML runtime is its child.
      if mapfile -t children < <(pgrep -P "$pid" -x qs 2>/dev/null); then
        [[ ${#children[@]} -le 1 ]] || die "vshell.service has ${#children[@]} qs children; refusing to guess which to sample"
        if [[ ${#children[@]} -eq 1 ]]; then
          printf '%s\n' "${children[0]}"
          return 0
        fi
      fi
    fi
  fi
  # No usable unit answer. Fall back to every qs whose command line names the
  # shell, and refuse any count but one: a wrong PID yields a plausible log
  # that describes nothing.
  local all=()
  mapfile -t all < <(pgrep -x qs 2>/dev/null) || true
  for candidate in "${all[@]}"; do
    [[ -n "$candidate" ]] || continue
    grep -qs 'quickshell/vshell' "/proc/$candidate/cmdline" && candidates+=("$candidate")
  done
  [[ ${#candidates[@]} -eq 1 ]] || die "found ${#candidates[@]} running vshell processes; refusing to guess which to sample"
  printf '%s\n' "${candidates[0]}"
}

PID="$(resolve_pid)"

if [[ -z "$LOG" ]]; then
  LOG="${XDG_CACHE_HOME:-$HOME/.cache}/vshell/memory-samples.tsv"
fi
mkdir -p -- "$(dirname -- "$LOG")"
[[ -s "$LOG" ]] || printf '%s\n' "$COLUMNS_HEADER" >"$LOG"

# One row of /proc reads. Classifying smaps by mapping name separates the QML
# JavaScript heap (a memfd) and the GPU driver's mappings from plain anonymous
# memory, which is what the native heap grows into.
sample_row() {
  local uptime_s cpu_ticks threads fds maps stat rest
  uptime_s="$(ps -o etimes= -p "$PID" | tr -d ' ')"
  # The comm field of /proc/<pid>/stat can hold spaces and parens, so counting
  # fields from the left misreads the times. Count from after the last ')'.
  stat="$(cat "/proc/$PID/stat")"
  rest="${stat##*") "}"
  # rest: 1=state 2=ppid 3=pgrp 4=session 5=tty 6=tpgid 7=flags 8=minflt
  #       9=cminflt 10=majflt 11=cmajflt 12=utime 13=stime
  # shellcheck disable=SC2086  # deliberate word splitting of a numeric field list
  set -- $rest
  cpu_ticks=$((${12} + ${13}))
  threads="$(awk '/^Threads:/ {print $2}' "/proc/$PID/status")"
  fds="$(find "/proc/$PID/fd" -mindepth 1 -maxdepth 1 2>/dev/null | grep -c . || true)"
  maps="$(grep -c . "/proc/$PID/maps")"
  awk -v ts="$(date +%s)" -v up="$uptime_s" -v cpu="$cpu_ticks" \
    -v thr="$threads" -v fds="$fds" -v maps="$maps" '
    /^[0-9a-f]+-[0-9a-f]+ / { name = $6; next }
    /^Rss:/ {
      rss += $2
      if (name == "") anon += $2
      else if (name ~ /JSGCHeap/) js += $2
      else if (name ~ /JITCode/) jit += $2
      else if (name ~ /nvidia|renderD|\/dri\//) gpu += $2
      else file += $2
      next
    }
    /^Swap:/ { swap += $2; next }
    /^AnonHugePages:/ { thp += $2; next }
    END {
      printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
        ts, up, rss, anon, file, swap, thp, js, jit, gpu, thr, fds, maps, cpu
    }
  ' "/proc/$PID/smaps"
}

deadline=0
[[ "$HOURS" -gt 0 ]] && deadline=$(($(date +%s) + HOURS * 3600))

printf 'sample-shell-memory: sampling pid %s every %ss into %s\n' "$PID" "$INTERVAL" "$LOG" >&2
printf 'sample-shell-memory: summarise later with --report %s\n' "$LOG" >&2

while [[ -d "/proc/$PID" ]]; do
  sample_row >>"$LOG"
  [[ "$deadline" -gt 0 && "$(date +%s)" -ge "$deadline" ]] && break
  sleep "$INTERVAL"
done

if [[ ! -d "/proc/$PID" ]]; then
  printf 'sample-shell-memory: pid %s exited; log ends at that point\n' "$PID" >&2
fi
report_baseline "$LOG"
