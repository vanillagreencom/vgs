#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

core="$tmp/core"
extras="$tmp/extras"

DESTDIR="$core" VGS_THEME_BUNDLE=core VGS_BACKEND_BINARY=/bin/true \
  "$root/packaging/install-system.sh"
test -f "$core/usr/lib/vshell/themes/coppernight/theme.json"
test -d "$core/usr/lib/vshell/themes/targets"
test ! -e "$core/usr/lib/vshell/themes/tokyo-night"
test ! -e "$core/usr/lib/vshell/config/vshell/icons"
test -x "$core/usr/lib/vshell/bin/vshell-backend"

DESTDIR="$extras" VGS_THEME_BUNDLE=extras "$root/packaging/install-system.sh"
test -f "$extras/usr/lib/vshell/themes/tokyo-night/theme.json"
test ! -e "$extras/usr/lib/vshell/themes/coppernight"
test -d "$extras/usr/lib/vshell/config/vshell/icons"
test ! -e "$extras/usr/lib/vshell/bin/vshell"

echo "package asset split checks passed"
