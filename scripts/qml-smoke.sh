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
# Checks, in order: the runner starts the shell and it answers IPC; the
# instance guard reports true; every bundled plugin loads with no manifest
# error; one bar surface maps per monitor, registers its built-in
# workspaces and clock and mounts a placed plugin widget; a widget
# can be disabled and re-enabled with its placement and settings kept;
# disabling the bar names the widgets it hides, unloads it and unmaps its
# surface; an unrelated write and a rescan that changes nothing build
# nothing, and a rescan that adds a disabled plugin builds nothing; a user
# plugin installed with `vgsh plugin add` from a local repository is
# discovered, built as a service and a widget, receives exactly the
# capabilities it named, and takes a settings change without a rebuild;
# an edit to a plugin's source, a sibling file included, rebuilds that
# plugin alone in its place, failed code is not retried until it changes,
# back-to-back rescans both complete and an unchanged plugin's files stay
# readable; the shared clock ticks seconds once a format shows them; every
# capability delivers its object to the plugin that named it, none to one
# that named none, and releases it on disable, read back from the fixture,
# the core's lending record, the compositor and a private D-Bus; a panel,
# an overlay and a menu open on summon, take their placement and close on
# hide, an anchored panel or menu opens as a popup under its item, follows
# it, and a menu closes on a click outside while a panel stays, and a
# background is drawn on the bottom layer of every screen; the bar's
# manager button opens a panel that lists, toggles and configures plugins,
# and the bar's settings hide it on every screen; an edit in progress in
# the manager's form survives an unrelated change, a write is published
# once, and dispatches queue in order, refuse past a bound and survive a
# process that cannot start; a built-in listed twice
# in one section is drawn once; a plugin refused an
# exclusive capability builds once the holder lets go; a plugin that cannot
# take what the core assigns keeps nothing; a removed monitor takes its bar
# and its build records with it; an unreadable user file keeps the bar and
# refuses writes; a theme file recolours the bar, one that does not parse,
# is not an object or holds a role that is not a colour is logged and keeps
# the last good palette, and a removed theme file restores the defaults;
# a bare `qs` started beside the runner refuses to draw and to write, and
# the runner's CLI still reaches the guarded instance; the log holds no QML
# error; resident memory stays under the ceiling.
#
# Exit 0 when every check passed. Exit 77 when a prerequisite is missing,
# naming it, or when a run whose only failures are geometry or render rows
# met a sandbox fault: the nested compositor failed to allocate its output
# buffers, or the host showed the nested window no frame so the shell never
# drew again; that is not a pass. Exit 1 when a check failed.
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
source "$repo/scripts/smoke/rows/instance-guard.sh"
source "$repo/scripts/smoke/rows/diagnostics.sh"

smoke_finish
