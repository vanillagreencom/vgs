#!/usr/bin/env bash
# The core owns terminal presentation. This script carries metadata only.
set -euo pipefail
# shellcheck source=/dev/null
source "$VGS_TUI_LIB"
[[ $# == 0 ]] || { printf 'jarvis-accounts: arguments=none\n' >&2; exit 2; }
[[ -t 0 ]] || { printf 'jarvis-accounts: input=terminal-required\n' >&2; exit 2; }
program="$VGS_PLUGIN_DIR/backend/accounts.js"
child_env=(env -i PATH="$PATH" HOME="$HOME" LANG=C.UTF-8
  XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}" XDG_STATE_HOME="${XDG_STATE_HOME:-}"
  XDG_DATA_HOME="${XDG_DATA_HOME:-}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
  DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}"
  CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}" CODEX_HOME="${CODEX_HOME:-}"
  VGS_TUI_ACCENT="${VGS_TUI_ACCENT:-}" VGS_TUI_SUCCESS="${VGS_TUI_SUCCESS:-}"
  VGS_TUI_WARNING="${VGS_TUI_WARNING:-}" VGS_TUI_DANGER="${VGS_TUI_DANGER:-}")
# The core presentation functions call this scoped executable wrapper too.
gum() { "${child_env[@]}" gum "$@"; }
vgs_tui_header "Jarvis accounts" "Login status is a hint, not verified inference access." "Verify may cost money. Keys stay in your desktop keyring."
accounts() { "${child_env[@]}" node "$program" "$@"; }
# Convert judged JSON to menu lines. Selection carries a stable id, never
# a directory label, back into the judge. No secret value enters the shell.
menu() {
  "${child_env[@]}" node -e '
let text=""; process.stdin.on("data", x => text += x);
process.stdin.on("end", () => {
    const rows=JSON.parse(text);
    for (const row of rows) {
        if (typeof row === "string") console.log(row);
        else if (row.path) console.log(row.path + " | " + row.label + " | " + row.presence);
        else console.log(row.id + " | " + row.provider + " / " + row.label + " | " + row.state.kind
            + (row.email ? " | " + row.email : "")
            + (row.plan ? " | " + row.plan : "")
            + (row.marker === "present" ? " | Marker present" : "")
            + (row.identity.kind === "mismatch" ? " | Identity mismatch" : ""));
    }
});'
}
while true; do
  action="$(vgs_tui_choose -- "Show accounts" "Add directory" "Use keyring item" "Verify" "Close")" || exit 130
  case "$action" in
    "Show accounts")
      listing="$(accounts list)" || exit $?
      menu <<<"$listing"
      ;;
    "Add directory")
      choices="$(accounts providers cli)" || exit $?
      choices="$(menu <<<"$choices")" || exit $?
      selected="$(vgs_tui_choose <<<"$choices")" || exit 130
      dir="$(vgs_tui_input --header "Account directory" --placeholder "Absolute path")" || exit 130
      label="$(vgs_tui_input --header "Account label")" || exit 130
      accounts add "$selected" "$dir" "$label"
      ;;
    "Use keyring item")
      choices="$(accounts items)" || exit $?
      choices="$(menu <<<"$choices")" || exit $?
      [[ -n $choices ]] || { vgs_tui_warn "No eligible API-key item is available."; continue; }
      item="$(vgs_tui_choose <<<"$choices")" || exit 130
      items="$(accounts providers key)" || exit $?
      items="$(menu <<<"$items")" || exit $?
      selected="$(vgs_tui_choose <<<"$items")" || exit 130
      label="$(vgs_tui_input --header "Account label")" || exit 130
      accounts remember "${item%% | *}" "$selected" "$label"
      ;;
    "Verify")
      choices="$(accounts list)" || exit $?
      choices="$(menu <<<"$choices")" || exit $?
      [[ -n $choices ]] || { vgs_tui_warn "No account is available."; continue; }
      selected="$(vgs_tui_choose <<<"$choices")" || exit 130
      model="$(vgs_tui_input --header "Model (blank uses the provider default; Ollama and LM Studio need a model)")" || exit 130
      if vgs_tui_confirm "Send a small inference request? This may cost money."; then
        code=0
        accounts verify "${selected%% | *}" user "$model" || code=$?
        if [[ $code == 69 ]]; then
          vgs_tui_warn "Verification did not succeed. The result above names the cause."
        elif [[ $code != 0 ]]; then
          exit "$code"
        fi
      else
        code=$?
        [[ $code == 1 ]] || exit "$code"
      fi
      ;;
    "Close") exit 0 ;;
    *) printf 'jarvis-accounts: selection=unknown\n' >&2; exit 2 ;;
  esac
done
