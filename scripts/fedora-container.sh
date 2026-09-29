#!/usr/bin/env bash
# Build and install both Fedora packages in a clean Fedora container.
#
# Usage: scripts/fedora-container.sh [--image IMAGE]
#
# The pre-publication test of COPR vanillagreen/vgs, run by hand before the
# project is created and before a new Fedora release's chroots are added:
# docs/architecture/distribution.md § Fedora. IMAGE defaults to
# registry.fedoraproject.org/fedora:44. Needs podman and the network; the
# host's session, configuration and package manager are never touched.
#
# It clones HEAD into a scratch directory and, inside the container:
# enables the repositories packaging/fedora/copr-project names; writes the
# vgs-git source RPM through .copr/Makefile, as COPR does; tags the clone
# v<VERSION>, packs the release tarball as scripts/release does and writes
# the vgs source RPM from it; installs each source RPM's build dependencies
# and rebuilds it as an unprivileged user, failing on any RPM warning;
# installs vgs, then checks
# `vgsh --version`, the /usr/bin/vgsh link and the preflight; proves vgs-git
# refuses to install beside vgs, replaces it with --allowerasing, provides
# vgs at its own version, and passes the same checks; and proves vgs then
# refuses to install beside vgs-git.
#
# The preflight runs twice per package. `vgsh run` with no Hyprland must
# refuse at hyprland alone, so the installed Quickshell met its floor. Then
# a stand-in hyprctl that reports the installed hyprland package's version
# lets `vgsh restart` pass the whole floor and refuse at shell=not-running.
#
# Exit 0: every check passed. Exit 1: a check failed. Exit 2: bad usage or a
# dirty tree. Exit 77: podman, the image or the package repositories could
# not be reached; that is not a pass.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"

inside() {
  local version srpm srpm_git srpm_rel git_version rpms hypr_version out status line key value
  fail() { printf 'fedora-container: fail: %s\n' "$*" >&2; exit 1; }
  step() { printf 'fedora-container: %s\n' "$*"; }
  # Runs COMMAND with its output in /work/logs/NAME.log, printed only when
  # it fails; leaves the log's last line in $line.
  logged() { # NAME COMMAND...
    local name="$1"
    shift
    if ! "$@" >"/work/logs/$name.log" 2>&1; then
      tail -n 60 -- "/work/logs/$name.log" >&2
      fail "$name: $*"
    fi
    line="$(tail -n 1 -- "/work/logs/$name.log")"
  }
  # True when installing RPM failed because of the vgs conflict, not for
  # any other cause; prints dnf's conflict line.
  refused_as_conflict() { # NAME RPM
    ! dnf -y install "$2" >"/work/logs/$1.log" 2>&1 &&
      grep -m 1 -E 'conflicts with vgs provided by vgs(-git)?-[0-9]' "/work/logs/$1.log" | sed 's/^ */fedora-container: refused as wanted: /'
  }

  cd /work/src
  mkdir -p /work/logs /work/out
  version="$(cat VERSION)"
  dnf -y makecache >/work/logs/makecache.log 2>&1 ||
    { echo 'fedora-container: status=not-measured reason=repositories-unreachable' >&2; exit 77; }
  logged tools dnf -y install make dnf-plugins-core
  while read -r key value; do
    [[ $key == repo ]] || continue
    logged "copr-${value//\//-}" dnf -y copr enable "$value"
    step "enabled copr $value"
  done <packaging/fedora/copr-project

  logged srpm-vgs-git make -s -f .copr/Makefile srpm outdir=/work/out spec=packaging/fedora/vgs-git.spec
  [[ $line =~ ^srpm:\ ok\ path=([^ ]+)\ version=([^ ]+)$ ]] || fail "vgs-git srpm printed: $line"
  srpm_git="${BASH_REMATCH[1]}" git_version="${BASH_REMATCH[2]}"
  [[ $git_version =~ ^[0-9]+\.[0-9]+\.[0-9]+\^[0-9]+\.git[0-9a-f]+$ ]] || fail "vgs-git version $git_version"
  step "vgs-git source RPM $git_version"

  # The scratch clone's release tag, moved to HEAD, so the release package
  # is built from this tree whether or not v<VERSION> exists upstream.
  git tag -f "v$version" >/dev/null
  git archive --format=tar --prefix="vgs-$version/" "v$version" | gzip -n >"/work/vgs-$version.tar.gz"
  logged srpm-vgs packaging/fedora/srpm.sh --spec packaging/fedora/vgs.spec --outdir /work/out --tarball "/work/vgs-$version.tar.gz"
  [[ $line =~ ^srpm:\ ok\ path=([^ ]+)\ version=$version$ ]] || fail "vgs srpm printed: $line"
  srpm_rel="${BASH_REMATCH[1]}"
  step "vgs source RPM $version"

  useradd -m builder
  for srpm in "$srpm_rel" "$srpm_git"; do
    logged "builddep-${srpm##*/}" dnf -y builddep "$srpm"
    logged "rebuild-${srpm##*/}" runuser -u builder -- rpmbuild --rebuild --define '_topdir /home/builder/rpmbuild' "$srpm"
    ! grep -E '^(warning|error):' "/work/logs/rebuild-${srpm##*/}.log" ||
      fail "rpmbuild --rebuild ${srpm##*/} printed the warnings above"
  done
  rpms=/home/builder/rpmbuild/RPMS/noarch
  step "built $(cd "$rpms" && echo *.rpm)"

  hypr_version=""
  checks() { # WANT_PACKAGE
    local link err
    out="$(vgsh --version)" || fail "vgsh --version exited $?"
    [[ $out == "vgs $version" ]] || fail "vgsh --version printed [$out], want [vgs $version]"
    link="$(readlink /usr/bin/vgsh)"
    [[ $link == ../share/vgs/bin/vgsh ]] || fail "/usr/bin/vgsh links to [$link]"
    rpm -V "$1" || fail "rpm -V $1"
    [[ -n $hypr_version ]] || hypr_version="$(rpm -q --qf '%{VERSION}' hyprland)"
    mkdir -p /tmp/rt /tmp/standin
    chown builder /tmp/rt
    cat >/tmp/standin/hyprctl <<EOF
#!/bin/bash
[[ \$* == "-j version" ]] || exit 1
printf '{"version": "%s"}\n' "$hypr_version"
EOF
    chmod 755 /tmp/standin/hyprctl
    set +e
    err="$(runuser -u builder -- env XDG_RUNTIME_DIR=/tmp/rt vgsh run 2>&1 >/dev/null)"
    status=$?
    set -e
    [[ $status == 78 && ${err%%$'\n'*} == "vgsh: refused: preflight=hyprland have=unknown need=0.56" ]] ||
      fail "vgsh run with no Hyprland: exit=$status stderr=[$err]"
    set +e
    err="$(runuser -u builder -- env XDG_RUNTIME_DIR=/tmp/rt PATH="/tmp/standin:$PATH" vgsh restart 2>&1 >/dev/null)"
    status=$?
    set -e
    [[ $status == 69 && ${err%%$'\n'*} == "vgsh: refused: shell=not-running lock=/tmp/rt/vgsh.lock" ]] ||
      fail "vgsh restart past the preflight with hyprland $hypr_version: exit=$status stderr=[$err]"
    step "$1: vgsh --version, /usr/bin/vgsh and the preflight hold (hyprland $hypr_version)"
  }

  logged install-vgs dnf -y install "$rpms/vgs-$version-"*.noarch.rpm
  step "installed $(rpm -q vgs) with $(rpm -q quickshell hyprland | tr '\n' ' ')"
  checks vgs

  refused_as_conflict refuse-vgs-git "$(echo "$rpms"/vgs-git-*.noarch.rpm)" ||
    fail "vgs-git beside vgs was not refused as a conflict: $(tail -n 5 /work/logs/refuse-vgs-git.log)"
  logged install-vgs-git dnf -y install --allowerasing "$rpms"/vgs-git-*.noarch.rpm
  ! rpm -q vgs >/dev/null || fail "vgs is still installed beside vgs-git"
  out="$(rpm -q --qf '%{VERSION}' vgs-git)"
  [[ $out == "$git_version" ]] || fail "vgs-git version [$out], want [$git_version]"
  out="$(rpm -q --whatprovides --qf '%{NAME} %{VERSION}\n' vgs)"
  [[ $out == "vgs-git $git_version" ]] || fail "vgs provided by [$out]"
  checks vgs-git

  refused_as_conflict refuse-vgs "$(echo "$rpms/vgs-$version-"*.noarch.rpm)" ||
    fail "vgs beside vgs-git was not refused as a conflict: $(tail -n 5 /work/logs/refuse-vgs.log)"
  step "ok vgs=$version vgs-git=$git_version"
}

if [[ ${1:-} == --inside ]]; then
  inside
  exit 0
fi

image=registry.fedoraproject.org/fedora:44
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) sed -n '2,31{s/^# \{0,1\}//;p}' "$self"; exit 0 ;;
    --image)
      [[ $# -ge 2 && -n $2 ]] || { echo 'fedora-container: refused: argument=--image value=missing' >&2; exit 2; }
      image="$2"; shift 2 ;;
    *) printf 'fedora-container: refused: argument=%s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v podman >/dev/null || { echo 'fedora-container: status=not-measured missing=podman' >&2; exit 77; }
repo="$(git -C "$(dirname -- "$self")" rev-parse --show-toplevel)"
if [[ -n $(git -C "$repo" status --porcelain --untracked-files=normal) ]]; then
  echo 'fedora-container: refused: tree=dirty' >&2
  echo 'the test builds HEAD; commit or stash first' >&2
  exit 2
fi
head="$(git -C "$repo" rev-parse --verify HEAD)"

work="$(mktemp -d "${TMPDIR:-/tmp}/vgs-fedora.XXXXXX")" || { echo 'fedora-container: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $work && ! -L $work ]] || { echo "fedora-container: scratch=not-a-directory value=[$work]" >&2; exit 1; }
# A file the container left under a subordinate uid needs podman's namespace.
cleanup() { rm -rf -- "$work" 2>/dev/null || podman unshare rm -rf -- "$work"; }
trap cleanup EXIT
# The container's unprivileged builder reads the source RPMs under it.
chmod 755 "$work"
git clone -q --no-hardlinks -- "$repo" "$work/src"
git -C "$work/src" checkout -q --detach "$head"
cp -- "$self" "$work/run.sh"

set +e
podman run --rm --pull=missing -v "$work:/work:Z" "$image" bash /work/run.sh --inside
status=$?
set -e
case "$status" in
  0|1|77) exit "$status" ;;
  125) printf 'fedora-container: status=not-measured reason=podman image=%s\n' "$image" >&2; exit 77 ;;
  *) printf 'fedora-container: fail: container exited %s\n' "$status" >&2; exit 1 ;;
esac
