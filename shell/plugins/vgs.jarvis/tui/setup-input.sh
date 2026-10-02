#!/usr/bin/env bash
# The user-started probe changes no unit, group, module or configuration.
set -euo pipefail
# shellcheck source=../../../../bin/lib/tui.sh
source "$VGS_TUI_LIB"
[[ $# == 0 ]] || { printf 'jarvis-input: arguments=none\n' >&2; exit 2; }
vgs_tui_header "Check Jarvis input" "Checks keyboard and pointer access without sending input." "Missing tools use the Jarvis requirements notice."
exec node "$VGS_PLUGIN_DIR/backend/input-check.js"
