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
# The vendored icon themes are ~48 MiB and ship only with the extras bundle.
rm -rf -- "${bundle:?}/config/vshell/icons"
# Themes: the core set only. The other ~1.0 GiB is scripts/build-assets.sh's
# artifact, and the shell downloads individual themes on demand from the pinned
# catalog. The core set here must match install-system.sh's `core` arm.
mkdir -p "$bundle/themes"
cp -a "$root/themes/coppernight" "$root/themes/targets" "$bundle/themes/"
cp "$root/themes/catalog.json" "$root/themes"/*.md "$bundle/themes/"
# Every other theme's screenshot, so the download browser can SHOW what it
# offers. install-system.sh derives these by scanning the theme tree, which this
# bundle deliberately no longer carries, so they are generated here instead and
# the installer copies them when they are already present.
mkdir -p "$bundle/themes/catalog-previews"
# `theme_name`, NOT `name`: this script's `name` holds the bundle's own
# directory and archive name, and reusing it here silently renamed the artifact
# to whichever theme happened to be last.
for theme in "$root"/themes/*/; do
  theme_name="$(basename "$theme")"
  [[ -f "$theme/theme.json" ]] || continue
  [[ "$theme_name" == "coppernight" ]] && continue
  [[ -f "$theme/preview.png" ]] || continue
  install -Dm644 "$theme/preview.png" "$bundle/themes/catalog-previews/$theme_name.png"
done
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