#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

core="$tmp/core"
extras="$tmp/extras"

# Every recipe that installs VGS must state which theme bundle it wants. The
# default is `core`, so a forgotten variable ships too little instead of the
# ~1.1 GiB `all` bundle, but silently shipping the wrong bundle is still a bug.
# These reference the installer without running it (copy, lint, or run it with
# an explicit bundle of their own), so they are exempt.
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

DESTDIR="$core" VGS_THEME_BUNDLE=core VGS_BACKEND_BINARY=/bin/true \
  "$root/packaging/install-system.sh"
test -f "$core/usr/lib/vshell/themes/coppernight/theme.json"
test -d "$core/usr/lib/vshell/themes/targets"
test ! -e "$core/usr/lib/vshell/themes/tokyo-night"
test ! -e "$core/usr/lib/vshell/config/vshell/icons"
test -x "$core/usr/lib/vshell/bin/vshell-backend"
# The screensaver's default art. It is the only thing standing between a fresh
# install and a saver with nothing to draw, and it is read-only package data —
# the runner cannot regenerate it into /usr, so dropping it here is silent.
test -s "$core/usr/lib/vshell/config/vshell/branding/screensaver.txt"
# The download catalog and the screenshots of the themes core does not install.
# Without them the theme browser on a base install can only offer the one theme
# it ships, which is what VGS-59 was.
test -s "$core/usr/lib/vshell/themes/catalog.json"
test -s "$core/usr/lib/vshell/themes/catalog-previews/tokyo-night.png"
test ! -e "$core/usr/lib/vshell/themes/catalog-previews/coppernight.png"
# `all` copies themes/ wholesale, so it carries the catalog with it and every
# theme's own preview.png; only its 1.1 GiB size keeps it out of this check.
test -f "$root/themes/catalog.json"

DESTDIR="$extras" VGS_THEME_BUNDLE=extras "$root/packaging/install-system.sh"
test -f "$extras/usr/lib/vshell/themes/tokyo-night/theme.json"
test ! -e "$extras/usr/lib/vshell/themes/coppernight"
test -d "$extras/usr/lib/vshell/config/vshell/icons"
test ! -e "$extras/usr/lib/vshell/bin/vshell"
test ! -e "$extras/usr/lib/vshell/themes/catalog-previews"

# A stale catalog is worse than no catalog: it points downloads at files whose
# checksums no longer match, so every install of a changed theme fails.
"$root/scripts/gen-theme-catalog.py" --check

echo "package asset split checks passed"
