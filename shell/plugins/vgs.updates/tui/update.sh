#!/usr/bin/env bash
# The vgs.updates `update` floating TUI: update every source in one
# guarded, logged, ordered run. tui/pipeline.sh holds the steps and their
# order.
#
#   update.sh [-y]
#
# -y skips the start question; each package manager still asks its own.
set -Eeuo pipefail
# shellcheck source=SCRIPTDIR/pipeline.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/pipeline.sh"
updates_main all "$@"
