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

# Catalog checksums must match theme contents or downloads fail verification.
"$root/scripts/gen-theme-catalog.py" --check

echo "package asset checks passed"
