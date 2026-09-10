#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

core="$tmp/core"

python3 - "$root" <<'PY'
import json
import runpy
import sys
from pathlib import Path

root = Path(sys.argv[1])
generator = runpy.run_path(str(root / "scripts/gen-package-metadata.py"))
mapping = json.loads((root / "packaging/optional-packages.json").read_text())
manifest = json.loads((root / "config/vshell/dependencies.json").read_text())
required, _ = generator["required_packages"](mapping)
collected = generator["collect"](manifest, mapping, required)
library = mapping["libraries"]["pillow"]
for distro in generator["DISTROS"]:
    assert library[distro] in collected[distro], f"{distro}: ICC library omitted from optional packages"
    assert library[distro] not in required[distro], f"{distro}: optional ICC library became required"
PY

DESTDIR="$core" VGS_BACKEND_BINARY=/bin/true "$root/packaging/install-system.sh"
test -f "$core/usr/lib/vshell/themes/bauhaus/theme.json"
test -f "$core/usr/lib/vshell/themes/roseofdune/theme.json"
test -d "$core/usr/lib/vshell/themes/targets"
test ! -e "$core/usr/lib/vshell/themes/tokyo-night"
# The retired vgs-shell-assets package was the only carrier of the vendored
# icon themes, so the one remaining install has to ship them.
test -d "$core/usr/lib/vshell/config/vshell/icons"
test -x "$core/usr/lib/vshell/bin/vshell-backend"
# The screensaver needs packaged art because it cannot regenerate data into /usr.
test -s "$core/usr/lib/vshell/config/vshell/branding/screensaver.txt"
# Installs need a thumbnail for every catalogued theme, installed or not,
# so the download browser paints them without a network call.
test -s "$core/usr/lib/vshell/themes/catalog.json"
test -s "$core/usr/lib/vshell/themes/thumbnails/tokyo-night.jpg"
test -s "$core/usr/lib/vshell/themes/thumbnails/bauhaus.jpg"

# The installer's refusal to run under the retired variable is what keeps a
# stale recipe from silently installing a different tree. It enumerates nothing
# and every channel passes through it, so it is the whole retirement gate.
bundle_status=0
DESTDIR="$tmp/retired" VGS_THEME_BUNDLE=extras VGS_BACKEND_BINARY=/bin/true \
  "$root/packaging/install-system.sh" >/dev/null 2>"$tmp/retired.err" || bundle_status=$?
if [[ "$bundle_status" -eq 0 ]]; then
  echo "packaging/install-system.sh accepted VGS_THEME_BUNDLE, so a recipe still passing it installs a tree nobody checks" >&2
  exit 1
fi
grep -q 'VGS_THEME_BUNDLE is retired' "$tmp/retired.err"

# Fedora's %files must enumerate what the install writes. rpmbuild fails on an
# unpackaged file, so a file the install adds and the list does not name breaks
# the Fedora build outright.
spec="$root/packaging/fedora/vgs-shell.spec"
unclaimed=0
while IFS= read -r -d '' installed; do
  name="$(basename -- "$installed")"
  if ! grep -qxF "/usr/lib/vshell/themes/$name" "$spec"; then
    echo "packaging/fedora/vgs-shell.spec: the install writes themes/$name but %files does not name it" >&2
    unclaimed=1
  fi
done < <(find "$core/usr/lib/vshell/themes" -mindepth 1 -maxdepth 1 -type f -print0)
test "$unclaimed" -eq 0

# The single install writes /usr/lib/vshell/config/vshell/icons, the tree the
# retired vgs-shell-assets owned. A channel that ships those paths without
# declaring the obsolescence aborts an upgrade on conflicting files for anyone
# still holding the old package. Each row is one recipe, the field its channel
# spells the relation in, the package it names, and the pattern that finds it.
# The package has its own column so a row and its message cannot disagree, and
# a second retired package costs one row per channel rather than a new regex.
# Arch needs both fields, because pacman honours replaces only for repository
# packages and an AUR install goes through conflicts. vgs-shell-assets-git
# needs no row: it declared provides=('vgs-shell-assets'), which is what pacman
# matches conflicts through.
unowned=0
while IFS='|' read -r recipe field package pattern; do
  if ! declared="$(grep -E "$pattern" "$root/$recipe")"; then
    echo "$recipe: nothing declares the retirement of $package in $field, so an upgrade over it aborts on /usr/lib/vshell/config/vshell/icons" >&2
    unowned=1
    continue
  fi
  # A renamed or mistyped package must not satisfy the row, so each pattern
  # needs a right-hand boundary. The near miss is the recipe's own line.
  if grep -qE "$pattern" <<<"${declared//"$package"/"$package-old"}"; then
    echo "$recipe: the $field pattern also matches $package-old, so a mistyped package would pass" >&2
    unowned=1
  fi
done <<'RECIPES'
packaging/arch/PKGBUILD|replaces|vgs-shell-assets|^replaces=\(.*'vgs-shell-assets'
packaging/arch/PKGBUILD|conflicts|vgs-shell-assets|^conflicts=\(.*'vgs-shell-assets'
packaging/arch/vgs-shell-git/PKGBUILD|replaces|vgs-shell-assets|^replaces=\(.*'vgs-shell-assets'
packaging/arch/vgs-shell-git/PKGBUILD|conflicts|vgs-shell-assets|^conflicts=\(.*'vgs-shell-assets'
packaging/debian/control|Replaces|vgs-shell-assets|^Replaces:(.*[[:space:],])?vgs-shell-assets([[:space:],(]|$)
packaging/debian/control|Breaks|vgs-shell-assets|^Breaks:(.*[[:space:],])?vgs-shell-assets([[:space:],(]|$)
packaging/fedora/vgs-shell.spec|Obsoletes|vgs-shell-assets|^Obsoletes:[[:space:]]+vgs-shell-assets([[:space:]<>=]|$)
packaging/void/template|replaces|vgs-shell-assets|^replaces="(.*[[:space:]])?vgs-shell-assets([<>=[:space:]]|")
RECIPES
test "$unowned" -eq 0

# Catalog checksums must match theme contents or downloads fail verification.
"$root/scripts/gen-theme-catalog.py" --check

echo "package asset checks passed"
