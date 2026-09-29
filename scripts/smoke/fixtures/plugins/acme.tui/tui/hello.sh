#!/bin/sh
# The smoke fixture's floating TUI. No row runs it: the stand-in
# terminal records the command and opens nothing.
printf 'hello %s\n' "$@"
