#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${DESTDIR:-}"
prefix="${PREFIX:-/usr}"
lib="$dest$prefix/lib/vshell"
# Default to the small bundle on purpose: `all` costs ~1.1 GiB of themes and
# icons, so a packaging recipe that forgets VGS_THEME_BUNDLE should ship too
# little rather than too much. scripts/check-package-assets.sh enforces that
# every in-repo caller states its bundle explicitly.
theme_bundle="${VGS_THEME_BUNDLE:-core}"

case "$theme_bundle" in
  all|core|extras) ;;
  *)
    echo "VGS_THEME_BUNDLE must be one of: all, core, extras" >&2
    exit 2
    ;;
esac

# Screenshots of the themes this bundle does not install, so `vshell theme
# catalog` can show them before they are downloaded. `all` needs none of this:
# every theme ships its own preview.png.
install_catalog_previews() {
  # The release bundle ships these already generated, because it deliberately
  # does not carry the themes they are screenshots OF — scripts/build-release.sh
  # renders them from the full tree at build time. A source checkout still has
  # that tree, so it derives them below. Copying when they exist is what lets one
  # installer serve both.
  if [[ -d "$root/themes/catalog-previews" ]]; then
    cp -a "$root/themes/catalog-previews" "$lib/themes/"
    return
  fi
  install -d "$lib/themes/catalog-previews"
  shopt -s nullglob
  local theme name
  for theme in "$root"/themes/*; do
    [[ -f "$theme/theme.json" ]] || continue
    name="${theme##*/}"
    [[ -f "$lib/themes/$name/preview.png" ]] && continue
    [[ -f "$theme/preview.png" ]] || continue
    install -Dm644 "$theme/preview.png" "$lib/themes/catalog-previews/$name.png"
  done
}

install_themes() {
  case "$theme_bundle" in
    all)
      cp -a "$root/themes" "$lib/"
      ;;
    core)
      install -d "$lib/themes"
      cp -a "$root/themes/coppernight" "$root/themes/targets" "$lib/themes/"
      install -Dm644 "$root/themes/BACKGROUNDS-ATTRIBUTION.md" "$lib/themes/BACKGROUNDS-ATTRIBUTION.md"
      install -Dm644 "$root/themes/THEMES-ATTRIBUTION.md" "$lib/themes/THEMES-ATTRIBUTION.md"
      # The download catalog: what `vshell theme catalog` lists, and the pinned,
      # checksummed manifest it verifies every downloaded file against.
      install -Dm644 "$root/themes/catalog.json" "$lib/themes/catalog.json"
      # Every theme's screenshot, ~23 MiB, against the ~1.1 GiB of wallpapers
      # that motivated the split. Without them the download browser can list the
      # other themes but not show any of them, so they belong in the base
      # package even though their palettes and wallpapers do not.
      install_catalog_previews
      ;;
    extras)
      install -d "$lib/themes"
      shopt -s nullglob
      local theme
      for theme in "$root"/themes/*; do
        [[ -f "$theme/theme.json" ]] || continue
        [[ "${theme##*/}" == "coppernight" ]] && continue
        cp -a "$theme" "$lib/themes/"
      done
      ;;
  esac
}

install -d "$lib"
if [[ "$theme_bundle" == "extras" ]]; then
  install_themes
  install -d "$lib/config/vshell"
  cp -a "$root/config/vshell/icons" "$lib/config/vshell/"
  exit 0
fi

install -d "$dest$prefix/bin" "$dest$prefix/lib/systemd/user"
cp -a "$root/quickshell" "$root/config" "$root/third_party" "$lib/"
rm -rf "$lib/config/vshell/icons"
install_themes
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
