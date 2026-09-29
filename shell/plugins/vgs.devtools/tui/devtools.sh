#!/usr/bin/env bash
# The vgs.devtools floating TUI: runs one engine verb on one row in the
# terminal the user watches, so vgsh pkg run's password prompt and mise's
# downloads show there. bin/vgsh-tui runs it from a private copy of the
# plugin's snapshot, so the engine and the catalog beside tui/ are under
# VGS_PLUGIN_DIR, and the VGS tree is the one VGS_TUI_LIB lies in.
#
#   devtools.sh install|update|remove <id> [flags...]
#   devtools.sh update|remove --mise <key>
#   devtools.sh launchers refresh|remove
#
# The arguments reach bin/devtools as they are; its header states each
# verb, its output and its refusals. The exit status is the engine's.
set -euo pipefail

lib="${VGS_TUI_LIB:-}"
tree="${lib%/bin/lib/tui.sh}"
if [[ -z $lib || $tree == "$lib" || -z ${VGS_PLUGIN_DIR:-} ]]; then
  printf 'devtools: refused: tui=missing\nrun this through the vgs.devtools floating TUI, which sets VGS_TUI_LIB and VGS_PLUGIN_DIR\n' >&2
  exit 2
fi
exec "$VGS_PLUGIN_DIR/bin/devtools" --tree "$tree" "$@"
