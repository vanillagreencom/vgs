#!/usr/bin/env bash
# The vgs.updates `update-source` floating TUI: update one source with the
# pipeline's lock, log, question and sudo discipline. tui/pipeline.sh holds
# the steps and their order.
#
#   update-source.sh <source> [-y]
#
# <source> is a status row's `source`: the primary package manager's id,
# aur, flatpak, mise, vgs, plugins or themes. -y skips the start question.
set -Eeuo pipefail
# shellcheck source=SCRIPTDIR/pipeline.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/pipeline.sh"
updates_main source "$@"
