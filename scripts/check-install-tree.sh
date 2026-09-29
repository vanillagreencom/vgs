#!/usr/bin/env bash
# Assert the installed VGS file list against packaging/install-tree.manifest.
#
# Usage:
#   scripts/check-install-tree.sh [--write] DESTDIR [PREFIX]
#
# DESTDIR is the staging root passed to packaging/install-system.sh. PREFIX
# defaults to /usr/local and must match the installer call. The manifest lists
# files and symlinks relative to PREFIX. --write rewrites the manifest from the
# installed tree after a legitimate shipped file is added.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd -P)"
manifest="$repo/packaging/install-tree.manifest"
write=false
if [[ ${1:-} == --write ]]; then write=true; shift; fi
case "${1:-}" in
  -h|--help) sed -n '2,11{s/^# \{0,1\}//;p}' "$self"; exit 0 ;;
esac
[[ $# -ge 1 && $# -le 2 ]] || { echo 'install-tree: refused: usage=DESTDIR [PREFIX]' >&2; exit 2; }
destdir="$1"
prefix="${2:-/usr/local}"
[[ -n $prefix && $prefix == /* && $prefix != */ ]] || { printf 'install-tree: refused: prefix=%s\n' "${prefix:-empty}" >&2; exit 2; }
root="$destdir$prefix"
[[ -d $root ]] || { printf 'install-tree: refused: root=missing path=%s\n' "$root" >&2; exit 1; }

list_tree() { # ROOT
  python3 - "$1" <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
roots = [root / "bin", root / "share" / "vgs", root / "share" / "doc" / "vgs", root / "share" / "licenses" / "vgs"]
rows = []
for base in roots:
    if not base.exists() and not base.is_symlink():
        continue
    for current, dirs, files in os.walk(base, followlinks=False):
        dirs[:] = sorted(dirs)
        for name in sorted(files):
            path = pathlib.Path(current) / name
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                rows.append(f"l {rel} -> {os.readlink(path)}")
            elif path.is_file():
                rows.append(f"f {rel}")
            else:
                rows.append(f"special {rel}")
for row in sorted(rows):
    print(row)
PY
}

actual_file="$repo/tmp/install-tree-actual.$$"
cleanup() { rm -f -- "$actual_file" "$actual_file.expected"; }
trap cleanup EXIT
mkdir -p -- "$repo/tmp"
list_tree "$root" | LC_ALL=C sort >"$actual_file"

if [[ $write == true ]]; then
  cp -- "$actual_file" "$manifest"
  printf 'install-tree=manifest-updated path=%s\n' "$manifest"
  exit 0
fi
[[ -f $manifest ]] || { printf 'install-tree: refused: manifest=missing path=%s\n' "$manifest" >&2; exit 1; }
LC_ALL=C sort -- "$manifest" >"$actual_file.expected"
if cmp -s -- "$actual_file.expected" "$actual_file"; then
  printf 'install-tree=ok root=%s manifest=%s\n' "$root" "$manifest"
  exit 0
fi
LC_ALL=C comm -23 -- "$actual_file.expected" "$actual_file" | sed 's/^/install-tree=missing entry=/'
LC_ALL=C comm -13 -- "$actual_file.expected" "$actual_file" | sed 's/^/install-tree=extra entry=/'
echo "install-tree=failed manifest=$manifest"
echo "run: packaging/install-system.sh with the same DESTDIR and PREFIX, then scripts/check-install-tree.sh --write DESTDIR PREFIX"
exit 1
