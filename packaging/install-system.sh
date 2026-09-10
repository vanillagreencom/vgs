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
# Only the two bundled themes ship with their imagery. Every other theme is a
# download: themes/catalog.json pins one release archive per theme.
cp -a "$root/themes/bauhaus" "$root/themes/roseofdune" "$root/themes/targets" "$lib/themes/"
install -Dm644 "$root/themes/BACKGROUNDS-ATTRIBUTION.md" "$lib/themes/BACKGROUNDS-ATTRIBUTION.md"
install -Dm644 "$root/themes/THEMES-ATTRIBUTION.md" "$lib/themes/THEMES-ATTRIBUTION.md"
# The catalog's archive checksums govern verification of downloaded themes.
# themes/asset-lock.json is publish-time input for the catalog generator and
# is deliberately not installed; the runtime reads the catalog alone.
install -Dm644 "$root/themes/catalog.json" "$lib/themes/catalog.json"
# Ship the 480 px thumbnails so the download browser can paint every
# uninstalled theme on first open, with no network call.
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
