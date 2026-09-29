#!/usr/bin/env bash
# The vgs.automations `linger` floating TUI: says whether systemd keeps your
# user manager, and so your automations' timers, running while you are
# logged out, and offers to turn that on with `loginctl enable-linger`.
# systemd-logind's polkit policy lets a user in an active session set their
# own lingering without a password; where the local policy asks for one,
# loginctl asks for it in this terminal.
#
#   linger.sh
#
# Exits 0 when lingering is on, or the user declined; loginctl's status
# when it fails. Refusals, one keyed line on stderr: `automations: refused:
# tui=missing`, exit 2, outside the presenter; `automations: refused:
# argument=<arg>`, exit 2; `automations: refused: loginctl=missing`, exit 1;
# `automations: refused: linger=unreadable exit=<n>`, exit 1, when
# loginctl cannot answer.
set -Eeuo pipefail

refuse() { # STATUS FIRST_LINE [ENGLISH...]
  local status="$1"
  printf 'automations: refused: %s\n' "$2" >&2
  shift 2
  [[ $# -gt 0 ]] && printf '%s\n' "$@" >&2
  exit "$status"
}

[[ -n ${VGS_TUI_LIB:-} ]] || refuse 2 "tui=missing" "run this through the vgs.automations floating TUI, which sets VGS_TUI_LIB"
# shellcheck source=SCRIPTDIR/../../../../bin/lib/tui.sh
source "$VGS_TUI_LIB"
[[ $# -eq 0 ]] || refuse 2 "argument=$1" "usage: linger.sh"
command -v loginctl >/dev/null || refuse 1 "loginctl=missing" "Lingering is a systemd-logind setting; without loginctl, automations run only while you are logged in."

user="$(id -un)"
status=0
state="$(loginctl show-user "$user" --property=Linger --value)" || status=$?
[[ $status == 0 ]] || refuse 1 "linger=unreadable exit=$status" "loginctl could not read your user's lingering."

vgs_tui_header "Automations while logged out" \
  "systemd runs your automations' timers inside your user manager." \
  "Without lingering, that manager stops when you log out, and so do the timers."
if [[ $state == yes ]]; then
  vgs_tui_step "Lingering is on: your automations run while you are logged out."
  exit 0
fi
vgs_tui_step "Lingering is off: your automations run only while you are logged in."
if ! vgs_tui_confirm "Turn lingering on for $user?"; then
  vgs_tui_step "Lingering stays off."
  exit 0
fi
loginctl enable-linger "$user"
vgs_tui_step "Lingering is on: your automations run while you are logged out."
