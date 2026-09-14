#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${DESTDIR:-}"
prefix="${PREFIX:-/usr}"
lib="$dest$prefix/lib/vshell"

# One theme set, so there is nothing left to select. A recipe still passing the
# retired variable expects a different tree than this installs.
if [[ -n "${VGS_THEME_BUNDLE:-}" ]]; then
  echo "install-system.sh: VGS_THEME_BUNDLE is retired; this installs the one theme set. Drop it from the caller." >&2
  exit 2
fi

install -d "$lib" "$dest$prefix/bin" "$dest$prefix/lib/systemd/user"
cp -a "$root/quickshell" "$root/config" "$root/third_party" "$lib/"
install -d "$lib/themes"
# Every theme's definitions ship, so a package update refreshes each of them.
# Wallpapers are a download, one release archive per theme pinned by
# themes/catalog.json, except the default theme's, so a first boot has one.
# scripts/check-package-assets.sh holds this tree to
# `scripts/gen-theme-catalog.py --package-files`, which owns that split.
default_theme=bauhaus
for theme_json in "$root"/themes/*/theme.json; do
  theme_dir="${theme_json%/theme.json}"
  theme="${theme_dir##*/}"
  cp -a "$root/themes/$theme" "$lib/themes/"
  if [[ "$theme" != "$default_theme" ]]; then
    rm -rf -- "${lib:?}/themes/${theme:?}/backgrounds"
  fi
done
cp -a "$root/themes/targets" "$lib/themes/"
install -Dm644 "$root/themes/BACKGROUNDS-ATTRIBUTION.md" "$lib/themes/BACKGROUNDS-ATTRIBUTION.md"
install -Dm644 "$root/themes/THEMES-ATTRIBUTION.md" "$lib/themes/THEMES-ATTRIBUTION.md"
# The catalog's archive checksums govern verification of downloaded themes.
# themes/asset-lock.json is publish-time input for the catalog generator and
# is deliberately not installed; the runtime reads the catalog alone.
install -Dm644 "$root/themes/catalog.json" "$lib/themes/catalog.json"
# Ship the 480 px thumbnails, derived from each theme's preview, for the
# surfaces that paint a small tile.
cp -a "$root/themes/thumbnails" "$lib/themes/"
while IFS= read -r -d '' file; do
  [[ "$(basename "$file")" == "vshell-asdcontrol" ]] && continue
  install -Dm755 "$file" "$lib/bin/$(basename "$file")"
done < <(find "$root/bin" -maxdepth 1 -type f -print0)
install -Dm644 "$root/README.md" "$root/LICENSE" "$root/VERSION" -t "$lib"
install -Dm755 "${VGS_BACKEND_BINARY:?set VGS_BACKEND_BINARY}" "$lib/bin/vshell-backend"
if [[ -n "${VGS_ASDCONTROL_BINARY:-}" ]]; then
  install -Dm755 "$VGS_ASDCONTROL_BINARY" "$lib/bin/vshell-asdcontrol"
fi
ln -s ../lib/vshell/bin/vshell "$dest$prefix/bin/vshell"
sed 's|ExecStart=%h/.local/bin/vshell run|ExecStart=/usr/bin/vshell run|' \
  "$root/systemd/user/vshell.service" > "$dest$prefix/lib/systemd/user/vshell.service"
