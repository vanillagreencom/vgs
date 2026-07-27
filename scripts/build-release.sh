#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-$(cat "$root/VERSION")}"
arch="${2:-$(uname -m)}"
out="${3:-$root/dist}"

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

cp -a "$root/quickshell" "$root/config" "$root/themes" "$root/systemd" "$root/third_party" "$bundle/"
mkdir -p "$bundle/packaging"
cp "$root/packaging/install-system.sh" "$bundle/packaging/"
cp -a "$root/bin/." "$bundle/bin/"
rm -f "$bundle/bin/vshell-asdcontrol"
cp "$root/README.md" "$root/LICENSE" "$root/VERSION" "$root/install.sh" "$root/uninstall.sh" "$bundle/"
CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" go build -C "$root/backend" -mod=vendor -trimpath \
  -ldflags="-s -w -X vshell/backend/internal/registry.cliVersion=${version#v}" \
  -o "$bundle/bin/vshell-backend" ./cmd/vshell-backend
if [[ "$arch" == "x86_64" ]] && command -v c++ >/dev/null 2>&1; then
  c++ -std=c++17 -O2 "$root/third_party/asdcontrol/asdcontrol.cpp" -o "$bundle/bin/vshell-asdcontrol"
fi
find "$bundle/bin" -maxdepth 1 -type f -exec chmod 0755 {} +
find "$bundle" -exec touch -h -d '@0' {} +
tar -C "$stage" --sort=name --owner=0 --group=0 --numeric-owner --mtime='@0' -cf - "$name" \
  | gzip -n -9 > "$out/$name.tar.gz"
(cd "$out" && sha256sum "$name.tar.gz")