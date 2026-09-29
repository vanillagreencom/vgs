#!/usr/bin/env bash
# The notifications' image helper, shell/plugins/vgs.notifications/images.sh,
# against a throwaway directory: preparing the directories, copying a
# sender's files with every skip reason but one, the refusal of a copy that
# would land outside the images directory, a sweep that keeps what is owned
# and removes the rest and every half-written copy, the usage refusals, and
# copies out of a Chromium disk cache: the synthetic entry under
# scripts/smoke/fixtures/slack and planted defects of it. The entry's file
# name, 1e3812948288f1fb_0, was derived for its URL with Python's hashlib as
# Chromium names an entry, the same derivation that named the entries of
# Slack 4.52.162's own cache on 2026-09-28.
# A read that outlasts its five seconds is not exercised: only a device
# that never answers reaches it, and planting one costs more than the case
# is worth, so `reason=timeout` is unexercised.
#
# The controls at the end edit a copy of the helper, one rule at a time, and
# require the suite to fail on each copy.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
helper="$repo/shell/plugins/vgs.notifications/images.sh"
slack="$repo/scripts/smoke/fixtures/slack"
# The EXIT trap is armed only on the directory mktemp made: an empty or
# non-directory answer never reaches rm -rf.
TMP_ROOT="$(mktemp -d)" || { echo "test-notifications-images: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "test-notifications-images: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
for tool in timeout head stat mkfifo sha1sum sha256sum od dd grep; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'test-notifications-images: status=not-measured missing=%s\n' "$tool"
    exit 77
  fi
done

# run HELPER ARGS...: the helper under a clean environment; prints its
# stdout, then `stderr=<first line>` and `exit=<status>`.
run() {
  local script="$1" out err status=0
  shift
  out="$(env -i PATH="$PATH" bash "$script" "$@" 2>"$TMP_ROOT/err")" || status=$?
  err="$(head -n 1 "$TMP_ROOT/err")"
  printf '%s\nstderr=%s\nexit=%s\n' "$out" "$err" "$status"
}

failures=0
check() { # LABEL WANT GOT
  if [[ $2 == "$3" ]]; then return 0; fi
  failures=$((failures + 1))
  printf '  FAIL  %s\n        want %q\n        got  %q\n' "$1" "$2" "$3"
}

suite() {
  local script="$1" before=$failures got world="$TMP_ROOT/world"
  rm -rf -- "${world:?}"
  mkdir -p "$world/sender"
  local state="$world/state" images="$world/state/images"
  printf 'avatar' >"$world/sender/avatar.png"
  head -c 5242880 /dev/zero >"$world/sender/edge.png"
  head -c 5242881 /dev/zero >"$world/sender/huge.png"
  mkfifo "$world/sender/pipe"

  check "prepare makes both directories" $'\nstderr=\nexit=0' "$(run "$script" prepare "$state" "$images")"
  check "the images directory exists" yes "$([[ -d $images ]] && echo yes || echo no)"

  got="$(run "$script" copy "$images" "$world/sender/avatar.png" "$images/1-7-image" "$world/sender/gone.png" "$images/1-7-appIcon" "$world/sender/pipe" "$images/2-7-image" "$world/sender/huge.png" "$images/3-7-image" "$world/sender/edge.png" "$images/4-7-image")"
  check "each copy answers one line" "copied $images/1-7-image
skipped $images/1-7-appIcon reason=missing
skipped $images/2-7-image reason=missing
skipped $images/3-7-image reason=too-large
copied $images/4-7-image
stderr=
exit=0" "$got"
  check "a copy holds the sender's bytes" avatar "$(cat "$images/1-7-image" 2>/dev/null || echo absent)"
  check "a file at the size bound is copied whole" 5242880 "$(stat -c %s -- "$images/4-7-image" 2>/dev/null || echo absent)"
  check "a file past the bound leaves no copy and no half" "" "$(cd "$images" && ls -1 3-7-image* 2>/dev/null || true)"
  check "a missing file leaves no copy" no "$([[ -e $images/1-7-appIcon ]] && echo yes || echo no)"
  check "a copy outside the images directory is refused" "
stderr=notifications-images: refused: outside=$world/elsewhere dir=$images
exit=3" "$(run "$script" copy "$images" "$world/sender/avatar.png" "$world/elsewhere")"
  check "a copy climbing out of the images directory is refused" "
stderr=notifications-images: refused: outside=$images/../x dir=$images
exit=3" "$(run "$script" copy "$images" "$world/sender/avatar.png" "$images/../x")"
  check "an odd number of copy paths is refused" $'\nstderr=notifications-images: refused: usage\nexit=2' "$(run "$script" copy "$images" "$world/sender/avatar.png")"

  printf 'half' >"$images/1-7-image.tmp"
  printf 'orphan' >"$images/9-9-image"
  check "a sweep removes what no entry owns and every half copy" $'removed 3\nstderr=\nexit=0' "$(run "$script" sweep "$images" 1-7-image)"
  check "the sweep keeps what is owned" "1-7-image" "$(cd "$images" && ls -1A)"
  check "a sweep of a directory that is not there removes nothing" $'removed 0\nstderr=\nexit=0' "$(run "$script" sweep "$world/none")"
  check "a sweep owning nothing empties the directory" $'removed 1\nstderr=\nexit=0' "$(run "$script" sweep "$images")"
  check "an unknown verb is refused" $'\nstderr=notifications-images: refused: usage\nexit=2' "$(run "$script" move "$images")"
  check "no arguments are refused" $'\nstderr=notifications-images: refused: usage\nexit=2' "$(run "$script")"

  # A Chromium disk cache: the fixture's one entry, whose file name is the
  # URL's hash as Chromium names it, and planted copies of it, each under
  # the name of the URL it is read for.
  local cache="$world/cache" icons="$world/icons" url="https://avatars.slack-edge.com/fixture/acme_88.png" entry
  entry="$slack/Cache/Cache_Data/1e3812948288f1fb_0"
  local key="1/0/$url"
  mkdir -p "$cache" "$icons"
  cp -- "$entry" "$cache/"
  printf 'stale' >"$icons/T0GONE-0"
  got="$(run "$script" cached "$cache" "$icons" "$icons/T0ACME-0" "$url" "$icons/T0ACME-1" "https://avatars.slack-edge.com/fixture/acme_68.png")"
  local icon_version
  icon_version="$(sha256sum -- "$icons/T0ACME-0")"
  icon_version="${icon_version%% *}"
  icon_version="${icon_version:0:16}"
  check "a cached URL's body is copied and a missing one skipped" "copied $icons/T0ACME-0 version=$icon_version
skipped $icons/T0ACME-1 reason=missing
stderr=
exit=0" "$got"
  check "the copy is the body alone, a PNG" "370 89504e470d0a1a0a" "$(stat -c %s -- "$icons/T0ACME-0" 2>/dev/null || echo absent) $(od -An -tx1 -N8 -- "$icons/T0ACME-0" 2>/dev/null | tr -d ' ')"
  check "the out directory holds only this run's copies" "T0ACME-0" "$(cd "$icons" && ls -1A)"
  # Planted defects, each under the fixture's file name.
  local named="$cache/1e3812948288f1fb_0"
  cp -- "$entry" "$named"
  printf 'X' | dd of="$named" bs=1 seek=$(( 24 + ${#key} - 1 )) conv=notrunc status=none
  check "an entry keyed to another URL is skipped" $'skipped '"$icons/T0ACME-0"$' reason=malformed\nstderr=\nexit=0' "$(run "$script" cached "$cache" "$icons" "$icons/T0ACME-0" "$url")"
  head -c $(( 24 + ${#key} + 370 )) -- "$entry" >"$named"
  check "an entry without its end record is skipped" $'skipped '"$icons/T0ACME-0"$' reason=malformed\nstderr=\nexit=0' "$(run "$script" cached "$cache" "$icons" "$icons/T0ACME-0" "$url")"
  { cat -- "$entry"; head -c 5242880 /dev/zero; } >"$named"
  check "an entry past the bound is skipped" $'skipped '"$icons/T0ACME-0"$' reason=too-large\nstderr=\nexit=0' "$(run "$script" cached "$cache" "$icons" "$icons/T0ACME-0" "$url")"
  check "a skipped entry leaves no copy and no half" "" "$(cd "$icons" && ls -1A)"
  printf 'kept' >"$icons/T0ACME-0"
  check "a cached copy outside the out directory is refused before anything is removed" "
stderr=notifications-images: refused: outside=$world/elsewhere dir=$icons
exit=3 kept" "$(run "$script" cached "$cache" "$icons" "$icons/T0ACME-0" "$url" "$world/elsewhere" "$url") $(cat "$icons/T0ACME-0")"
  check "an odd number of cached arguments is refused" $'\nstderr=notifications-images: refused: usage\nexit=2' "$(run "$script" cached "$cache" "$icons" "$icons/T0ACME-0")"
  [[ $failures -eq $before ]]
}

if ! suite "$helper"; then
  echo "test-notifications-images: failing=$failures"
  exit 1
fi

# One control per rule: a copy with that rule removed and the text around it
# kept. The suite must fail on each.
mkdir -p "$TMP_ROOT/controls"
python3 - "$helper" "$TMP_ROOT/controls" <<'CONTROLS'
import os, sys
source, out = sys.argv[1:]
text = open(source).read()
controls = [
    ("regular files only", "if [[ ! -f $from ]]; then", "if [[ ! -e $from ]]; then"),
    ("size bound", "if [[ $size -gt $max_bytes ]]; then\n", "if false; then\n"),
    ("inside the images directory", 'if [[ $2 != "$1/$name" || -z $name || $name == . || $name == .. ]]; then', 'if [[ -z $name ]]; then'),
    ("cache entry keyed to its URL", 'if [[ $got != "$key" ]]; then echo malformed; return; fi', 'if false; then echo malformed; return; fi'),
    ("cache entry ends in its record", 'if [[ $status -eq 1 ]]; then echo malformed; return; fi', 'if [[ $status -eq 1 ]]; then offsets="$size:"; status=0; fi'),
    ("cache entry bound", 'if [[ $size -gt $max_bytes ]]; then echo too-large; return; fi', 'if false; then echo too-large; return; fi'),
    ("cached out directory emptied", 'rm -f -- "$file" || { printf \'notifications-images: error=remove path=%s\\n\' "$file" >&2; exit 4; }\n    done\n    for ((', 'true || { printf \'notifications-images: error=remove path=%s\\n\' "$file" >&2; exit 4; }\n    done\n    for (('),
    ("cached copy version", 'printf \'copied %s version=%s\\n\' "$to" "$version"', 'printf \'copied %s\\n\' "$to"'),
    ("sweep keeps owned", 'if [[ -n ${keep[$name]:-} ]]; then continue; fi', 'if false; then continue; fi'),
    ("sweep removes orphans", 'rm -f -- "$file" || { printf \'notifications-images: error=remove path=%s\\n\' "$file" >&2; exit 4; }\n      removed=', 'true || { printf \'notifications-images: error=remove path=%s\\n\' "$file" >&2; exit 4; }\n      removed='),
    ("paired copy paths", "[[ $(( $# % 2 )) -eq 0 ]] || usage", "true"),
]
for n, (label, needle, replacement) in enumerate(controls):
    assert text.count(needle) == 1, "control needle must occur once: " + label
    with open(os.path.join(out, "%02d.sh" % n), "w") as fh:
        fh.write(text.replace(needle, replacement))
    with open(os.path.join(out, "%02d.label" % n), "w") as fh:
        fh.write(label)
CONTROLS
passed=0
for copy in "$TMP_ROOT"/controls/*.sh; do
  label="$(<"${copy%.sh}.label")"
  saved=$failures
  if suite "$copy" >/dev/null 2>&1; then
    echo "  FAIL  control \"$label\": the suite passed on a helper without that rule"
    exit 1
  fi
  failures=$saved
  passed=$((passed + 1))
done
if [[ $passed -ne 11 ]]; then
  echo "test-notifications-images: controls=$passed want 11; the control table is broken"
  exit 1
fi
echo "test-notifications-images: ok controls=$passed"
