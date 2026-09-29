#!/usr/bin/env bash
# The vgs.devtools TUI entry `requirement`: devtools.sh requirement, whose header states
# the arguments and every refusal.
exec "$(dirname -- "$0")/devtools.sh" requirement "$@"
