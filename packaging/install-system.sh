#!/usr/bin/env bash
# Install VGS into one relocatable tree.
#
# Contract for package recipes, flakes and the curl installer:
#   DESTDIR=/staging PREFIX=/usr packaging/install-system.sh
#
# PREFIX selects the runtime prefix. The runtime tree lands at
# $DESTDIR$PREFIX/share/vgs. The command link lands at
# $DESTDIR$PREFIX/bin/vgsh and points to ../share/vgs/bin/vgsh. Root README.md
# and LICENSE land under share/doc/vgs and share/licenses/vgs.
# The installed shell tree drops developer-only AGENTS.md, CLAUDE.md and
# README.md files under shell/. Refusals print one keyed first line.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
source_root="$(cd -- "$(dirname -- "$self")/.." && pwd -P)"
destdir="${DESTDIR:-}"
prefix="${PREFIX:-/usr/local}"

usage() {
  sed -n '2,15{s/^# \{0,1\}//;p}' "$self"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) printf 'install-system: refused: argument=%s\n' "$1" >&2; exit 2 ;;
esac

[[ -n $prefix && $prefix == /* && $prefix != */ ]] || {
  printf 'install-system: refused: prefix=%s\n' "${prefix:-empty}" >&2
  echo 'PREFIX must be an absolute path with no trailing slash' >&2
  exit 2
}
[[ -z $destdir || $destdir != */ ]] || {
  printf 'install-system: refused: destdir=%s\n' "$destdir" >&2
  echo 'DESTDIR must have no trailing slash' >&2
  exit 2
}

for required in bin shell config themes VERSION LICENSE README.md; do
  [[ -e $source_root/$required ]] || {
    printf 'install-system: refused: source=missing path=%s\n' "$source_root/$required" >&2
    exit 1
  }
done

install_root="$destdir$prefix"
runtime_root="$install_root/share/vgs"

skip_shell_markdown() { # RELATIVE_PATH
  [[ $1 == shell/* ]] || return 1
  case "${1##*/}" in
    AGENTS.md|CLAUDE.md|README.md) return 0 ;;
    *) return 1 ;;
  esac
}

tracked_tree() {
  local top
  if top="$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null)" && [[ $top == "$source_root" ]]; then
    git -C "$source_root" ls-files -z -- bin shell config themes VERSION
  else
    python3 - "$source_root" <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for base in ("bin", "shell", "config", "themes"):
    start = root / base
    for current, dirs, files in os.walk(start, followlinks=False):
        dirs[:] = sorted(dirs)
        for name in sorted(files):
            path = pathlib.Path(current) / name
            if path.is_file() or path.is_symlink():
                print(path.relative_to(root).as_posix(), end="\0")
version = root / "VERSION"
if version.is_file() or version.is_symlink():
    print("VERSION", end="\0")
PY
  fi
}

mkdir -p -- "$runtime_root" "$install_root/bin" "$install_root/share/doc/vgs" "$install_root/share/licenses/vgs"

while IFS= read -r -d '' rel; do
  [[ -n $rel ]] || continue
  skip_shell_markdown "$rel" && continue
  src="$source_root/$rel"
  dst="$runtime_root/$rel"
  [[ -f $src || -L $src ]] || continue
  mkdir -p -- "$(dirname -- "$dst")"
  cp -Pp -- "$src" "$dst"
done < <(tracked_tree)

cp -p -- "$source_root/README.md" "$install_root/share/doc/vgs/README.md"
cp -p -- "$source_root/LICENSE" "$install_root/share/licenses/vgs/LICENSE"
ln -sfn -- ../share/vgs/bin/vgsh "$install_root/bin/vgsh"

printf 'install-system: ok prefix=%s root=%s\n' "$prefix" "$install_root"
