#!/usr/bin/env bash
# The core opens this script from the plugin's published snapshot.
set -euo pipefail
source "$VGS_TUI_LIB"
[[ $# == 0 ]] || { printf 'jarvis: browser-setup=arguments\n' >&2; exit 2; }
for tool in node agent-browser; do
  command -v "$tool" >/dev/null || { printf 'jarvis: browser-setup=missing command=%s\n' "$tool" >&2; exit 77; }
done
vgs_tui_lock jarvis-browser-setup
vgs_tui_header "Set up Jarvis browser" "Verifies a private browser on a blank page." "Jarvis does not use your signed-in browser."
program="$VGS_PLUGIN_DIR/backend/browser-setup.js"
result=0
node "$program" verify || result=$?
case "$result" in
  0) vgs_tui_step "Private browser ready" ;;
  69)
    vgs_tui_confirm "Download a private Chrome browser for Jarvis?" || exit 130
    node "$program" download
    node "$program" verify
    vgs_tui_step "Private browser ready" ;;
  *) exit "$result" ;;
esac
