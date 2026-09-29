#!/bin/sh
# The smoke row's gated floating TUI: waits for the file $1, polling every
# 0.05 s for at most 20 s, then exits with the code $2.
n=0
while [ ! -e "$1" ] && [ "$n" -lt 400 ]; do
  sleep 0.05
  n=$((n + 1))
done
exit "$2"
