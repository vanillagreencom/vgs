#!/usr/bin/env bash
# Build the VGS source tarball of one commit. This is the one place that
# decides how a release tarball is built: scripts/release, the Arch and
# Fedora container builds and packaging/fedora/srpm.sh all call it.
#
#   scripts/lib/release-tarball.sh COMMIT VERSION OUT
#
# COMMIT is a revision of the git repository this script sits in. VERSION
# names the top directory, vgs-VERSION/: X.Y.Z for a release, the commit id
# for a vgs-git snapshot. OUT is the file to write.
#
# The tarball is `git archive --format=tar --prefix=vgs-VERSION/ COMMIT`
# through `gzip -n -9`. Its bytes are a function of the commit and VERSION:
# git archive stamps every member with the commit's time, and gzip -n
# writes no name and no time. A channel test that packs the commit a
# release tags therefore packs the release asset's bytes, the ones the
# vgs recipe's checksum pins.
#
# It packs a commit, never the working tree. A caller that tests
# uncommitted files writes them as a commit first, as
# scripts/arch-packages.sh does, and gets the tarball a release of that
# commit would publish.
#
# Prints the sha256 of OUT, 64 hex digits, on stdout. Exit 1 prints
# `release-tarball: refused: archive=failed commit=<COMMIT>` or
# `release-tarball: refused: sha256sum=failed path=<OUT>` on stderr. Exit 2
# prints `release-tarball: refused: arguments=<count>`.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/../.." && pwd -P)"

refuse() { # STATUS KEY [DETAIL...]
  local status="$1"
  printf 'release-tarball: refused: %s\n' "$2" >&2
  shift 2
  [[ $# -eq 0 ]] || printf '%s\n' "$@" >&2
  exit "$status"
}

[[ $# -eq 3 ]] || refuse 2 "arguments=$#" "usage: scripts/lib/release-tarball.sh COMMIT VERSION OUT"
commit="$1" version="$2" out="$3"

git -C "$repo" archive --format=tar --prefix="vgs-$version/" "$commit" | gzip -n -9 >"$out" ||
  refuse 1 "archive=failed commit=$commit"
sum="$(sha256sum -- "$out")" || refuse 1 "sha256sum=failed path=$out"
printf '%s\n' "${sum%% *}"
