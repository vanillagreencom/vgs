#!/usr/bin/env bash
# The vgs.devtools TUI entry `remove`: devtools.sh remove, whose header states
# the arguments and every refusal.
exec "$(dirname -- "$0")/devtools.sh" remove "$@"
