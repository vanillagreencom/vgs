#!/usr/bin/env bash
# The vgs.updates `log` floating TUI: the last update run's log in less,
# opened at its end. tui/pipeline.sh names the file; the log is script(1)'s
# transcript of the run, so less draws its colours with -R.
#
#   log.sh
#
# Refuses, exiting 1, with `updates: refused: log=absent path=<file>` when
# no run has written a log yet and `updates: refused: pager=missing` when
# less is not on PATH; any argument exits 2.
set -Eeuo pipefail
# shellcheck source=SCRIPTDIR/pipeline.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/pipeline.sh"
[[ $# -eq 0 ]] || _updates_refuse 2 "argument=$1" "usage: log.sh"
log="$(updates_log_file)"
[[ -f $log ]] || _updates_refuse 1 "log=absent path=$log" "No update has run yet, so there is no log to show."
command -v less >/dev/null || _updates_refuse 1 "pager=missing" "Install less to read the log here. The log is $log."
exec less -R +G -- "$log"
