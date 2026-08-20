#!/usr/bin/env bash
# Build the architecture-independent extras bundle: every theme the core bundle
# leaves out, plus the vendored icon themes.
#
# WHY IT IS ITS OWN ARTIFACT. The extras are ~1.05 GiB against a ~79 MiB shell,
# and nothing about them is architecture-specific. Shipping them inside each
# per-architecture bundle made every download, every distribution build and every
# `install.sh` run pay for wallpapers most installs never use — while the shell
# already downloads individual themes on demand from the pinned catalog.
#
# It carries packaging/install-system.sh so it is self-sufficient: a recipe
# extracts this bundle and runs `VGS_THEME_BUNDLE=extras` against it directly,
# without needing the core tree.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-$(cat "$root/VERSION")}"
out="${2:-$root/dist}"

name="vgs-${version#v}-assets"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/$name"
mkdir -p "$bundle/themes" "$bundle/packaging" "$out"

# Every theme except the one the core bundle already installs. The skip list
# must match install-system.sh's `extras` arm, which skips the same theme.
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

# An incomplete bundle tars and uploads exactly like a complete one, so the
# staged count must equal the eligible source count rather than merely being
# non-empty: a loop that silently dropped 70 of 78 themes would otherwise ship,
# and the only symptom would be themes missing from a user's install.
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
