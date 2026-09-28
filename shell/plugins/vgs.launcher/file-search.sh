#!/usr/bin/env bash
# The launcher's file search helper. The launcher runs it with bash from the
# plugin's published source revision; every run is one child process the
# launcher's FileSearch owns and waits for, and nothing is left running.
#
#   file-search.sh query <f|d> <text>   best matches, at most 40, one per line:
#                                       <mtime>\t<mime>\t<path>
#   file-search.sh refresh <f|d>        rebuild that index now
#   file-search.sh apps <path>          the applications that open it, one per
#                                       line: default|other\t<desktop file>
#
# `f` is files, `d` folders. A query ranks a cached name index with
# `fzf --exact`: the name alone, or the whole path when the text holds a `/`.
# The launcher calls `refresh` when it enters f: or F:, so a query never
# waits on a walk once an index exists; a query with no index builds it
# first. The index lives under $XDG_CACHE_HOME/vgs/launcher, holds at most
# 200000 entries, and is replaced whole by a rename, so a reader never sees
# half of one. One build per index runs at a time, under a lock beside it; a
# refresh that finds a build running leaves it to finish. A name holding a
# tab or a newline cannot be one line of the index and is not listed. Hidden
# files are indexed only under ~/.config and ~/.dot, less the excludes below.
#
# Every refusal is one keyed line on stderr:
#   exit 2  file-search: refused: usage
#   exit 3  file-search: missing=<command,...>
#   exit 4  file-search: index=<type> error=<what>
#   exit 5  file-search: vanished=<path>
#   exit 6  file-search: mime=<type> error=<what>
# and every notice one line on stderr with exit 0:
#   file-search: refresh=busy type=<type>
#   file-search: walk=partial type=<type> status=<fd status>
#   file-search: index=<type> truncated=<entries>
#   file-search: vanished=<count>          paths gone since the index was built
set -euo pipefail

# The index a build is writing, removed if the helper ends before the
# rename puts it in place.
scratch=""
cleanup() { [[ -z $scratch ]] || rm -f -- "${scratch:?}" "${scratch:?}.count" "${scratch:?}.walk"; }
trap cleanup EXIT

cache="${XDG_CACHE_HOME:-$HOME/.cache}/vgs/launcher"
limit=40
index_max=200000
hidden_roots=("$HOME/.config" "$HOME/.dot")
hidden_excludes=(-E .git -E node_modules -E 'chromium*' -E BraveSoftware -E google-chrome
  -E Code -E VSCodium -E 1Password -E discord -E Slack -E obsidian -E '*Cache*')

usage() { echo 'file-search: refused: usage' >&2; exit 2; }

need() {
  local command missing=()
  for command in "$@"; do command -v -- "$command" >/dev/null 2>&1 || missing+=("$command"); done
  if ((${#missing[@]})); then
    printf 'file-search: missing=%s\n' "$(IFS=,; echo "${missing[*]}")" >&2
    exit 3
  fi
}

index_error() { printf 'file-search: index=%s error=%s\n' "$1" "$2" >&2; exit 4; }

# Walk and write one index, holding its lock. fd's status 1 is a walk that
# met an unreadable directory and listed the rest: reported, and kept.
build() {
  local type=$1 tmp roots=() root awk_status=0 count walk status
  tmp=$(mktemp -- "$cache/.$type.XXXXXX") || index_error "$type" "mktemp"
  scratch=$tmp
  for root in "${hidden_roots[@]}"; do [[ -d $root ]] && roots+=("$root"); done
  # fd names each unreadable directory on its own stderr, dropped here; its
  # status, kept in $tmp.walk, is what the report carries.
  {
    status=0
    fd -t "$type" --absolute-path --print0 . "$HOME" 2>/dev/null || status=$?
    echo "$status" >"$tmp.walk"
    if ((${#roots[@]})); then
      status=0
      fd -t "$type" --hidden --absolute-path --print0 "${hidden_excludes[@]}" . "${roots[@]}" 2>/dev/null || status=$?
      echo "$status" >>"$tmp.walk"
    fi
  } | awk -v RS='\0' -v max="$index_max" '
    index($0, "\t") || index($0, "\n") { next }
    { sub(/\/$/, ""); name = $0; sub(/.*\//, "", name); print name "\t" $0; if (++count >= max) { truncated = 1; exit } }
    END { if (truncated) print count > "/dev/stderr" }' >"$tmp" 2>"$tmp.count" || awk_status=$?
  count=$(<"$tmp.count")
  walk=$(<"$tmp.walk")
  rm -f -- "$tmp.count" "$tmp.walk"
  if [[ $awk_status -ne 0 ]]; then
    rm -f -- "$tmp"
    index_error "$type" "awk-status-$awk_status"
  fi
  if [[ -n $count ]]; then
    # The ceiling closed the pipe, and fd died of it: not a failed walk.
    printf 'file-search: index=%s truncated=%s\n' "$type" "$count" >&2
  else
    for status in $walk; do
      [[ $status == 0 ]] || { printf 'file-search: walk=partial type=%s status=%s\n' "$type" "$status" >&2; break; }
    done
  fi
  mv -f -- "$tmp" "$cache/$type.idx" || { rm -f -- "$tmp"; index_error "$type" "rename"; }
  scratch=""
}

refresh() {
  local type=$1
  need fd awk flock
  mkdir -p -- "$cache" 2>/dev/null || index_error "$type" "mkdir"
  exec 9>"$cache/.$type.lock" || index_error "$type" "lock"
  if ! flock -n 9; then
    printf 'file-search: refresh=busy type=%s\n' "$type" >&2
    return 0
  fi
  build "$type"
}

query() {
  local type=$1 text=$2 nth=1 matches status path mtime mime vanished=0 shown=0
  [[ -n $text ]] || exit 0
  need fzf stat flock
  [[ $type == f ]] && need file
  local index="$cache/$type.idx"
  if [[ ! -s $index ]]; then
    need fd awk
    mkdir -p -- "$cache" 2>/dev/null || index_error "$type" "mkdir"
    exec 9>"$cache/.$type.lock" || index_error "$type" "lock"
    # A first build: wait for one already running rather than start another.
    flock 9 || index_error "$type" "lock"
    [[ -s $index ]] || build "$type"
    exec 9>&-
  fi
  [[ $text == */* ]] && nth=2
  status=0
  matches=$(fzf --filter "$text" --exact --delimiter $'\t' --nth "$nth" --tiebreak=length,index <"$index") || status=$?
  case $status in
    0) ;;
    1) exit 0 ;;
    *) index_error "$type" "fzf-status-$status" ;;
  esac
  while IFS=$'\t' read -r _ path; do
    ((shown < limit)) || break
    if ! mtime=$(stat -c %Y -- "$path" 2>/dev/null); then
      vanished=$((vanished + 1))
      continue
    fi
    mime=inode/directory
    if [[ $type == f ]] && ! mime=$(file -b --mime-type -- "$path" 2>/dev/null); then
      vanished=$((vanished + 1))
      continue
    fi
    printf '%s\t%s\t%s\n' "$mtime" "$mime" "$path"
    shown=$((shown + 1))
  done <<<"$matches"
  ((vanished)) && printf 'file-search: vanished=%s\n' "$vanished" >&2
  exit 0
}

desktop_file() {
  local dir dirs
  IFS=: read -r -a dirs <<<"${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  for dir in "${dirs[@]}"; do
    [[ -n $dir && -f $dir/applications/$1 ]] && { printf '%s\n' "$dir/applications/$1"; return 0; }
  done
  return 1
}

apps() {
  local path=$1 mime line id file default="" listing
  [[ -e $path ]] || { printf 'file-search: vanished=%s\n' "$path" >&2; exit 5; }
  need gio
  if [[ -d $path ]]; then
    mime=inode/directory
  else
    need xdg-mime
    mime=$(xdg-mime query filetype "$path") || { printf 'file-search: vanished=%s\n' "$path" >&2; exit 5; }
  fi
  listing=$(gio mime "$mime") || { printf 'file-search: mime=%s error=gio-status-%s\n' "$mime" "$?" >&2; exit 6; }
  declare -A seen=()
  while IFS= read -r line; do
    case $line in
      "Default application"*) default=${line##*: }; id=$default ;;
      $'\t'*) id=${line#$'\t'} ;;
      *) continue ;;
    esac
    [[ -n $id && -z ${seen[$id]:-} ]] || continue
    seen[$id]=1
    file=$(desktop_file "$id") || continue
    printf '%s\t%s\n' "$([[ $id == "$default" ]] && echo default || echo other)" "$file"
  done <<<"$listing"
}

case ${1:-} in
  query) [[ $# -eq 3 && ($2 == f || $2 == d) ]] || usage; query "$2" "$3" ;;
  refresh) [[ $# -eq 2 && ($2 == f || $2 == d) ]] || usage; refresh "$2" ;;
  apps) [[ $# -eq 2 && -n $2 ]] || usage; apps "$2" ;;
  *) usage ;;
esac
