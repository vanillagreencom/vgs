#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

core="$tmp/core"
extras="$tmp/extras"

# A missing bundle choice defaults to core and can silently omit intended themes.
# These references copy or inspect the installer, or invoke it with their own explicit choice.
non_callers=(
  packaging/install-system.sh
  scripts/build-release.sh
  scripts/check-package-assets.sh
  scripts/check-release.sh
  scripts/gen-theme-catalog.py
  bin/vshell-helper
)

missing=0
while IFS= read -r caller; do
  for exempt in "${non_callers[@]}"; do
    [[ "$caller" == "$exempt" ]] && continue 2
  done
  if ! grep -q 'VGS_THEME_BUNDLE=[a-z]' "$root/$caller"; then
    echo "$caller runs install-system.sh without setting VGS_THEME_BUNDLE" >&2
    missing=1
  fi
done < <(git -C "$root" grep -l 'install-system\.sh' -- . ':!docs' ':!*.md')
test "$missing" -eq 0

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

DESTDIR="$core" VGS_THEME_BUNDLE=core VGS_BACKEND_BINARY=/bin/true \
  "$root/packaging/install-system.sh"
test -f "$core/usr/lib/vshell/themes/coppernight/theme.json"
test -d "$core/usr/lib/vshell/themes/targets"
test ! -e "$core/usr/lib/vshell/themes/tokyo-night"
test ! -e "$core/usr/lib/vshell/config/vshell/icons"
test -x "$core/usr/lib/vshell/bin/vshell-backend"
# The screensaver needs packaged art because it cannot regenerate data into /usr.
test -s "$core/usr/lib/vshell/config/vshell/branding/screensaver.txt"
# Core installs need catalog previews for themes available to download.
test -s "$core/usr/lib/vshell/themes/catalog.json"
test -s "$core/usr/lib/vshell/themes/catalog-previews/tokyo-night.png"
test ! -e "$core/usr/lib/vshell/themes/catalog-previews/coppernight.png"
# The all bundle carries themes/ directly. This check avoids copying that full tree.
test -f "$root/themes/catalog.json"

DESTDIR="$extras" VGS_THEME_BUNDLE=extras "$root/packaging/install-system.sh"
test -f "$extras/usr/lib/vshell/themes/tokyo-night/theme.json"
test ! -e "$extras/usr/lib/vshell/themes/coppernight"
test -d "$extras/usr/lib/vshell/config/vshell/icons"
test ! -e "$extras/usr/lib/vshell/bin/vshell"
test ! -e "$extras/usr/lib/vshell/themes/catalog-previews"

# Catalog checksums must match theme contents or downloads fail verification.
"$root/scripts/gen-theme-catalog.py" --check

echo "package asset split checks passed"
