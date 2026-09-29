#!/usr/bin/env bash
# A floating TUI script: copy it to the plugin's tui/ directory, make it
# executable, and declare it under the manifest's `tui` key. bin/vgsh-tui
# runs it from a private copy of the plugin's snapshot, with the arguments
# shell.tui.run passed as "$@", VGS_PLUGIN_ID, VGS_PLUGIN_DIR (the copy, so
# the plugin's other files are under it) and VGS_TUI_LIB, the presentation
# library, whose header lists its functions: docs/architecture/tui.md.
set -euo pipefail
# shellcheck source=/dev/null
source "$VGS_TUI_LIB"

vgs_tui_header "__NAME__"
# gum confirm answers 1 for No, which ends the script as a success. 130 is a
# Ctrl-C, which present closes on without a prompt, and any other status is
# a refusal: both leave with their own code.
status=0
vgs_tui_confirm "Continue?" || status=$?
case "$status" in
  0) ;;
  1) exit 0 ;;
  *) exit "$status" ;;
esac
vgs_tui_step "Running"
