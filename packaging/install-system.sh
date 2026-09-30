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
# The installed shell tree drops developer Markdown under shell/.
# Jarvis's backend/skills/voice Markdown is runtime guidance and ships.
# Install into a fresh DESTDIR, or remove an
# old runtime tree before running this script. Refusals print one keyed first
# line.
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
  [[ $1 == shell/plugins/vgs.jarvis/backend/skills/voice/*.md ]] && return 1
  [[ $1 == *.md ]]
}

refuse() { # STATUS KEY [DETAIL...]
  local status="$1"
  printf 'install-system: refused: %s\n' "$2" >&2
  shift 2
  [[ $# -gt 0 ]] && printf '%s\n' "$@" >&2
  exit "$status"
}

directory_nonempty() { # DIR
  local -a entries
  [[ -d $1 ]] || return 1
  shopt -s nullglob dotglob
  entries=("$1"/*)
  shopt -u nullglob dotglob
  ((${#entries[@]} > 0))
}

enumerate_tree() {
  local top
  if top="$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null)" && [[ $top == "$source_root" ]]; then
    git -C "$source_root" ls-files -- bin shell config themes VERSION
  else
    python3 - "$source_root" <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
errors = []
def onerror(error):
    errors.append(f"{error.filename}: {error.strerror}")
for base in ("bin", "shell", "config", "themes"):
    start = root / base
    for current, dirs, files in os.walk(start, followlinks=False, onerror=onerror):
        dirs[:] = sorted(dirs)
        for name in sorted(files):
            path = pathlib.Path(current) / name
            if path.is_file() or path.is_symlink():
                print(path.relative_to(root).as_posix())
version = root / "VERSION"
if version.is_file() or version.is_symlink():
    print("VERSION")
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
  fi
}

bin_link="$install_root/bin/vgsh"
if directory_nonempty "$runtime_root"; then
  refuse 1 "target=not-empty path=$runtime_root" "remove the old tree or install into a fresh DESTDIR"
fi
if [[ -e $bin_link || -L $bin_link ]]; then
  if [[ ! -L $bin_link || $(readlink -- "$bin_link") != "../share/vgs/bin/vgsh" ]]; then
    refuse 1 "link=unexpected path=$bin_link" "remove the old command or install into a fresh DESTDIR"
  fi
fi

enumerate_errors="$(mktemp "${TMPDIR:-/tmp}/vgs-install-enumerate.XXXXXX")" ||
  refuse 1 "enumerate=temp TMPDIR=${TMPDIR:-/tmp}"
cleanup() { rm -f -- "$enumerate_errors"; }
trap cleanup EXIT
if ! entries_text="$(enumerate_tree 2>"$enumerate_errors")"; then
  printf 'install-system: refused: enumerate=failed path=%s\n' "$source_root" >&2
  cat -- "$enumerate_errors" >&2
  exit 1
fi
install_entries=()
if [[ -n $entries_text ]]; then
  mapfile -t install_entries <<<"$entries_text"
fi
if ((${#install_entries[@]} == 0)); then
  refuse 1 "enumerate=empty path=$source_root"
fi

mkdir -p -- "$runtime_root" "$install_root/bin" "$install_root/share/doc/vgs" "$install_root/share/licenses/vgs"

for rel in "${install_entries[@]}"; do
  [[ -n $rel ]] || continue
  skip_shell_markdown "$rel" && continue
  src="$source_root/$rel"
  dst="$runtime_root/$rel"
  [[ -f $src || -L $src ]] || continue
  mkdir -p -- "$(dirname -- "$dst")"
  cp -Pp -- "$src" "$dst"
done

cp -p -- "$source_root/README.md" "$install_root/share/doc/vgs/README.md"
cp -p -- "$source_root/LICENSE" "$install_root/share/licenses/vgs/LICENSE"
ln -sfn -- ../share/vgs/bin/vgsh "$install_root/bin/vgsh"

printf 'install-system: ok prefix=%s root=%s\n' "$prefix" "$install_root"
