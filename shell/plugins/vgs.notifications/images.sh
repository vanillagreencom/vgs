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
#   images.sh cached <cache dir> <out dir> <to> <url>...
#                                               empty <out dir>, then copy
#                                               each URL's body out of a
#                                               Chromium disk cache to <to>,
#                                               one line each, as copy does
#
# A sender's image file is read with a bound: a regular file only, at most
# 5 MiB, within 5 seconds, into a temporary file beside the copy that is
# renamed into place once whole, so a file that grows, blocks or is a FIFO
# neither hangs the queue nor fills the directory. A copy lands only inside
# the images directory. A copy that cannot be made is a `skipped` line, not
# a failure: a sender that deleted its file leaves a card without that image.
#
# `cached` reads the simple cache an Electron client such as Slack keeps
# (read against Slack 4.52.162's Cache/Cache_Data on 2026-09-28). A URL's
# entry is the file <hash>_0, where <hash> is the first 8 bytes of the SHA-1
# of the key "1/0/<url>" read as a little-endian number, in 16 hex digits.
# The file opens with a 24-byte header whose bytes 12-15 are the key's
# length, little-endian, then the key, then the body, then an end record
# opening with the bytes d8 41 0d 97 45 6f fa f4. An entry that is missing,
# past 5 MiB, keyed to another URL or without its end record is `skipped`
# with reason missing, too-large or malformed, and one a read fails on with
# reason unreadable. <out dir> holds only what
# this verb writes, so emptying it first drops the icons of a workspace
# that is gone.
#
# Every refusal is one keyed line on stderr:
#   exit 2  notifications-images: refused: usage
#   exit 3  notifications-images: refused: outside=<to> dir=<images dir>
#   exit 4  notifications-images: error=<mkdir|list|remove> path=<path>
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
# cache_body CACHE URL TO: the body of URL's cache entry into TO.tmp, or
# the reason it cannot be read on stdout.
cache_body() {
  local cache="$1" url="$2" to="$3" key sum hash="" i entry size keylen got offsets end start status=0
  key="1/0/$url"
  if ! sum="$(printf '%s' "$key" | sha1sum)"; then echo unreadable; return; fi
  for (( i = 14; i >= 0; i -= 2 )); do hash+="${sum:i:2}"; done
  entry="$cache/${hash}_0"
  if [[ ! -f $entry ]]; then echo missing; return; fi
  if ! size="$(stat -c %s -- "$entry")"; then echo unreadable; return; fi
  if [[ $size -gt $max_bytes ]]; then echo too-large; return; fi
  if ! keylen="$(od --endian=little -An -tu4 -j12 -N4 -- "$entry" | tr -d ' ')"; then echo unreadable; return; fi
  if [[ $keylen != "${#key}" ]]; then echo malformed; return; fi
  if ! got="$(dd if="$entry" iflag=skip_bytes,count_bytes skip=24 count="$keylen" status=none)"; then echo unreadable; return; fi
  if [[ $got != "$key" ]]; then echo malformed; return; fi
  offsets="$(grep -obUaP '\xd8\x41\x0d\x97\x45\x6f\xfa\xf4' -- "$entry")" || status=$?
  if [[ $status -eq 1 ]]; then echo malformed; return; fi
  if [[ $status -ne 0 ]]; then echo unreadable; return; fi
  end="${offsets%%$'\n'*}"
  end="${end%%:*}"
  start=$(( 24 + keylen ))
  if [[ $end -le $start ]]; then echo malformed; return; fi
  dd if="$entry" of="$to.tmp" iflag=skip_bytes,count_bytes skip="$start" count=$(( end - start )) status=none || echo unreadable
}
version_of() {
  local sum
  sum="$(sha256sum -- "$1")" || return
  sum="${sum%% *}"
  printf '%s' "${sum:0:16}"
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
  cached)
    [[ $# -ge 2 && $(( $# % 2 )) -eq 0 ]] || usage
    cache="$1" dir="$2"; shift 2
    pairs=("$@")
    for (( i = 0; i < ${#pairs[@]}; i += 2 )); do inside "$dir" "${pairs[i]}"; done
    mkdir -p -- "$dir" || { printf 'notifications-images: error=mkdir path=%s\n' "$dir" >&2; exit 4; }
    shopt -s nullglob dotglob
    for file in "$dir"/*; do
      rm -f -- "$file" || { printf 'notifications-images: error=remove path=%s\n' "$file" >&2; exit 4; }
    done
    for (( i = 0; i < ${#pairs[@]}; i += 2 )); do
      to="${pairs[i]}" url="${pairs[i + 1]}"
      if ! reason="$(cache_body "$cache" "$url" "$to")"; then reason=unreadable; fi
      if [[ -n $reason ]]; then
        rm -f -- "$to.tmp"
        printf 'skipped %s reason=%s\n' "$to" "$reason"
        continue
      fi
      mv -f -- "$to.tmp" "$to"
      if ! version="$(version_of "$to")"; then
        rm -f -- "$to"
        printf 'skipped %s reason=unreadable\n' "$to"
        continue
      fi
      printf 'copied %s version=%s\n' "$to" "$version"
    done
    ;;
  *) usage ;;
esac
