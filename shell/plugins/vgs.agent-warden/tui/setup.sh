#!/usr/bin/env bash
# The vgs.agent-warden TUI `setup`: `vsys warden install`, which writes the
# warden's systemd user units as the user, asks for no privilege and enables
# and starts its timer
# (https://github.com/vanillagreencom/vsys/blob/main/docs/architecture/warden-install.md). Run again,
# it rewrites the units it wrote, which updates an older warden. vsys prints
# what it wrote or why it refused, and the script ends with its code.
set -euo pipefail
# shellcheck source=/dev/null
source "$VGS_TUI_LIB"

vgs_tui_header "Set up Agent Warden" "Limit your AI agents' memory and process use."
vgs_tui_step "Setting up Agent Warden"
vsys warden install
