#!/usr/bin/env bash
# The vgs.devtools TUI entry `install`: devtools.sh install, whose header states
# the arguments and every refusal.
exec "$(dirname -- "$0")/devtools.sh" install "$@"
