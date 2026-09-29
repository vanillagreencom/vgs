#!/usr/bin/env bash
# Build and install both Arch recipes in a throwaway archlinux:latest
# container, and run the installed vgsh.
#
# Usage: scripts/arch-packages.sh
#
# Nothing runs against the host's pacman, /etc or the live session. The
# script writes under this repository's tmp/ only: the scratch inputs in
# tmp/arch-packages.<pid>/, removed on exit, and the container's pacman
# package cache in tmp/arch-packages-cache/, kept so a rerun downloads no
# package it already has. podman keeps the image in its own store.
#
# What is built is the working tree as `git add -A` would commit it: HEAD
# when the tree is clean, else a commit object over HEAD that no ref names.
# From that commit the host makes the release tarball with
# scripts/lib/release-tarball.sh, the builder scripts/release calls, and a
# bare repository holding it and every tag. Copies of the recipes take the
# tarball's sha256 (vgs) and `git+file://` of that commit (vgs-git); each
# substitution must match exactly once. A stand-in `vgs-shell` package that
# owns /usr/bin/vshell, v1's command, proves the conflicts replace v1.
#
# In the rootless podman container, as root: update the system, install
# base-devel, git and the depends the vgs recipe's .SRCINFO lists, then
# build the stand-in, vgs and vgs-git with makepkg as an unprivileged user
# and no network. Install the stand-in, then vgs with `pacman -U --ask 4`,
# which answers yes to the conflict question: vgs-shell and /usr/bin/vshell
# must be gone, `vgsh --version` must print `vgs <VERSION>` and
# /usr/bin/vgsh must link to ../share/vgs/bin/vgsh. Then vgs-git the same
# way: vgs must be gone, the pkgver must be X.Y.Z.r<N>.g<hash> with the
# hash a prefix of the built commit, vgs-git must provide vgs=<pkgver>,
# and vgsh --version must print `vgs <VERSION>` again.
#
# Exit 0 prints `arch-packages: ok commit=<sha> vgs=<version> vgs-git=<pkgver>`.
# Exit 1 prints `arch-packages: refused: <key>=<value> ...` first: a
# recipe, build, install or assertion failure. Exit 77 prints
# `arch-packages: status=not-measured reason=<key>`: podman-missing,
# image-pull, container-start or container-setup (the system update or the
# depends download failed); that is not a pass. Exit 2: an argument.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd -P)"
image='docker.io/library/archlinux:latest'

refuse() { # STATUS KEY [DETAIL...]
  local status="$1"
  printf 'arch-packages: refused: %s\n' "$2"
  shift 2
  [[ $# -eq 0 ]] || printf '%s\n' "$@"
  exit "$status"
}
not_measured() { # REASON [DETAIL...]
  printf 'arch-packages: status=not-measured reason=%s\n' "$1"
  shift
  [[ $# -eq 0 ]] || printf '%s\n' "$@"
  exit 77
}

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,38{s/^# \{0,1\}//;p}' "$self"; exit 0 ;;
  *) refuse 2 "argument=$1" ;;
esac
[[ $# -le 1 ]] || refuse 2 "argument=$2"

command -v podman >/dev/null 2>&1 || not_measured podman-missing "install podman to build the packages in a container"

version="$(<"$repo/VERSION")"
scratch="$repo/tmp/arch-packages.$$"
cache="$repo/tmp/arch-packages-cache"
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT
rm -rf -- "$scratch"
mkdir -p -- "$scratch/in/vgs" "$scratch/in/vgs-git" "$scratch/in/vgs-shell" "$cache"

# The commit to build.
git_env=(env GIT_AUTHOR_NAME=arch-packages GIT_AUTHOR_EMAIL=arch-packages@example.invalid
  GIT_COMMITTER_NAME=arch-packages GIT_COMMITTER_EMAIL=arch-packages@example.invalid)
status_out="$(git -C "$repo" status --porcelain --untracked-files=normal)" || refuse 1 "git=status path=$repo"
if [[ -z $status_out ]]; then
  commit="$(git -C "$repo" rev-parse --verify HEAD)" || refuse 1 "git=rev-parse path=$repo"
else
  index="$scratch/index"
  GIT_INDEX_FILE="$index" git -C "$repo" read-tree HEAD || refuse 1 "git=read-tree path=$repo"
  GIT_INDEX_FILE="$index" git -C "$repo" add -A || refuse 1 "git=add path=$repo"
  tree="$(GIT_INDEX_FILE="$index" git -C "$repo" write-tree)" || refuse 1 "git=write-tree path=$repo"
  commit="$("${git_env[@]}" git -C "$repo" commit-tree "$tree" -p HEAD -m 'arch-packages: working tree')" ||
    refuse 1 "git=commit-tree path=$repo"
fi
echo "arch-packages: commit=$commit dirty=$([[ -n $status_out ]] && echo true || echo false)"

sum="$("$repo/scripts/lib/release-tarball.sh" "$commit" "$version" "$scratch/in/vgs/vgs-$version.tar.gz")" ||
  refuse 1 "archive=failed commit=$commit"

git init -q --bare "$scratch/in/srcrepo.git" || refuse 1 "git=init path=$scratch/in/srcrepo.git"
git -C "$repo" push -q "$scratch/in/srcrepo.git" "$commit:refs/heads/main" 'refs/tags/*:refs/tags/*' ||
  refuse 1 "git=push path=$scratch/in/srcrepo.git"

# Copy a recipe, replacing the one match of PATTERN with REPLACEMENT.
recipe_copy() { # RECIPE PATTERN REPLACEMENT
  cp -- "$repo/packaging/arch/$1/PKGBUILD" "$scratch/in/$1/PKGBUILD"
  cp -- "$repo/packaging/arch/$1/.SRCINFO" "$scratch/in/$1/.SRCINFO"
  python3 - "$scratch/in/$1/PKGBUILD" "$2" "$3" <<'PY' || refuse 1 "recipe=unedited recipe=$1"
import pathlib, re, sys
path, pattern, replacement = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
matches = len(re.findall(pattern, text, flags=re.M))
if matches != 1:
    raise SystemExit(f"pattern {pattern!r} matched {matches} times, want 1")
changed = re.sub(pattern, lambda m: replacement, text, flags=re.M)
if changed == text:
    raise SystemExit("the substitution changed nothing")
path.write_text(changed)
PY
}
recipe_copy vgs "^sha256sums=\('[^']*'\)$" "sha256sums=('$sum')"
recipe_copy vgs-git '^source=\("vgs::git\+\$url\.git"\)$' "source=(\"vgs::git+file:///build/srcrepo.git#commit=$commit\")"

cat >"$scratch/in/vgs-shell/PKGBUILD" <<'PKGBUILD'
# A stand-in for v1's vgs-shell package: its conflicts must remove it.
pkgname=vgs-shell
pkgver=0.5.0
pkgrel=1
pkgdesc='Stand-in for the v1 vgs-shell package'
arch=('any')
license=('MIT')

package() {
  install -Dm755 /dev/null "$pkgdir/usr/bin/vshell"
  install -Dm644 /dev/null "$pkgdir/usr/lib/vshell/stand-in"
}
PKGBUILD

cat >"$scratch/in/run.sh" <<'RUN'
#!/usr/bin/env bash
# Runs as root in the container. Arguments: VERSION COMMIT.
set -euo pipefail
version="$1" commit="$2"
refuse() { printf 'arch-packages: refused: %s\n' "$1"; shift; [[ $# -eq 0 ]] || printf '%s\n' "$@"; exit 1; }
not_measured() { printf 'arch-packages: status=not-measured reason=%s\n' "$1"; shift; [[ $# -eq 0 ]] || printf '%s\n' "$@"; exit 77; }

# The cache is the host's tmp/arch-packages-cache. Downloads run as root,
# which is the host user, so no file there is owned by a uid the host
# cannot remove; a download directory left behind is removed on exit.
sed -i 's/^DownloadUser/#DownloadUser/' /etc/pacman.conf || refuse "pacman-conf=unedited"
if grep -q '^DownloadUser' /etc/pacman.conf; then refuse "pacman-conf=download-user"; fi
trap 'rm -rf /var/cache/pacman/pkg/download-*' EXIT

mapfile -t depends < <(sed -n 's/^\tdepends = //p' /in/vgs/.SRCINFO)
[[ ${#depends[@]} -gt 0 ]] || refuse "depends=empty path=/in/vgs/.SRCINFO"
pacman -Syu --noconfirm --needed base-devel git >/tmp/setup.log 2>&1 ||
  not_measured container-setup "$(tail -n 20 /tmp/setup.log)"
# Resolving against the synced databases downloads nothing: a failure here
# is a depends entry no repository satisfies.
pacman -Sp --print-format %n "${depends[@]}" >/tmp/resolve.log 2>&1 ||
  refuse "depends=unresolvable" "$(cat /tmp/resolve.log)"
pacman -S --noconfirm --needed --asdeps "${depends[@]}" >/tmp/depends.log 2>&1 ||
  not_measured container-setup "$(tail -n 20 /tmp/depends.log)"

useradd -m builder
cp -a /in/. /build/
chown -R builder:builder /build

# The one package file makepkg built for RECIPE.
package_file() { # RECIPE
  local files=()
  shopt -s nullglob
  files=(/build/"$1"/*.pkg.tar.*)
  shopt -u nullglob
  [[ ${#files[@]} -eq 1 ]] || refuse "package=count recipe=$1 count=${#files[@]}"
  printf '%s' "${files[0]}"
}
for recipe in vgs-shell vgs vgs-git; do
  runuser -u builder -- bash -c 'cd "/build/$1" && makepkg --noconfirm' _ "$recipe" >"/tmp/build-$recipe.log" 2>&1 ||
    refuse "build=failed recipe=$recipe" "$(tail -n 40 "/tmp/build-$recipe.log")"
done
shell_pkg="$(package_file vgs-shell)"; vgs_pkg="$(package_file vgs)"; git_pkg="$(package_file vgs-git)"

# Whether a package named NAME, not one providing NAME, is installed.
installed() { # NAME
  local names
  names="$(pacman -Qq)" || refuse "pacman=query-failed"
  grep -qxF -e "$1" <<<"$names"
}
install_pkg() { # FILE NAME
  pacman -U --noconfirm --ask 4 "$1" >"/tmp/install-$2.log" 2>&1 ||
    refuse "install=failed package=$2" "$(tail -n 40 "/tmp/install-$2.log")"
  installed "$2" || refuse "install=absent package=$2"
}
vgsh_version() { # PACKAGE
  local out
  out="$(runuser -u builder -- vgsh --version 2>&1)" || refuse "vgsh=failed package=$1" "$out"
  [[ $out == "vgs $version" ]] || refuse "vgsh-version=${out// /_} want=vgs_$version package=$1"
}

install_pkg "$shell_pkg" vgs-shell
[[ -e /usr/bin/vshell ]] || refuse "stand-in=absent path=/usr/bin/vshell"

install_pkg "$vgs_pkg" vgs
! installed vgs-shell || refuse "conflict=kept package=vgs-shell by=vgs"
[[ ! -e /usr/bin/vshell ]] || refuse "conflict=kept path=/usr/bin/vshell by=vgs"
vgsh_version vgs
link="$(readlink /usr/bin/vgsh)" || refuse "link=missing path=/usr/bin/vgsh"
[[ $link == ../share/vgs/bin/vgsh ]] || refuse "link=$link path=/usr/bin/vgsh"
vgs_ver="$(pacman -Q vgs)"; vgs_ver="${vgs_ver#vgs }"

install_pkg "$git_pkg" vgs-git
! installed vgs || refuse "conflict=kept package=vgs by=vgs-git" "$(pacman -Q)"
full="$(pacman -Q vgs-git)"; full="${full#vgs-git }"; pkgver="${full%-*}"
[[ $pkgver =~ ^[0-9]+\.[0-9]+\.[0-9]+\.r[0-9]+\.g([0-9a-f]{7,})$ && $commit == "${BASH_REMATCH[1]}"* ]] ||
  refuse "pkgver=$pkgver commit=$commit package=vgs-git"
provides="$(LC_ALL=C pacman -Qi vgs-git | sed -n 's/^Provides *: //p')"
[[ " $provides " == *" vgs=$pkgver "* ]] || refuse "provides=${provides// /,} want=vgs=$pkgver package=vgs-git"
vgsh_version vgs-git

echo "arch-packages: ok commit=$commit vgs=$vgs_ver vgs-git=$full"
RUN
chmod 755 "$scratch/in/run.sh"

if ! podman image exists "$image"; then
  pull_out="$(podman pull -q "$image" 2>&1)" || not_measured image-pull "$pull_out"
fi

status=0
podman run --rm \
  -v "$scratch/in:/in:ro" \
  -v "$cache:/var/cache/pacman/pkg" \
  "$image" /in/run.sh "$version" "$commit" || status=$?
case "$status" in
  0|1|77) exit "$status" ;;
  125) not_measured container-start "podman run exited 125" ;;
  *) refuse 1 "container=failed status=$status" ;;
esac
