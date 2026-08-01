#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(cat "$root/VERSION")"

grep -q "pkgver=$version" "$root/packaging/arch/PKGBUILD"
grep -q "Version:        $version" "$root/packaging/fedora/vgs-shell.spec"
grep -q "vgs-shell ($version-1)" "$root/packaging/debian/changelog"
grep -q "version=$version" "$root/packaging/void/template"
grep -qx "$version" "$root/quickshell/vshell/VERSION"
! grep -q "sha256sums=('SKIP')" "$root/packaging/arch/PKGBUILD"
! grep -q '^checksum=SKIP$' "$root/packaging/void/template"
bash -n "$root/install.sh" "$root/uninstall.sh" "$root/scripts/build-release.sh" "$root/packaging/install-system.sh" "$root/scripts/check-package-assets.sh"
bash "$root/scripts/check-package-assets.sh"
git diff --check

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"$root/scripts/build-release.sh" "$version" "$(uname -m)" "$tmp" >/dev/null
archive="$tmp/vgs-$version-linux-$(uname -m).tar.gz"
tar -tzf "$archive" > "$tmp/archive.list"
grep -q "/bin/vshell-backend$" "$tmp/archive.list"
grep -q "/quickshell/vshell/shell.qml$" "$tmp/archive.list"
tar -xzf "$archive" -C "$tmp"
bundle="$tmp/vgs-$version-linux-$(uname -m)"
test "$("$bundle/bin/vshell" --version)" = "$version"
runtime_dir="$tmp/runtime"
mkdir -p "$runtime_dir"
XDG_RUNTIME_DIR="$runtime_dir" VGS_BACKEND_SOCKET= "$bundle/bin/vshell-backend" methods --json \
  | python3 -c 'import json,sys; expected=sys.argv[1]; actual=json.load(sys.stdin)["cliVersion"]; raise SystemExit(0 if actual == expected else f"backend cliVersion {actual!r} != {expected!r}")' "$version"
echo "release checks passed for $version"
