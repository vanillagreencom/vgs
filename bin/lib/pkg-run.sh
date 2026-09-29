#!/usr/bin/env bash
# bin/lib/pkg-run.sh: runs the steps of one package plan in the terminal
# the user sees. bin/vgsh-pkg's `run` decides everything first (the caller,
# the terminal, the plan and the elevation command) and then starts this
# file with bash, so the steps run under bin/lib/tui.sh's sudo session.
#
#   pkg-run.sh ELEVATOR COUNT ARG... [COUNT ARG...]...
#
# ELEVATOR is `sudo`, `doas`, `run0` or `none`. Each step is COUNT, a
# positive number, then that many arguments, the step's argv. The steps
# reach this file as argv from node, never as a shell string, and run as
# lists: a package name holding `$(...)` stays one literal word.
#
# Each step runs in order with ELEVATOR before it, unless ELEVATOR is none,
# after a step line in the theme accent. The first step that fails ends the
# run with its exit status. Under sudo every run holds one sudo session
# (tui.sh's vgs_tui_sudo_session): the password is asked once, before the
# first step, and the credential is dropped when the run ends, whatever the
# number of steps. doas and run0 get no keepalive: each step asks as the
# system's own rules say, doas.conf's `persist` or polkit's
# `auth_admin_keep`, since neither has a command that refreshes a
# credential without running a program as root.
#
# The ending, Done or Failed, is `vgsh-tui present`'s: this file prints no
# verdict. A bad invocation prints `vgsh: refused: pkg-run=<key>` and exits
# 2; a sudo session that cannot start exits 1 after tui.sh's refusal line.
set -euo pipefail

# shellcheck source=tui.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/tui.sh"

bad() { printf 'vgsh: refused: pkg-run=%s\n' "$1" >&2; exit 2; }

elevator="${1:-}"
[[ $# -gt 0 ]] && shift
case "$elevator" in
  sudo|doas|run0) prefix=("$elevator") ;;
  none) prefix=() ;;
  *) bad "elevator value=${elevator:-missing}" ;;
esac

args=("$@")
starts=()
counts=()
i=0
while [[ $i -lt ${#args[@]} ]]; do
  count="${args[i]}"
  [[ $count =~ ^[123456789][0123456789]*$ ]] || bad "count value=$count"
  [[ $((i + 1 + count)) -le ${#args[@]} ]] || bad "step=short"
  starts+=("$((i + 1))")
  counts+=("$count")
  i=$((i + 1 + count))
done
[[ ${#starts[@]} -gt 0 ]] || bad "steps=missing"

if [[ $elevator == sudo ]]; then
  vgs_tui_sudo_session start || exit 1
fi
for k in "${!starts[@]}"; do
  step=("${prefix[@]}" "${args[@]:${starts[k]}:${counts[k]}}")
  vgs_tui_step "${step[*]}"
  status=0
  "${step[@]}" || status=$?
  # The sudo session's EXIT trap drops the credential on the way out.
  [[ $status -eq 0 ]] || exit "$status"
done
if [[ $elevator == sudo ]]; then
  vgs_tui_sudo_session end || exit 1
fi
exit 0
