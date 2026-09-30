#!/usr/bin/env bash
# The notifications' image helper. The service runs it with bash from the
# plugin's published source revision, one run at a time, from the store's
# one Process, so a copy never races a sweep of the same directory.
#
#   images.sh prepare <dir> <images dir>        create both directories
#   images.sh copy <images dir> <from> <to>...  copy each pair, one line each:
#                                               copied <to>
#                                               skipped <to> reason=<why>
#   images.sh sweep <images dir> <name>...      remove every file there not
#                                               named, a half-written *.tmp
#                                               copy among them; prints
#                                               removed <count>
#
# A sender's image file is read with a bound: a regular file only, at most
# 5 MiB, within 5 seconds, into a temporary file beside the copy that is
# renamed into place once whole, so a file that grows, blocks or is a FIFO
# neither hangs the queue nor fills the directory. A copy lands only inside
# the images directory. A copy that cannot be made is a `skipped` line, not
# a failure: a sender that deleted its file leaves a card without that image.
#
# Every refusal is one keyed line on stderr:
#   exit 2  notifications-images: refused: usage
#   exit 3  notifications-images: refused: outside=<to> dir=<images dir>
#   exit 4  notifications-images: error=<mkdir|remove> path=<path>
set -euo pipefail

max_bytes=5242880
usage() { printf 'notifications-images: refused: usage\n' >&2; exit 2; }
# inside DIR TO: refuse a copy that would land outside DIR.
inside() {
  local name="${2##*/}"
  if [[ $2 != "$1/$name" || -z $name || $name == . || $name == .. ]]; then
    printf 'notifications-images: refused: outside=%s dir=%s\n' "$2" "$1" >&2
    exit 3
  fi
}
[[ $# -ge 2 ]] || usage
verb="$1"; shift
export LC_ALL=C

case "$verb" in
  prepare)
    [[ $# -eq 2 ]] || usage
    mkdir -p -- "$1" "$2" || { printf 'notifications-images: error=mkdir path=%s\n' "$2" >&2; exit 4; }
    ;;
  copy)
    dir="$1"; shift
    [[ $(( $# % 2 )) -eq 0 ]] || usage
    mkdir -p -- "$dir" || { printf 'notifications-images: error=mkdir path=%s\n' "$dir" >&2; exit 4; }
    while [[ $# -ge 2 ]]; do
      from="$1" to="$2"; shift 2
      inside "$dir" "$to"
      if [[ ! -f $from ]]; then
        printf 'skipped %s reason=missing\n' "$to"
        continue
      fi
      status=0
      timeout 5 head -c "$((max_bytes + 1))" -- "$from" >"$to.tmp" 2>/dev/null || status=$?
      if [[ $status -ne 0 ]]; then
        rm -f -- "$to.tmp"
        if [[ $status -eq 124 ]]; then printf 'skipped %s reason=timeout\n' "$to"; else printf 'skipped %s reason=unreadable\n' "$to"; fi
        continue
      fi
      size="$(stat -c %s -- "$to.tmp")"
      if [[ $size -gt $max_bytes ]]; then
        rm -f -- "$to.tmp"
        printf 'skipped %s reason=too-large\n' "$to"
        continue
      fi
      mv -f -- "$to.tmp" "$to"
      printf 'copied %s\n' "$to"
    done
    ;;
  sweep)
    dir="$1"; shift
    [[ -d $dir ]] || { printf 'removed 0\n'; exit 0; }
    declare -A keep=()
    for name in "$@"; do keep["$name"]=1; done
    removed=0
    shopt -s nullglob dotglob
    for file in "$dir"/*; do
      name="${file##*/}"
      if [[ -n ${keep[$name]:-} ]]; then continue; fi
      rm -f -- "$file" || { printf 'notifications-images: error=remove path=%s\n' "$file" >&2; exit 4; }
      removed=$((removed + 1))
    done
    printf 'removed %d\n' "$removed"
    ;;
  *) usage ;;
esac
