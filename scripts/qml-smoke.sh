#!/usr/bin/env bash
# Run the shell inside a nested Hyprland sandbox and check it end to end.
#
# Usage: scripts/qml-smoke.sh [--timeout SECONDS] [--keep]
#        scripts/qml-smoke.sh --first-bar-runs N [--timeout SECONDS]
#
# The sandbox is built from the repository alone: its own HOME, XDG dirs and
# runtime dir, a minimal compositor config, no user state. It never touches
# the live session: the nested compositor gets its own runtime dir, the
# shell is addressed through that runtime dir, and teardown kills only the
# process groups this run created.
#
# Exit 0 when every check passed. Exit 77 when a prerequisite is missing,
# naming it; when the nested compositor still lists a monitor with no size
# after 10 s, nested-monitor=unsized, since it configures no bar there;
# or when a run whose only failures are geometry or render rows
# met a sandbox fault: the nested window's output rejected a state because
# its buffers could not be allocated, which the nested compositor logs as
# `Output WAYLAND-<n>: pending state rejected: swapchain failed
# reconfiguring` (a bare GBM allocation failure, which passing runs log for
# the headless output, is not that fault), or the host withheld frame
# callbacks so the shell never drew again; that is not a pass. A run whose
# every failure came after the nested output left a mode a row held,
# nested-output=mode-reset, is not a pass either.
# scripts/smoke/verdict.sh holds the verdict. Exit 1 when a check failed.
#
# --first-bar-runs N, N a positive integer, measures the first bar alone:
# it starts the sandbox N times, runs no row, and prints one line per run,
# `run=<i> latency_first_bar_ms=<ms> cpu_some_pct=<pct>`, or
# `run=<i> status=not-measured exit=<status> log=<path>` for a run whose
# harness exited non-zero or read no bar. The last line is
# `qml-smoke: first-bar runs=<N> measured=<M> highest_ms=<H> budget_ms=<2H>`.
# Exit 0 when every run measured; otherwise a line naming how many did not
# and where their logs are, then exit 77. One run takes about 2 s.
#
# VGSH_SMOKE_RSS_CEILING_KIB: resident-size ceiling for the shell process at
# the end of the run. It catches a startup allocation blow-up and nothing
# else: a run this short cannot see the slow growth docs/architecture/memory.md
# describes, and the reading carries the machine's graphics stack. The
# default is twice the rss_kib this script printed on the owner's machine
# (host cachy, AMD Ryzen 9 9950X) on 2026-09-25 with the one bundled plugin,
# the bar, plus the fixtures this run installs, on one nested monitor. The
# high-water mark is printed beside it as the reproducible reading.
#
# VGSH_SMOKE_FIRST_BAR_BUDGET_MS: ceiling on the time from the runner's exec
# to the first bar surface with a client in the compositor's layer list,
# polled every 10 ms. The default is twice the highest reading of two passes
# of --first-bar-runs 12 on the owner's machine (host cachy, AMD Ryzen 9
# 9950X) on 2026-09-29, at load average 10 to 14; each pass lost one start
# to an unsized nested monitor. The 22 readings, each a start with no
# compiled QML cache, were 253 to 310 ms with cpu_some_pct at most 1.3.
# VGSH_SMOKE_RECONCILE_BUDGET_MS: ceiling on the time from a
# setPluginEnabled reply to the build records no longer listing the
# disabled widget, polled with qs ipc. The default is twice the highest
# reading of twelve runs of this script on the same machine on 2026-09-23,
# which read 12 to 15 ms.
set -euo pipefail

timeout_s=60
keep=false
first_bar_runs=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) timeout_s="$2"; shift 2 ;;
    --keep) keep=true; shift ;;
    --first-bar-runs)
      if [[ $# -lt 2 || ! $2 =~ ^[1-9][0-9]*$ ]]; then printf 'qml-smoke: refused: argument=--first-bar-runs value=%s\n' "${2-}" >&2; exit 2; fi
      first_bar_runs="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) printf 'qml-smoke: refused: argument=%s\n' "$1" >&2; exit 2 ;;
  esac
done

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
rss_ceiling_kib="${VGSH_SMOKE_RSS_CEILING_KIB:-574064}"
first_bar_budget_ms="${VGSH_SMOKE_FIRST_BAR_BUDGET_MS:-620}"
reconcile_budget_ms="${VGSH_SMOKE_RECONCILE_BUDGET_MS:-30}"

# The measurement mode. Each run sources the harness in its own subshell,
# so its teardown runs when the subshell exits, and the harness's output
# goes to that run's log. The subshell is no operand of || or &&, where
# bash would ignore the harness's set -e.
if [[ -n $first_bar_runs ]]; then
  if ! first_bar_logs="$(mktemp -d "${TMPDIR:-/tmp}/qml-smoke-first-bar.XXXXXX")"; then
    printf 'qml-smoke: refused: scratch=%s\n' "${TMPDIR:-/tmp}" >&2
    exit 1
  fi
  measured=0
  highest=0
  for ((run = 1; run <= first_bar_runs; run++)); do
    log="$first_bar_logs/run-$run.log"
    result="$first_bar_logs/run-$run.result"
    set +e
    (
      source "$repo/scripts/smoke/harness.sh"
      printf '%s %s\n' "${first_bar_ms:-unmeasured}" "$first_bar_cpu_some_pct" >"$result"
    ) >"$log" 2>&1 </dev/null
    status=$?
    set -e
    ms=""
    pct=""
    if [[ $status -eq 0 && -f $result ]]; then read -r ms pct <"$result"; fi
    if [[ $status -eq 0 && $ms =~ ^[0-9]+$ ]]; then
      measured=$((measured + 1))
      if ((ms > highest)); then highest=$ms; fi
      printf 'run=%d latency_first_bar_ms=%d cpu_some_pct=%s\n' "$run" "$ms" "$pct"
    else
      printf 'run=%d status=not-measured exit=%d log=%s\n' "$run" "$status" "$log"
    fi
  done
  if ((measured > 0)); then
    printf 'qml-smoke: first-bar runs=%d measured=%d highest_ms=%d budget_ms=%d\n' "$first_bar_runs" "$measured" "$highest" $((highest * 2))
  else
    printf 'qml-smoke: first-bar runs=%d measured=0 highest_ms=unmeasured budget_ms=unmeasured\n' "$first_bar_runs"
  fi
  if ((measured < first_bar_runs)); then
    printf 'qml-smoke: status=not-measured first-bar-unmeasured=%d logs=%s\n' $((first_bar_runs - measured)) "$first_bar_logs"
    exit 77
  fi
  rm -rf -- "$first_bar_logs"
  exit 0
fi


source "$repo/scripts/smoke/harness.sh"

# These rows share one sandbox and run in dependency order.
source "$repo/scripts/smoke/rows/bar.sh"
# bar.sh read the startup latencies; the cursor rows need the log.
if compositor_logs_on; then ok "the nested compositor logs from here on"; else fail "the nested compositor's logs did not turn on"; fi
source "$repo/scripts/smoke/rows/plugins.sh"
source "$repo/scripts/smoke/rows/sources.sh"
source "$repo/scripts/smoke/rows/capabilities.sh"
source "$repo/scripts/smoke/rows/status.sh"
source "$repo/scripts/smoke/rows/manager.sh"
source "$repo/scripts/smoke/rows/updates.sh"
source "$repo/scripts/smoke/rows/settings.sh"
source "$repo/scripts/smoke/rows/windows.sh"
source "$repo/scripts/smoke/rows/agent-warden.sh"
source "$repo/scripts/smoke/rows/capability-release.sh"
source "$repo/scripts/smoke/rows/surfaces.sh"
source "$repo/scripts/smoke/rows/failed-builds.sh"
source "$repo/scripts/smoke/rows/monitors.sh"
source "$repo/scripts/smoke/rows/configuration.sh"
source "$repo/scripts/smoke/rows/theme.sh"
source "$repo/scripts/smoke/rows/themes.sh"
source "$repo/scripts/smoke/rows/theme-browse.sh"
source "$repo/scripts/smoke/rows/theme-browser.sh"
source "$repo/scripts/smoke/rows/toasts.sh"
source "$repo/scripts/smoke/rows/layers.sh"
source "$repo/scripts/smoke/rows/tui.sh"
source "$repo/scripts/smoke/rows/notices.sh"
source "$repo/scripts/smoke/rows/devtools.sh"
source "$repo/scripts/smoke/rows/overlays.sh"
source "$repo/scripts/smoke/rows/gallery.sh"
source "$repo/scripts/smoke/rows/launcher.sh"
source "$repo/scripts/smoke/rows/notifications.sh"
source "$repo/scripts/smoke/rows/hyprland.sh"
source "$repo/scripts/smoke/rows/instance-guard.sh"
source "$repo/scripts/smoke/rows/diagnostics.sh"
source "$repo/scripts/smoke/rows/read-only-prefix.sh"
source "$repo/scripts/smoke/rows/notices-control.sh"

smoke_finish
