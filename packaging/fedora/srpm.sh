#!/usr/bin/env bash
# Write the source RPM of one Fedora package of COPR vanillagreen/vgs.
#
# Usage: packaging/fedora/srpm.sh --spec SPEC --outdir DIR [--tarball FILE]
#
# SPEC is packaging/fedora/vgs.spec or packaging/fedora/vgs-git.spec, taken
# from the checkout this script sits in. COPR runs it through .copr/Makefile
# (the make_srpm method); a maintainer or scripts/fedora-container.sh runs it
# directly.
#
# vgs.spec, the release: the checkout must sit at tag v<VERSION>, and the
# spec's Version must be VERSION's line. Source0 is the release tarball,
# downloaded over HTTPS from the URL the spec names, or FILE with --tarball,
# which must unpack to vgs-<VERSION>/ holding that VERSION.
#
# vgs-git.spec, main: the version is the RPM form of `vgsh version`'s
# describe, X.Y.Z^<count>.git<hash> for X.Y.Z.r<count>.g<hash>, so the
# package and `vgsh --version` in the checkout agree. The script packs HEAD
# as vgs-<commit>.tar.gz with scripts/lib/release-tarball.sh, the release's
# builder, and writes a spec copy that defines vgs_version and vgs_commit
# ahead of the template and ends its %changelog with one entry of the
# commit's author and UTC date. A shallow clone is refused, since its
# commit count is short.
#
# Prints `srpm: ok path=<file> version=<version>`. Refusals exit 1 with one
# keyed first line `srpm: refused: ...`; usage errors exit 2.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
root="$(cd -- "$(dirname -- "$self")/../.." && pwd -P)"
version_re='^[0-9]+\.[0-9]+\.[0-9]+$'

usage() { sed -n '2,26{s/^# \{0,1\}//;p}' "$self"; }

refuse() { # STATUS KEY [DETAIL...]
  local status="$1"
  printf 'srpm: refused: %s\n' "$2" >&2
  shift 2
  [[ $# -gt 0 ]] && printf '%s\n' "$@" >&2
  exit "$status"
}

spec_arg="" outdir="" tarball=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --spec|--outdir|--tarball)
      [[ $# -ge 2 && -n $2 ]] || refuse 2 "argument=$1 value=missing"
      case "$1" in
        --spec) spec_arg="$2" ;;
        --outdir) outdir="$2" ;;
        --tarball) tarball="$2" ;;
      esac
      shift 2 ;;
    *) refuse 2 "argument=$1" ;;
  esac
done
[[ -n $spec_arg ]] || refuse 2 "argument=--spec value=missing"
[[ -n $outdir ]] || refuse 2 "argument=--outdir value=missing"

spec="$(readlink -f -- "$spec_arg")" || refuse 1 "spec=missing path=$spec_arg"
[[ -f $spec ]] || refuse 1 "spec=missing path=$spec_arg"
case "$spec" in
  "$root/packaging/fedora/vgs.spec") package=vgs ;;
  "$root/packaging/fedora/vgs-git.spec") package=vgs-git ;;
  *) refuse 1 "spec=unknown path=$spec" "use packaging/fedora/vgs.spec or packaging/fedora/vgs-git.spec of this checkout" ;;
esac
[[ -z $tarball || $package == vgs ]] || refuse 2 "argument=--tarball package=$package" "--tarball applies to the release package only"

for tool in git gzip rpmbuild rpmspec; do
  command -v -- "$tool" >/dev/null || refuse 1 "tool=missing name=$tool"
done

# COPR's make_srpm runs as root in a mock chroot over a clone another user
# owns, where git refuses the repository as dubious. Trusting this one
# checkout, through the environment so vgsh's git calls inherit it too,
# keeps every caller-set entry.
n="${GIT_CONFIG_COUNT:-0}"
[[ $n =~ ^[0-9]+$ ]] || refuse 1 "git-config-count=$n"
export "GIT_CONFIG_KEY_$n=safe.directory" "GIT_CONFIG_VALUE_$n=$root"
export GIT_CONFIG_COUNT=$((n + 1))
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" && [[ $top == "$root" ]] ||
  refuse 1 "checkout=missing path=$root" "srpm.sh builds from the git checkout it sits in"

# `vgsh version --json` prints {"version":"X.Y.Z","describe":"X.Y.Z.rN.gHASH"}.
version_json="$("$root/bin/vgsh" version --json)" || refuse 1 "vgsh=version path=$root/bin/vgsh"
[[ $version_json =~ ^\{\"version\":\"([0-9.]+)\",\"describe\":\"([0-9.]+)\.r([0-9]+)\.g([0-9a-f]+)\"\}$ ]] ||
  refuse 1 "describe=unreadable" "vgsh version --json printed: $version_json"
version="${BASH_REMATCH[1]}" tag_version="${BASH_REMATCH[2]}" count="${BASH_REMATCH[3]}" hash="${BASH_REMATCH[4]}"
[[ $version =~ $version_re ]] || refuse 1 "version=malformed value=$version"

work="$(mktemp -d "${TMPDIR:-/tmp}/vgs-srpm.XXXXXX")" || refuse 1 "work=temp TMPDIR=${TMPDIR:-/tmp}"
[[ -d $work && ! -L $work ]] || refuse 1 "work=not-a-directory value=[$work]"
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT
# Source0 alone, apart from the spec copy and the build log.
sources="$work/sources"
mkdir -p -- "$sources" "$outdir"
outdir="$(cd -- "$outdir" && pwd -P)"

# One field of a spec, macros expanded, read by rpm itself.
spec_field() { # SPEC TAG
  local out
  out="$(rpmspec -q --srpm --qf "%{$2}\n" "$1")" || refuse 1 "rpmspec=failed spec=$1 tag=$2"
  printf '%s\n' "$out"
}
spec_source0() { # SPEC
  local parsed line
  parsed="$(rpmspec -P "$1")" || refuse 1 "rpmspec=failed spec=$1"
  while IFS= read -r line; do
    if [[ $line =~ ^Source0:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<<"$parsed"
  refuse 1 "source0=missing spec=$1"
}

case "$package" in
  vgs)
    spec_version="$(spec_field "$spec" VERSION)"
    [[ $spec_version == "$version" ]] ||
      refuse 1 "spec-version=$spec_version version=$version" "set Version in packaging/fedora/vgs.spec to VERSION's line"
    [[ $count == 0 && $tag_version == "$version" ]] ||
      refuse 1 "checkout=not-at-tag want=v$version describe=$tag_version.r$count.g$hash" "build the release package from a checkout at its release tag"
    source_url="$(spec_source0 "$spec")"
    source_file="$sources/${source_url##*/}"
    [[ ${source_url##*/} == "vgs-$version.tar.gz" ]] || refuse 1 "source0=unexpected url=$source_url"
    if [[ -n $tarball ]]; then
      [[ -f $tarball ]] || refuse 1 "tarball=missing path=$tarball"
      cp -- "$tarball" "$source_file"
    else
      [[ $source_url == https://* ]] || refuse 1 "source0=not-https url=$source_url"
      command -v curl >/dev/null || refuse 1 "tool=missing name=curl"
      curl --proto '=https' --tlsv1.2 -fsSL -o "$source_file" -- "$source_url" ||
        refuse 1 "download=failed url=$source_url"
    fi
    # The tarball must be this release: vgs-<VERSION>/VERSION holds it.
    packed="$(tar -xzOf "$source_file" "vgs-$version/VERSION" 2>/dev/null)" ||
      refuse 1 "tarball=unreadable want=vgs-$version/VERSION"
    [[ $packed == "$version" ]] || refuse 1 "tarball-version=$packed version=$version"
    build_spec="$work/vgs.spec"
    cp -- "$spec" "$build_spec"
    rpm_version="$version"
    ;;
  vgs-git)
    [[ $(git -C "$root" rev-parse --is-shallow-repository) == false ]] ||
      refuse 1 "clone=shallow path=$root" "the commit count needs the whole history: git fetch --unshallow"
    commit="$(git -C "$root" rev-parse --verify 'HEAD^{commit}')" || refuse 1 "git=rev-parse path=$root"
    [[ $commit == "$hash"* ]] || refuse 1 "describe=stale hash=$hash head=$commit"
    rpm_version="$tag_version^$count.git$hash"
    "$root/scripts/lib/release-tarball.sh" "$commit" "$commit" "$sources/vgs-$commit.tar.gz" >/dev/null ||
      refuse 1 "git=archive commit=$commit"
    build_spec="$work/vgs-git.spec"
    # The entry's date, the commit's in UTC, is the build's
    # SOURCE_DATE_EPOCH, so one commit always builds the same package.
    entry="$(TZ=UTC git -C "$root" log -1 --format='* %cd %an <%ae> - '"$rpm_version"'-1%n- Snapshot of commit %H' \
      --date=format-local:'%a %b %d %Y' "$commit")" || refuse 1 "git=log commit=$commit"
    {
      printf '%%global vgs_version %s\n' "$rpm_version"
      printf '%%global vgs_commit %s\n' "$commit"
      cat -- "$spec"
      printf '%s\n' "$entry"
    } >"$build_spec"
    spec_version="$(spec_field "$build_spec" VERSION)"
    [[ $spec_version == "$rpm_version" ]] || refuse 1 "spec-version=$spec_version want=$rpm_version"
    ;;
esac

log="$work/rpmbuild.log"
rpmbuild -bs --define "_sourcedir $sources" --define "_srcrpmdir $outdir" "$build_spec" >"$log" 2>&1 || {
  printf 'srpm: refused: rpmbuild=failed spec=%s\n' "$build_spec" >&2
  cat -- "$log" >&2
  exit 1
}
srpm=""
while IFS= read -r line; do
  [[ $line =~ ^Wrote:[[:space:]]+(.+\.src\.rpm)$ ]] && srpm="${BASH_REMATCH[1]}"
done <"$log"
[[ -n $srpm && -f $srpm ]] || refuse 1 "rpmbuild=no-srpm" "$(cat -- "$log")"
printf 'srpm: ok path=%s version=%s\n' "$srpm" "$rpm_version"
