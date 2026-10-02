#!/usr/bin/env bash
# The vgs.themes TUI `browser-policy`, which the Settings page's Install
# browser theming button opens: `vgsh theme browser-policy install`, which
# installs the Chromium-family colour writer and its sudoers rule once,
# sudo asking for the password in this terminal
# (docs/architecture/theme-browsers.md § Chromium). The VGS tree is the one
# VGS_TUI_LIB lies in. Ends with the install's exit code. Refusals, one keyed
# line on stderr: `themes: refused: tui=missing`, exit 2, outside the
# presenter; `themes: refused: argument=<arg>`, exit 2.
set -euo pipefail

lib="${VGS_TUI_LIB:-}"
if [[ -z $lib ]]; then
  printf 'themes: refused: tui=missing\nrun this through the vgs.themes floating TUI, which sets VGS_TUI_LIB\n' >&2
  exit 2
fi
if [[ $# -gt 0 ]]; then
  dir="${XDG_STATE_HOME:-$HOME/.local/state}/vgs/themes"
  mkdir -p -- "$dir"
  printf 'themes: refused: argument=%s\n' "$1" >>"$dir/setup.log"
  printf 'This setup request is invalid. Open Themes and try again.\n' >&2
  exit 2
fi
# shellcheck source=SCRIPTDIR/../../../../bin/lib/tui.sh
source "$lib"
tree="${lib%/bin/lib/tui.sh}"

vgs_tui_header "Browser theming" \
  "Apply theme colours to Chromium, Chrome, Edge and Brave." \
  "Setup asks for your password."
vgs_tui_step "Setting up browser theming"
"$tree/bin/vgsh" theme browser-policy install
