#!/usr/bin/env bash
set -euo pipefail

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
systemctl --user disable --now vshell.service 2>/dev/null || true
cli_link="$HOME/.local/bin/vshell"
shell_link="$config_home/quickshell/vshell"
if [[ -L "$cli_link" && "$(readlink -f "$cli_link")" == "$data_home/vshell/"* ]]; then
  rm -f "$cli_link"
fi
if [[ -L "$shell_link" && "$(readlink -f "$shell_link")" == "$data_home/vshell/"* ]]; then
  rm -f "$shell_link"
fi
rm -f "$config_home/systemd/user/vshell.service"
rm -rf "$data_home/vshell"
systemctl --user daemon-reload
echo "VGS removed. User settings remain in $config_home/vshell"