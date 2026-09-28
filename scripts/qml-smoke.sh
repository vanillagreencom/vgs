#!/usr/bin/env bash
# Run the shell inside a nested Hyprland sandbox and check it end to end.
#
# Usage: scripts/qml-smoke.sh [--timeout SECONDS] [--keep]
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
# met a sandbox fault: the nested compositor failed to allocate its output
# buffers, or the host withheld frame callbacks so the shell never drew
# again; that is not a pass. Exit 1 when a check failed.
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
# to the first bar surface with a client in the compositor's layer list.
# VGSH_SMOKE_RECONCILE_BUDGET_MS: ceiling on the time from a
# setPluginEnabled reply to the build records no longer listing the
# disabled widget, polled with qs ipc. Both defaults are twice the highest
# reading of twelve runs of this script on the owner's machine (host cachy,
# AMD Ryzen 9 9950X) on 2026-09-23, which read 100 to 127 ms and 12 to
# 15 ms, each carrying its poll interval.
set -euo pipefail

timeout_s=60
keep=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) timeout_s="$2"; shift 2 ;;
    --keep) keep=true; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) printf 'qml-smoke: refused: argument=%s\n' "$1" >&2; exit 2 ;;
  esac
done

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
rss_ceiling_kib="${VGSH_SMOKE_RSS_CEILING_KIB:-574064}"
first_bar_budget_ms="${VGSH_SMOKE_FIRST_BAR_BUDGET_MS:-254}"
reconcile_budget_ms="${VGSH_SMOKE_RECONCILE_BUDGET_MS:-30}"


source "$repo/scripts/smoke/harness.sh"

# These rows share one sandbox and run in dependency order.
source "$repo/scripts/smoke/rows/bar.sh"
source "$repo/scripts/smoke/rows/plugins.sh"
source "$repo/scripts/smoke/rows/sources.sh"
source "$repo/scripts/smoke/rows/capabilities.sh"
source "$repo/scripts/smoke/rows/manager.sh"
source "$repo/scripts/smoke/rows/settings.sh"
source "$repo/scripts/smoke/rows/capability-release.sh"
source "$repo/scripts/smoke/rows/surfaces.sh"
source "$repo/scripts/smoke/rows/failed-builds.sh"
source "$repo/scripts/smoke/rows/monitors.sh"
source "$repo/scripts/smoke/rows/configuration.sh"
source "$repo/scripts/smoke/rows/theme.sh"
source "$repo/scripts/smoke/rows/themes.sh"
source "$repo/scripts/smoke/rows/toasts.sh"
source "$repo/scripts/smoke/rows/overlays.sh"
source "$repo/scripts/smoke/rows/gallery.sh"
source "$repo/scripts/smoke/rows/instance-guard.sh"
source "$repo/scripts/smoke/rows/diagnostics.sh"

smoke_finish
