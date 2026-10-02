#!/usr/bin/env bash
# The vgs.devtools floating TUI: runs one change in the terminal the user
# watches, so vgsh pkg run's password prompt and mise's downloads show
# there. bin/vgsh-tui runs it from a private copy of the plugin's snapshot,
# so the engine and the catalog beside tui/ are under VGS_PLUGIN_DIR, and
# the VGS tree is the one VGS_TUI_LIB lies in. The manifest's entries run it
# through install.sh, update.sh and remove.sh, one per verb, since a TUI
# entry names a script and no arguments.
#
#   devtools.sh install <id> [--channel <channel>] [--launchers]
#   devtools.sh update <id> [--launchers] | update --mise <key>
#   devtools.sh remove <id> | remove --mise <key>
#       the engine's verb on that row, as bin/devtools states it
#   devtools.sh install|update|remove
#       with no row, as an entry opens it: the rows the verb accepts now,
#       the engine's `targets`, in a gum filter, then the verb on the row
#       picked. No row to offer, or leaving the filter with Esc, exits 0
#       and runs nothing; Ctrl-C exits 130.
#
# The exit status is the engine's. `devtools: refused: picked=<line>
# reason=unlisted`, exit 1, when the filter answers a line it was not
# offered. Refusals, exit 2: `devtools: refused: tui=missing` outside the
# presenter, and `devtools: refused: verb=<verb>` for any other verb.
set -euo pipefail

lib="${VGS_TUI_LIB:-}"
tree="${lib%/bin/lib/tui.sh}"
if [[ -z $lib || $tree == "$lib" || -z ${VGS_PLUGIN_DIR:-} ]]; then
  printf 'devtools: refused: tui=missing\nrun this through the vgs.devtools floating TUI, which sets VGS_TUI_LIB and VGS_PLUGIN_DIR\n' >&2
  exit 2
fi
engine=("$VGS_PLUGIN_DIR/bin/devtools" --tree "$tree")

refuse() { # STATUS DIAGNOSTIC MESSAGE
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/vgs/devtools"
  mkdir -p -- "$dir"
  printf 'devtools: refused: %s\n' "$2" >>"$dir/actions.log"
  printf '%s\n' "$3" >&2
  exit "$1"
}

verb="${1:-}"
case "$verb" in
  install|update|remove) ;;
  *)
    refuse 2 "verb=${verb:-missing}" "This tool action is invalid. Open the action from Dev Tools."
    ;;
esac
if [[ $# -gt 1 ]]; then exec "${engine[@]}" "$@"; fi

# shellcheck source=/dev/null
source "$lib"
targets="$("${engine[@]}" targets "$verb")"
if [[ -z $targets ]]; then
  vgs_tui_step "No tools are available to $verb."
  exit 0
fi
labels=() words=()
while IFS= read -r line; do
  labels+=("${line%%$'\t'*}")
  words+=("${line#*$'\t'}")
done <<<"$targets"
status=0
picked="$(printf '%s\n' "${labels[@]}" | vgs_tui_filter --header "Pick a tool to $verb")" || status=$?
# gum filter answers 1 for Esc and 130 for Ctrl-C.
case "$status" in
  0) ;;
  1) exit 0 ;;
  *) exit "$status" ;;
esac
if [[ -z $picked ]]; then exit 0; fi
for ((i = 0; i < ${#labels[@]}; i++)); do
  [[ ${labels[i]} == "$picked" ]] || continue
  IFS=$'\t' read -r -a target <<<"${words[i]}"
  exec "${engine[@]}" "$verb" "${target[@]}"
done
refuse 1 "picked=$picked reason=unlisted" "This tool is unavailable. Open Dev Tools and choose another tool."
