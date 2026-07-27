#!/usr/bin/env bash
set -euo pipefail

repo="vanillagreencom/vgs"
version="latest"
start=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:?missing version}"; shift 2 ;;
    --no-start) start=false; shift ;;
    -h|--help)
      echo "Usage: install.sh [--version v0.1.0] [--no-start]"
      exit 0
      ;;
    *) echo "install.sh: unknown option: $1" >&2; exit 2 ;;
  esac
done

for cmd in curl tar sha256sum; do
  command -v "$cmd" >/dev/null || { echo "install.sh: missing $cmd" >&2; exit 1; }
done

case "$(uname -m)" in
  x86_64|amd64) arch="x86_64" ;;
  aarch64|arm64) arch="aarch64" ;;
  *) echo "install.sh: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [[ "$version" == latest ]]; then
  version="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
fi
[[ -n "$version" ]] || { echo "install.sh: could not resolve release" >&2; exit 1; }

release="${version#v}"
archive="vgs-${release}-linux-${arch}.tar.gz"
base="${VGS_RELEASE_BASE_URL:-https://github.com/$repo/releases/download/$version}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fL "$base/$archive" -o "$tmp/$archive"
curl -fL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"
(cd "$tmp" && grep "  $archive$" SHA256SUMS | sha256sum -c -)

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
install_root="$data_home/vshell"
version_root="$install_root/$version"
if [[ -L "$install_root" ]]; then
  echo "install.sh: refusing symlinked install root: $install_root" >&2
  exit 1
fi
mkdir -p "$install_root" "$HOME/.local/bin" "$config_home/quickshell" "$config_home/systemd/user" "$config_home/vshell"
case "$(readlink -m "$version_root")" in
  "$install_root"/*) ;;
  *) echo "install.sh: invalid install path" >&2; exit 1 ;;
esac
rm -rf "$version_root"
mkdir -p "$version_root"
tar -xzf "$tmp/$archive" --strip-components=1 -C "$version_root"
ln -sfn "$version_root" "$install_root/current"
ln -sfn "$install_root/current/bin/vshell" "$HOME/.local/bin/vshell"

shell_link="$config_home/quickshell/vshell"
if [[ -e "$shell_link" && ! -L "$shell_link" ]]; then
  echo "install.sh: refusing to replace non-symlink $shell_link" >&2
  exit 1
fi
ln -sfn "$install_root/current/quickshell/vshell" "$shell_link"
service_path="$config_home/systemd/user/vshell.service"
if [[ -L "$service_path" ]]; then
  echo "install.sh: refusing symlinked service path: $service_path" >&2
  exit 1
fi
cp "$version_root/systemd/user/vshell.service" "$service_path"
systemctl --user daemon-reload
if [[ "$start" == true ]]; then
  systemctl --user enable --now vshell.service
fi

echo "VGS $version installed. Run: vshell deps status"