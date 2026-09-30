#!/usr/bin/env bash
# Only metadata reaches the shell. secret-tool's terminal prompt masks the
# key and stores it directly. No transcript or shell variable holds it.
set -euo pipefail
# shellcheck source=/dev/null
source "$VGS_TUI_LIB"
[[ $# == 0 ]] || { printf 'jarvis-keys: arguments=none\n' >&2; exit 2; }
vgs_tui_header "Add Jarvis key" "The key stays in your desktop keyring." "Use the provider's origin, with no path."
[[ -t 0 ]] || { printf 'jarvis-keys: store=terminal-required\n' >&2; exit 2; }
read -r -p "Provider: " provider || { printf 'jarvis-keys: input=cancelled\n' >&2; exit 130; }
read -r -p "Account label: " account || { printf 'jarvis-keys: input=cancelled\n' >&2; exit 130; }
read -r -p "Origin (for example https://api.openai.com): " origin || { printf 'jarvis-keys: input=cancelled\n' >&2; exit 130; }
exec node "$VGS_PLUGIN_DIR/backend/keys.js" add-key "$provider" "$account" "$origin"
