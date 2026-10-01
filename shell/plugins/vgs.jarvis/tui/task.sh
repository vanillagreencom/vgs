#!/usr/bin/env bash
# The plugin's `task` TUI: one coding task in the floating terminal.
#   task.sh SPEC
# SPEC is the daemon's one-shot launch spec; the goal never travels as an
# argument. task-run.py owns the launch, its records and its exit code.
# The presentation is `plain`, since the agent owns the window, so a
# failure holds the window on the library's own close prompt.
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$VGS_TUI_LIB"
trap 'status=$?; [[ $status == 0 ]] || vgs_tui_close_prompt "$status"' EXIT
[[ $# == 1 ]] || { printf 'jarvis-task: arguments=spec\n' >&2; exit 2; }
python3 "$VGS_PLUGIN_DIR/backend/task-run.py" --spec "$1"
