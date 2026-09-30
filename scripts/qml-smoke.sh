#!/usr/bin/env bash
# Run the shell inside a nested Hyprland sandbox and check it end to end.
#
# Usage: scripts/qml-smoke.sh [--timeout SECONDS] [--keep]
#        scripts/qml-smoke.sh --first-bar-runs N [--plugin-set smoke|default] [--timeout SECONDS]
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
# `run=<i> latency_first_bar_ms=<ms> cpu_some_pct=<pct>
# services_released=<reason> waited_ms=<ms>`, the last two from the
# service gate's release line (unreleased and - when it logged none), or
# `run=<i> status=not-measured exit=<status> log=<path>` for a run whose
# harness exited non-zero or read no bar. The last line is
# `qml-smoke: first-bar runs=<N> measured=<M> highest_ms=<H> budget_ms=<2H>
# highest_waited_ms=<W> deadline_ms=<2W>`, W over the runs released on a
# first frame. Exit 0 when every run measured; otherwise a line naming how
# many did not and where their logs are, then exit 77. One run takes about
# 2 s. --plugin-set picks the set each run starts with: `smoke`, the rows'
# own and the default, or `default`, every first-party plugin enabled as
# in a live session (scripts/smoke/harness.sh); it needs --first-bar-runs.
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
# VGSH_SMOKE_DEFAULT_FIRST_BAR_BUDGET_MS: the same ceiling for the start
# over the default set that rows/start-order.sh reads. The default is twice
# the highest reading of two passes of --first-bar-runs 12 --plugin-set
# default on the same machine on 2026-09-29, at load average 4 to 8; each
# pass lost one start to an unsized nested monitor. The 22 readings were
# 206 to 271 ms with cpu_some_pct at most 1.3.
# VGSH_SMOKE_RECONCILE_BUDGET_MS: ceiling on the time from a
# setPluginEnabled reply to the build records no longer listing the
# disabled widget, polled with qs ipc. The default is twice the highest
# reading of twelve runs of this script on the same machine on 2026-09-23,
# which read 12 to 15 ms.
# VGSH_SMOKE_EMOJI_TOAST_BUDGET_MS: ceiling on the time from the notify
# call for a Slack card with six custom emoji to its body naming the
# images on every screen, and VGSH_SMOKE_EMOJI_INBOX_BUDGET_MS on the time
# from the history call to forty such cards naming theirs
# (rows/notifications.sh), each counted by the probe and polled back to
# back, one reading per IPC round trip of about 22 ms. The defaults are
# twice the highest reading of 14 runs of that row in the nested sandbox on
# the same machine on 2026-09-30, at load average 4 to 8, one toast and one
# inbox reading a run: 43 to 50 ms and 79 to 95 ms.
set -euo pipefail

timeout_s=60
keep=false
first_bar_runs=""
plugin_set=smoke
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) timeout_s="$2"; shift 2 ;;
    --keep) keep=true; shift ;;
    --first-bar-runs)
      if [[ $# -lt 2 || ! $2 =~ ^[1-9][0-9]*$ ]]; then printf 'qml-smoke: refused: argument=--first-bar-runs value=%s\n' "${2-}" >&2; exit 2; fi
      first_bar_runs="$2"; shift 2 ;;
    --plugin-set)
      if [[ $# -lt 2 || ! $2 =~ ^(smoke|default)$ ]]; then printf 'qml-smoke: refused: argument=--plugin-set value=%s\n' "${2-}" >&2; exit 2; fi
      plugin_set="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) printf 'qml-smoke: refused: argument=%s\n' "$1" >&2; exit 2 ;;
  esac
done
# The rows read the smoke set's state, so another set only measures.
if [[ $plugin_set != smoke && -z $first_bar_runs ]]; then
  printf 'qml-smoke: refused: argument=--plugin-set value=%s reason=needs-first-bar-runs\n' "$plugin_set" >&2
  exit 2
fi

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
rss_ceiling_kib="${VGSH_SMOKE_RSS_CEILING_KIB:-574064}"
first_bar_budget_ms="${VGSH_SMOKE_FIRST_BAR_BUDGET_MS:-620}"
default_first_bar_budget_ms="${VGSH_SMOKE_DEFAULT_FIRST_BAR_BUDGET_MS:-542}"
reconcile_budget_ms="${VGSH_SMOKE_RECONCILE_BUDGET_MS:-30}"
emoji_toast_budget_ms="${VGSH_SMOKE_EMOJI_TOAST_BUDGET_MS:-100}"
emoji_inbox_budget_ms="${VGSH_SMOKE_EMOJI_INBOX_BUDGET_MS:-190}"

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
  highest_waited=""
  for ((run = 1; run <= first_bar_runs; run++)); do
    log="$first_bar_logs/run-$run.log"
    result="$first_bar_logs/run-$run.result"
    set +e
    (
      source "$repo/scripts/smoke/harness.sh"
      printf '%s %s %s\n' "${first_bar_ms:-unmeasured}" "$first_bar_cpu_some_pct" "$(service_release)" >"$result"
    ) >"$log" 2>&1 </dev/null
    status=$?
    set -e
    ms=""
    pct=""
    reason=""
    waited=""
    if [[ $status -eq 0 && -f $result ]]; then read -r ms pct reason waited <"$result"; fi
    if [[ $status -eq 0 && $ms =~ ^[0-9]+$ ]]; then
      measured=$((measured + 1))
      if ((ms > highest)); then highest=$ms; fi
      if [[ $reason == first-frame ]] && { [[ -z $highest_waited ]] || ((waited > highest_waited)); }; then highest_waited=$waited; fi
      printf 'run=%d latency_first_bar_ms=%d cpu_some_pct=%s services_released=%s waited_ms=%s\n' "$run" "$ms" "$pct" "$reason" "$waited"
    else
      printf 'run=%d status=not-measured exit=%d log=%s\n' "$run" "$status" "$log"
    fi
  done
  if ((measured > 0)); then
    printf 'qml-smoke: first-bar runs=%d measured=%d highest_ms=%d budget_ms=%d highest_waited_ms=%s deadline_ms=%s\n' "$first_bar_runs" "$measured" "$highest" $((highest * 2)) \
      "${highest_waited:-unmeasured}" "$([[ -n $highest_waited ]] && echo $((highest_waited * 2)) || echo unmeasured)"
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


# Every sandbox shell finds vsys and the browser-policy writer absent,
# whatever the host holds, so the rows press Install vsys and Install
# browser theming on any host (harness.sh's shell_hidden_commands); a row
# that needs one present stands its own stand-in for it.
# shellcheck disable=SC2034 # the harness sourced below reads it
shell_hidden_commands=(vsys vgs-browser-policy)
source "$repo/scripts/smoke/harness.sh"

# These rows share one sandbox and run in dependency order. smoke_row
# (harness.sh) sources each and fails one whose output holds a traceback.
smoke_row bar
smoke_row hyprland-consent
# bar.sh read the startup latencies; the cursor rows need the log.
if compositor_logs_on; then ok "the nested compositor logs from here on"; else fail "the nested compositor's logs did not turn on"; fi
smoke_row plugins
smoke_row sources
smoke_row capabilities
smoke_row session
smoke_row status
smoke_row manager
smoke_row updates
smoke_row settings
smoke_row windows
smoke_row compositor-dispatchers
smoke_row compositor-reveal
smoke_row agent-warden
smoke_row capability-release
smoke_row surfaces
smoke_row failed-builds
smoke_row monitors
smoke_row configuration
smoke_row theme
smoke_row themes
smoke_row theme-browse
smoke_row theme-browser
smoke_row toasts
smoke_row layers
smoke_row shader-frames
smoke_row tui
smoke_row notices
smoke_row devtools
smoke_row overlays
smoke_row gallery
smoke_row launcher
smoke_row list-motion
smoke_row notifications
smoke_row automations
smoke_row polkit
smoke_row jarvis
smoke_row hyprland
smoke_row hold-shortcuts
smoke_row jarvis-keys
smoke_row instance-guard
smoke_row diagnostics
smoke_row supervise
smoke_row lock
smoke_row read-only-prefix
smoke_row hyprland-consent-decline
smoke_row notices-control
smoke_row hidpi
smoke_row start-order
smoke_row overlay-capture
# After every row that opens a TUI: the stand-in terminal ran no plugin
# script but a fixture's.
smoke_row tui-guard
# Last: every row above has run, so its reading covers the whole run.
smoke_row auth-sentinel

smoke_finish
