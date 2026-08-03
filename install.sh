#!/usr/bin/env bash
set -euo pipefail

repo="vanillagreencom/vgs"
version="latest"
start=true
force=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:?missing version}"; shift 2 ;;
    --no-start) start=false; shift ;;
    --force) force=true; shift ;;
    -h|--help)
      echo "Usage: install.sh [--version v0.1.0] [--no-start] [--force]"
      echo "  --force  replace paths that point outside the VGS install root"
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

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
install_root="$data_home/vshell"
version_root="$install_root/$version"
cli_link="$HOME/.local/bin/vshell"
shell_link="$config_home/quickshell/vshell"
service_path="$config_home/systemd/user/vshell.service"

# Preflight. Every guard that can abort runs here, before anything the user owns
# is touched, so a refusal is a true no-op instead of a half-applied install.
if [[ -L "$install_root" ]]; then
  echo "install.sh: refusing symlinked install root: $install_root" >&2
  exit 1
fi
install_root_real="$(readlink -m "$install_root")"
case "$(readlink -m "$version_root")" in
  "$install_root_real"/*) ;;
  *) echo "install.sh: invalid install path" >&2; exit 1 ;;
esac

vgs_owned() {
  # True when $1 resolves inside the VGS install root, i.e. VGS put it there.
  local target
  target="$(readlink -m "$1")"
  [[ "$target" == "$install_root_real" || "$target" == "$install_root_real"/* ]]
}

check_managed_link() {
  # Paths VGS owns as symlinks into the install root.
  local path="$1"
  if [[ -L "$path" ]]; then
    vgs_owned "$path" && return 0
    if [[ "$force" == true ]]; then
      echo "install.sh: --force: replacing $path (was -> $(readlink "$path"))" >&2
      return 0
    fi
    echo "install.sh: refusing to replace externally managed symlink: $path -> $(readlink "$path")" >&2
    echo "install.sh: it points outside $install_root, so something else (dotfiles?) manages it." >&2
    echo "install.sh: move it aside, or re-run with --force to replace it." >&2
    exit 1
  fi
  if [[ -e "$path" ]]; then
    echo "install.sh: refusing to replace non-symlink $path" >&2
    echo "install.sh: move it aside and re-run." >&2
    exit 1
  fi
}

check_managed_link "$cli_link"
check_managed_link "$shell_link"
# The service path VGS owns as a regular file; a symlink there is someone else's.
if [[ -L "$service_path" ]]; then
  if [[ "$force" == true ]]; then
    echo "install.sh: --force: replacing $service_path (was -> $(readlink "$service_path"))" >&2
  else
    echo "install.sh: refusing symlinked service path: $service_path -> $(readlink "$service_path")" >&2
    echo "install.sh: move it aside, or re-run with --force to replace it." >&2
    exit 1
  fi
fi

release="${version#v}"
archive="vgs-${release}-linux-${arch}.tar.gz"
base="${VGS_RELEASE_BASE_URL:-https://github.com/$repo/releases/download/$version}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fL "$base/$archive" -o "$tmp/$archive"
curl -fL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"
(cd "$tmp" && grep "  $archive$" SHA256SUMS | sha256sum -c -)

mkdir -p "$install_root" "$HOME/.local/bin" "$config_home/quickshell" "$config_home/systemd/user" "$config_home/vshell"
rm -rf "$version_root"
mkdir -p "$version_root"
tar -xzf "$tmp/$archive" --strip-components=1 -C "$version_root"
ln -sfn "$version_root" "$install_root/current"
ln -sfn "$install_root/current/bin/vshell" "$cli_link"
ln -sfn "$install_root/current/quickshell/vshell" "$shell_link"
rm -f "$service_path"
cp "$version_root/systemd/user/vshell.service" "$service_path"
systemctl --user daemon-reload
if [[ "$start" == true ]]; then
  systemctl --user enable --now vshell.service
fi

echo "VGS $version installed. Run: vshell deps status"