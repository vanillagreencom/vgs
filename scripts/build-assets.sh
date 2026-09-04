#!/usr/bin/env bash
# The extras bundle is architecture independent. It includes its own installer.
# Consumers must run packaging/install-system.sh with VGS_THEME_BUNDLE=extras.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-$(cat "$root/VERSION")}"
out="${2:-$root/dist}"

name="vgs-${version#v}-assets"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/$name"
mkdir -p "$bundle/themes" "$bundle/packaging" "$out"

# The exclusions must match install-system.sh's extras bundle.
shopt -s nullglob
for theme in "$root"/themes/*/; do
  name_theme="$(basename "$theme")"
  [[ -f "$theme/theme.json" ]] || continue
  [[ "$name_theme" == "coppernight" ]] && continue
  cp -a "$theme" "$bundle/themes/"
done

mkdir -p "$bundle/config/vshell"
cp -a "$root/config/vshell/icons" "$bundle/config/vshell/"
cp "$root/packaging/install-system.sh" "$bundle/packaging/"
cp "$root/LICENSE" "$root/VERSION" "$bundle/"

# An archive can succeed with missing themes. Compare the staged set size with all eligible sources.
staged="$(find "$bundle/themes" -mindepth 1 -maxdepth 1 -type d | wc -l)"
eligible=0
for theme in "$root"/themes/*/; do
  [[ -f "$theme/theme.json" ]] || continue
  [[ "$(basename "$theme")" == "coppernight" ]] && continue
  eligible=$((eligible + 1))
done
if [[ "$staged" -ne "$eligible" ]]; then
  echo "build-assets: staged $staged theme(s) but $eligible are eligible in themes/" >&2
  exit 1
fi
if [[ "$eligible" -eq 0 ]]; then
  echo "build-assets: no eligible themes found; the extras bundle would be empty" >&2
  exit 1
fi

find "$bundle" -exec touch -h -d '@0' {} +
tar -C "$stage" --sort=name --owner=0 --group=0 --numeric-owner --mtime='@0' -cf - "$name" \
  | gzip -n -9 > "$out/$name.tar.gz"
(cd "$out" && sha256sum "$name.tar.gz")
