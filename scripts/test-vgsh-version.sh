#!/usr/bin/env bash
# Controls for `vgsh --version` and `vgsh version [--json]`: the VERSION
# read, the describe form in a checkout, the checkout test and the
# refusals. Rows run copies of bin/vgsh in trees under $tmp, never this
# repository's own checkout. An exported tree holds bin/ and VERSION and no
# repository; a checkout is one g built. Expected values come from the
# repository's VERSION and from each fixture's own git, never from vgsh.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

want_version="$(<"$repo/VERSION")"
version_tree() { # DIR [VERSION_TEXT]: bin/ and the repository's VERSION, or VERSION_TEXT
  mkdir -p "$1"
  cp -R -- "$repo/bin" "$1/"
  if [[ $# -gt 1 ]]; then printf '%s' "$2" >"$1/VERSION"; else cp -- "$repo/VERSION" "$1/VERSION"; fi
}
cfg="$tmp/cfg-version"
exported="$tmp/version-export"; version_tree "$exported"
INST_BIN="$exported/bin/vgsh" inst "--version in an exported tree prints VERSION" "$cfg" "$rt_empty" 0 "vgs $want_version" "" --version
check "--version prints one line on stdout" test "$(<"$tmp/out")" == "vgs $want_version"
check "--version prints nothing on stderr" test ! -s "$tmp/err"
INST_BIN="$exported/bin/vgsh" inst "version prints the same line" "$cfg" "$rt_empty" 0 "vgs $want_version" "" version
INST_BIN="$exported/bin/vgsh" inst "version --json outside a checkout has a null describe" "$cfg" "$rt_empty" 0 "{\"version\":\"$want_version\",\"describe\":null}" "" version --json

# The export sits untracked inside a repository with a commit, so git
# finds that repository's top level above the tree.
foreign="$tmp/version-foreign"; mkdir -p "$foreign"; printf 'fixture\n' >"$foreign/README"
g init -q "$foreign"; g -C "$foreign" add README; g -C "$foreign" commit -q -m foreign
version_tree "$foreign/vgs"
check "the nested export's repository is the foreign one" test "$(g -C "$foreign/vgs" rev-parse --show-toplevel)" == "$foreign"
INST_BIN="$foreign/vgs/bin/vgsh" inst "an export inside another repository prints VERSION alone" "$cfg" "$rt_empty" 0 "vgs $want_version" "" --version
# GIT_DIR alone makes git take the working directory for the top level.
check "a caller's GIT_DIR makes plain git call the export a checkout" test "$("${base_env[@]}" GIT_DIR="$foreign/.git" git -C "$exported" rev-parse --show-toplevel)" == "$exported"
saved_env=("${base_env[@]}"); base_env+=(GIT_DIR="$foreign/.git")
INST_BIN="$exported/bin/vgsh" inst "a caller's GIT_DIR never gives the export a describe" "$cfg" "$rt_empty" 0 "{\"version\":\"$want_version\",\"describe\":null}" "" version --json
base_env=("${saved_env[@]}")

checkout="$tmp/version-checkout"; version_tree "$checkout"
g init -q "$checkout"; g -C "$checkout" add -A; g -C "$checkout" commit -q -m one
for note in two three; do
  printf '%s\n' "$note" >"$checkout/NOTE"; g -C "$checkout" add NOTE; g -C "$checkout" commit -q -m "$note"
done
hash="$(g -C "$checkout" rev-parse --short HEAD)"
INST_BIN="$checkout/bin/vgsh" inst "a checkout with no release tag counts every commit" "$cfg" "$rt_empty" 0 "vgs $want_version.r3.g$hash" "" --version
INST_BIN="$checkout/bin/vgsh" inst "version --json in a checkout carries the describe form" "$cfg" "$rt_empty" 0 "{\"version\":\"$want_version\",\"describe\":\"$want_version.r3.g$hash\"}" "" version --json
# A repository's core.abbrev of 12 would lengthen git's own abbreviation;
# the describe form keeps 7 hex digits, the AUR -git package convention.
g -C "$checkout" config core.abbrev 12
check "the fixture's own git abbreviates to 12 digits" test "$(g -C "$checkout" rev-parse --short HEAD)" == "$(g -C "$checkout" rev-parse HEAD | cut -c1-12)"
INST_BIN="$checkout/bin/vgsh" inst "a checkout's describe keeps a 7-digit hash under core.abbrev=12" "$cfg" "$rt_empty" 0 "vgs $want_version.r3.g${hash:0:7}" "" --version

# nightly and v1-beta sit on HEAD, nearer than v0.0.9: a describe that
# counted them would name them.
tagged="$tmp/version-tagged"; version_tree "$tagged"
g init -q "$tagged"; g -C "$tagged" add -A; g -C "$tagged" commit -q -m one; g -C "$tagged" tag -a -m v0.0.9 v0.0.9
for note in two three; do
  printf '%s\n' "$note" >"$tagged/NOTE"; g -C "$tagged" add NOTE; g -C "$tagged" commit -q -m "$note"
done
g -C "$tagged" tag nightly; g -C "$tagged" tag v1-beta
hash="$(g -C "$tagged" rev-parse --short HEAD)"
INST_BIN="$tagged/bin/vgsh" inst "a checkout prints the release tag's version and the distance from it" "$cfg" "$rt_empty" 0 "vgs 0.0.9.r2.g$hash" "" --version
INST_BIN="$tagged/bin/vgsh" inst "version --json keeps VERSION beside the tag's describe form" "$cfg" "$rt_empty" 0 "{\"version\":\"$want_version\",\"describe\":\"0.0.9.r2.g$hash\"}" "" version --json
g -C "$tagged" config core.abbrev 12
INST_BIN="$tagged/bin/vgsh" inst "a tagged describe keeps a 7-digit hash under core.abbrev=12" "$cfg" "$rt_empty" 0 "vgs 0.0.9.r2.g${hash:0:7}" "" --version
g -C "$tagged" tag v2.0
INST_BIN="$tagged/bin/vgsh" inst "a release tag that is not v<X.Y.Z> is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: tag=v2.0 reason=not-a-version" --version

unborn="$tmp/version-unborn"; version_tree "$unborn"; g init -q "$unborn"
INST_BIN="$unborn/bin/vgsh" inst "a checkout with no commit is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: git=describe path=$unborn" --version

bad="$tmp/version-bad"; version_tree "$bad"; rm -- "$bad/VERSION"
INST_BIN="$bad/bin/vgsh" inst "a missing VERSION is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: version=missing path=$bad/VERSION" --version
INST_BIN="$bad/bin/vgsh" inst "a refused version --json prints nothing on stdout" "$cfg" "$rt_empty" 1 "" "vgsh: refused: version=missing path=$bad/VERSION" version --json
for text in '0.1\n' '0.1.0' 'v0.1.0\n' '0.1.0\n0.2.0\n' '0.1.0\n\n'; do
  printf '%b' "$text" >"$bad/VERSION"
  INST_BIN="$bad/bin/vgsh" inst "a VERSION of [$text] is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: version=malformed path=$bad/VERSION" --version
done
for args in 'version extra' '--version extra' '--version --json' 'version --json extra'; do
  read -r -a words <<<"$args"
  INST_BIN="$exported/bin/vgsh" inst "$args is a bad invocation" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=${words[-1]}" "${words[@]}"
done

# The must-fail control: a copy of vgsh that prints a fixed version instead
# of reading VERSION passes every row above whose tree holds the
# repository's VERSION, and fails the row below, whose VERSION differs.
other="$tmp/version-other"; version_tree "$other" $'9.8.7\n'
INST_BIN="$other/bin/vgsh" inst "--version prints the tree's own VERSION" "$cfg" "$rt_empty" 0 "vgs 9.8.7" "" --version
python3 - "$other/bin/vgsh" "$want_version" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = 'cat -- "$file" 2>/dev/null'
count = text.count(old)
if count != 1:
    raise SystemExit(f"version-read-control: expected one match, found {count}")
changed = text.replace(old, f"printf '%s\\n' {sys.argv[2]}")
if changed == text:
    raise SystemExit("version-read-control: mutation changed nothing")
path.write_text(changed)
PY
INST_BIN="$other/bin/vgsh" inst "the VERSION-ignoring mutant prints its fixed version, not the tree's" "$cfg" "$rt_empty" 0 "vgs $want_version" "" --version

rows_done test-vgsh-version
