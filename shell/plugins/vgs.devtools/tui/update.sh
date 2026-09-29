#!/usr/bin/env bash
# The vgs.devtools TUI entry `update`: devtools.sh update, whose header states
# the arguments and every refusal.
exec "$(dirname -- "$0")/devtools.sh" update "$@"
