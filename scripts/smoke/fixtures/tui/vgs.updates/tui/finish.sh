#!/usr/bin/env bash
# The updates row's gated TUI, which rows/updates.sh copies into its copy
# of vgs.updates as tui/finish.sh. Runs until the row opens its gate.
gate="${XDG_STATE_HOME:?}/vgs/updates-smoke/tui-gate"
while [[ ! -e $gate ]]; do sleep 0.05; done
