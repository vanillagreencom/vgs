#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-$(cat "$root/VERSION")}"
arch="${2:-$(uname -m)}"
out="${3:-$root/dist}"
go_toolchain="${VGS_GO_TOOLCHAIN:-go1.23.12}"

case "$arch" in
  x86_64|amd64) goarch=amd64; arch=x86_64 ;;
  aarch64|arm64) goarch=arm64; arch=aarch64 ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac

name="vgs-${version#v}-linux-$arch"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/$name"
mkdir -p "$bundle/bin" "$out"

cp -a "$root/quickshell" "$root/config" "$root/systemd" "$root/third_party" "$bundle/"
# The bundle carries exactly the theme package files install-system.sh keeps.
mkdir -p "$bundle/themes"
"$root/scripts/gen-theme-catalog.py" --package-files > "$stage/theme-files"
tar -C "$root/themes" -cf - --files-from="$stage/theme-files" | tar -C "$bundle/themes" -xf -
cp -a "$root/themes/targets" "$bundle/themes/"
cp "$root/themes/catalog.json" "$root/themes"/*.md "$bundle/themes/"
# install-system.sh installs the thumbnails too.
cp -a "$root/themes/thumbnails" "$bundle/themes/"
mkdir -p "$bundle/packaging"
cp "$root/packaging/install-system.sh" "$bundle/packaging/"
cp -a "$root/bin/." "$bundle/bin/"
rm -f "$bundle/bin/vshell-asdcontrol"
cp "$root/README.md" "$root/LICENSE" "$root/VERSION" "$root/install.sh" "$root/uninstall.sh" "$bundle/"
CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" GOTOOLCHAIN="$go_toolchain" go build -C "$root/backend" -mod=vendor -buildvcs=false -trimpath \
  -ldflags="-s -w -X vshell/backend/internal/registry.cliVersion=${version#v}" \
  -o "$bundle/bin/vshell-backend" ./cmd/vshell-backend
find "$bundle/bin" -maxdepth 1 -type f -exec chmod 0755 {} +
find "$bundle" -exec touch -h -d '@0' {} +
tar -C "$stage" --sort=name --owner=0 --group=0 --numeric-owner --mtime='@0' -cf - "$name" \
  | gzip -n -9 > "$out/$name.tar.gz"
(cd "$out" && sha256sum "$name.tar.gz")