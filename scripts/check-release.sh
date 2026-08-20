#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(cat "$root/VERSION")"

grep -q "pkgver=$version" "$root/packaging/arch/PKGBUILD"
grep -q "Version:        $version" "$root/packaging/fedora/vgs-shell.spec"
grep -q "vgs-shell ($version-1)" "$root/packaging/debian/changelog"
grep -q "version=$version" "$root/packaging/void/template"
grep -qx "$version" "$root/quickshell/vshell/VERSION"
# The Gentoo recipe carries its version in its FILENAME, and gen-package-metadata
# deliberately finds it by glob so the rename does not break the generator. That
# means the generator cannot notice a release that forgot to rename it: bumping
# VERSION to 0.3.0 while vgs-shell-0.2.0.ebuild is still the only ebuild passes
# every other check here. The version match belongs at release time, so it is
# asserted here rather than turning the generator back into a hardcoded path.
test -f "$root/packaging/gentoo/vgs-shell-$version.ebuild"
# errexit exempts a pipeline that begins with `!` (SC2251), so the previous
# `! grep -q` form never failed the script — these two checks were inert. The
# patterns match the shapes the files actually use: PKGBUILD carries per-arch
# sha256sums_<arch>= arrays, and the void template's checksum= lines sit
# tab-indented inside a case arm.
if grep -qE "sha256sums(_[a-z0-9_]+)?=\('SKIP'\)" "$root/packaging/arch/PKGBUILD"; then
  echo "check-release: packaging/arch/PKGBUILD still carries a sha256sums SKIP entry" >&2
  exit 1
fi
if grep -qE '^[[:space:]]*checksum=SKIP$' "$root/packaging/void/template"; then
  echo "check-release: packaging/void/template still carries checksum=SKIP" >&2
  exit 1
fi

# A .install scriptlet that no PKGBUILD declares is dead weight: the post-install
# activation message never reaches the user. Keep PKGBUILD, .SRCINFO, and the
# scriptlet file in agreement.
grep -q "install='vgs-shell.install'" "$root/packaging/arch/PKGBUILD"
grep -q '^	install = vgs-shell.install$' "$root/packaging/arch/.SRCINFO"
test -f "$root/packaging/arch/vgs-shell.install"
grep -q "install='vgs-shell-git.install'" "$root/packaging/arch/vgs-shell-git/PKGBUILD"
grep -q '^	install = vgs-shell-git.install$' "$root/packaging/arch/vgs-shell-git/.SRCINFO"
test -f "$root/packaging/arch/vgs-shell-git/vgs-shell-git.install"

# The theme download catalog builds its URLs from a pinned tag, and its
# checksums come from the tree. A release must therefore pin to its own tag AND
# have every theme file committed, or the tag it creates will not serve what the
# catalog describes. Regenerate with `scripts/gen-theme-catalog.py --ref vX.Y.Z --write`.
"$root/scripts/gen-theme-catalog.py" --check-release-pin "$version"

"$root/scripts/gen-package-metadata.py"
# The AUR serves .SRCINFO to paru and yay; a release that publishes one which
# disagrees with its PKGBUILD advertises dependencies the package does not have.
"$root/scripts/check-aur-sync.py"
bash -n "$root/install.sh" "$root/uninstall.sh" "$root/scripts/build-release.sh" "$root/scripts/build-assets.sh" "$root/packaging/install-system.sh" "$root/scripts/check-package-assets.sh"
bash "$root/scripts/check-package-assets.sh"
git diff --check

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"$root/scripts/build-release.sh" "$version" "$(uname -m)" "$tmp" >/dev/null
# The extras bundle is the other half of the release: an assets package built
# from a bundle that never got made would install nothing, and the failure would
# only show up in a user's theme browser.
"$root/scripts/build-assets.sh" "$version" "$tmp" >/dev/null
tar -tzf "$tmp/vgs-$version-assets.tar.gz" > "$tmp/assets.list"
grep -q "/packaging/install-system.sh$" "$tmp/assets.list"
grep -q "/config/vshell/icons/" "$tmp/assets.list"
# The core bundle must NOT carry what the extras bundle exists to hold, or the
# split silently stops saving anything.
archive="$tmp/vgs-$version-linux-$(uname -m).tar.gz"
tar -tzf "$archive" > "$tmp/archive.list"
grep -q "/bin/vshell-backend$" "$tmp/archive.list"
grep -q "/quickshell/vshell/shell.qml$" "$tmp/archive.list"
if grep -q "/config/vshell/icons/" "$tmp/archive.list"; then
  echo "check-release: the core bundle carries config/vshell/icons, which belongs to the extras bundle" >&2
  exit 1
fi
# Screenshots for the themes the core bundle does not install. Without them the
# download browser lists themes it cannot show, and nothing else would notice:
# the installer falls back to scanning a theme tree this bundle no longer has.
grep -q "/themes/catalog-previews/.*\.png$" "$tmp/archive.list"
tar -xzf "$archive" -C "$tmp"
bundle="$tmp/vgs-$version-linux-$(uname -m)"
test "$("$bundle/bin/vshell" --version)" = "$version"
runtime_dir="$tmp/runtime"
mkdir -p "$runtime_dir"
XDG_RUNTIME_DIR="$runtime_dir" VGS_BACKEND_SOCKET='' "$bundle/bin/vshell-backend" methods --json \
  | python3 -c 'import json,sys; expected=sys.argv[1]; actual=json.load(sys.stdin)["cliVersion"]; raise SystemExit(0 if actual == expected else f"backend cliVersion {actual!r} != {expected!r}")' "$version"
echo "release checks passed for $version"
