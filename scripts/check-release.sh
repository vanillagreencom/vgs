#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(cat "$root/VERSION")"

grep -q "pkgver=$version" "$root/packaging/arch/PKGBUILD"
# The assets recipe must reference the release being published.
grep -q "pkgver=$version" "$root/packaging/arch/vgs-shell-assets/PKGBUILD"
grep -q "Version:        $version" "$root/packaging/fedora/vgs-shell.spec"
grep -q "vgs-shell ($version-1)" "$root/packaging/debian/changelog"
grep -q "version=$version" "$root/packaging/void/template"
grep -qx "$version" "$root/quickshell/vshell/VERSION"
# Gentoo stores its version in the ebuild filename. Metadata generation discovers it by glob,
# so that generation alone cannot detect a missing release rename.
test -f "$root/packaging/gentoo/vgs-shell-$version.ebuild"
# errexit does not fail on a negated pipeline. Use an explicit failure branch.
# Checksum patterns must cover architecture arrays and indented template fields.
if grep -qE "sha256sums(_[a-z0-9_]+)?=\('SKIP'\)" "$root/packaging/arch/PKGBUILD"; then
  echo "check-release: packaging/arch/PKGBUILD still carries a sha256sums SKIP entry" >&2
  exit 1
fi
if grep -qE '^[[:space:]]*checksum=SKIP$' "$root/packaging/void/template"; then
  echo "check-release: packaging/void/template still carries checksum=SKIP" >&2
  exit 1
fi

# The activation message requires agreement between PKGBUILD, .SRCINFO, and the scriptlet.
grep -q "install='vgs-shell.install'" "$root/packaging/arch/PKGBUILD"
grep -q '^	install = vgs-shell.install$' "$root/packaging/arch/.SRCINFO"
test -f "$root/packaging/arch/vgs-shell.install"
grep -q "install='vgs-shell-git.install'" "$root/packaging/arch/vgs-shell-git/PKGBUILD"
grep -q '^	install = vgs-shell-git.install$' "$root/packaging/arch/vgs-shell-git/.SRCINFO"
test -f "$root/packaging/arch/vgs-shell-git/vgs-shell-git.install"

# Catalog URLs must resolve to committed theme contents under this release tag.
"$root/scripts/gen-theme-catalog.py" --check-release-pin "$version"

"$root/scripts/gen-package-metadata.py"
# AUR clients read .SRCINFO, so it must agree with PKGBUILD.
"$root/scripts/check-aur-sync.py"
bash -n "$root/install.sh" "$root/uninstall.sh" "$root/scripts/build-release.sh" "$root/scripts/build-assets.sh" "$root/packaging/install-system.sh" "$root/scripts/check-package-assets.sh"
bash "$root/scripts/check-package-assets.sh"
git diff --check

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"$root/scripts/build-release.sh" "$version" "$(uname -m)" "$tmp" >/dev/null
# Build the extras archive to verify that its installer and theme data are present.
"$root/scripts/build-assets.sh" "$version" "$tmp" >/dev/null
tar -tzf "$tmp/vgs-$version-assets.tar.gz" > "$tmp/assets.list"
grep -q "/packaging/install-system.sh$" "$tmp/assets.list"
grep -q "/config/vshell/icons/" "$tmp/assets.list"
# Core must omit assets assigned to the extras archive.
archive="$tmp/vgs-$version-linux-$(uname -m).tar.gz"
tar -tzf "$archive" > "$tmp/archive.list"
grep -q "/bin/vshell-backend$" "$tmp/archive.list"
grep -q "/quickshell/vshell/shell.qml$" "$tmp/archive.list"
if grep -q "/config/vshell/icons/" "$tmp/archive.list"; then
  echo "check-release: the core bundle carries config/vshell/icons, which belongs to the extras bundle" >&2
  exit 1
fi
# Compare the preview set with all eligible themes. A nonempty archive can still omit previews.
sed -n 's|.*/themes/catalog-previews/\(.*\)\.png$|\1|p' "$tmp/archive.list" | sort > "$tmp/previews.have"
for theme in "$root"/themes/*/; do
  name="$(basename "$theme")"
  [[ -f "$theme/theme.json" ]] || continue
  [[ "$name" == "coppernight" ]] && continue
  [[ -f "$theme/preview.png" ]] || continue
  echo "$name"
done | sort > "$tmp/previews.want"
# Any failed comparison must stop the check, including errors while reading either file.
if ! preview_diff="$(diff "$tmp/previews.want" "$tmp/previews.have")"; then
  echo "check-release: the core bundle's catalog previews do not match the themes that have one:" >&2
  printf '%s\n' "$preview_diff" >&2
  exit 1
fi
tar -xzf "$archive" -C "$tmp"
bundle="$tmp/vgs-$version-linux-$(uname -m)"
test "$("$bundle/bin/vshell" --version)" = "$version"
runtime_dir="$tmp/runtime"
mkdir -p "$runtime_dir"
XDG_RUNTIME_DIR="$runtime_dir" VGS_BACKEND_SOCKET='' "$bundle/bin/vshell-backend" methods --json \
  | python3 -c 'import json,sys; expected=sys.argv[1]; actual=json.load(sys.stdin)["cliVersion"]; raise SystemExit(0 if actual == expected else f"backend cliVersion {actual!r} != {expected!r}")' "$version"
echo "release checks passed for $version"
