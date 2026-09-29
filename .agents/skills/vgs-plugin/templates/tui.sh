#!/usr/bin/env bash
# A floating TUI script: copy it to the plugin's tui/ directory, make it
# executable, and declare it under the manifest's `tui` key. bin/vgsh-tui
# runs it from a private copy of the plugin's tui/ directory, with the
# arguments shell.tui.run passed as "$@", VGS_PLUGIN_ID, VGS_PLUGIN_DIR (the
# copy) and VGS_TUI_LIB, the presentation library, whose header lists its
# functions: docs/architecture/tui.md.
set -euo pipefail
# shellcheck source=/dev/null
source "$VGS_TUI_LIB"

vgs_tui_header "__NAME__"
vgs_tui_step "Running"
vgs_tui_confirm "Continue?" || exit 0
