#!/usr/bin/env bash
# Controls for packaging/fedora/srpm.sh, the COPR entry .copr/Makefile and
# the host side of scripts/fedora-container.sh. The host has no RPM tools,
# so stub rpmspec, rpmbuild, curl, dnf and podman first on PATH answer and
# record their arguments; the real container run is
# scripts/fedora-container.sh itself. Each row runs in a scratch git
# repository holding the files these scripts read, and each refusal row
# pins its exit status and keyed first line. The control at the end runs a
# copy of srpm.sh that packs vgs-git another way.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
# srpm.sh names its spec by its resolved path.
repo="$(cd -- "$repo" && pwd -P)"

for tool in git gzip tar make python3; do
  command -v "$tool" >/dev/null || { echo "test-fedora-srpm: status=not-measured missing=$tool"; exit 77; }
done

# --- stubs -----------------------------------------------------------------
stubs="$tmp/stubs"
record="$tmp/record"
mkdir -p "$stubs" "$record" "$tmp/home"
cat >"$stubs/rpmspec" <<'EOF'
#!/usr/bin/env bash
# -q --srpm --qf FORMAT SPEC prints Version; -P SPEC prints the spec with
# %{url} and %{version} expanded. Version %{vgs_version} reads the global.
spec="${*: -1}"
ver="$(sed -n 's/^Version:[[:space:]]*//p' "$spec")"
[[ $ver == '%{vgs_version}' ]] && ver="$(sed -n 's/^%global vgs_version //p' "$spec")"
url="$(sed -n 's/^URL:[[:space:]]*//p' "$spec")"
case "$1" in
  -P) sed -e "s|%{url}|$url|g" -e "s|%{version}|$ver|g" "$spec" ;;
  -q) printf '%s\n' "$ver" ;;
  *) exit 64 ;;
esac
EOF
cat >"$stubs/rpmbuild" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_RECORD/rpmbuild.args"
env | grep -E '^GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+)=' | LC_ALL=C sort >"$STUB_RECORD/git-config.env" || true
[[ -z ${STUB_RPMBUILD_EXIT:-} ]] || { echo "error: stub rpmbuild failed"; exit "$STUB_RPMBUILD_EXIT"; }
src="" out=""
while [[ $# -gt 1 ]]; do
  case "$1" in
    --define) case "$2" in _sourcedir\ *) src="${2#* }" ;; _srcrpmdir\ *) out="${2#* }" ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
spec="$1"
cp -- "$spec" "$STUB_RECORD/built.spec"
ls -- "$src" >"$STUB_RECORD/sources"
cp -- "$src"/*.tar.gz "$STUB_RECORD/"
name="$(sed -n 's/^Name:[[:space:]]*//p' "$spec")"
ver="$(sed -n 's/^Version:[[:space:]]*//p' "$spec")"
[[ $ver == '%{vgs_version}' ]] && ver="$(sed -n 's/^%global vgs_version //p' "$spec")"
: >"$out/$name-$ver-1.src.rpm"
echo "Wrote: $out/$name-$ver-1.src.rpm"
EOF
cat >"$stubs/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_RECORD/curl.args"
[[ -n ${STUB_CURL_TARBALL:-} ]] || exit 22
while [[ $# -gt 0 ]]; do [[ $1 == -o ]] && { cp -- "$STUB_CURL_TARBALL" "$2"; exit 0; }; shift; done
exit 2
EOF
cat >"$stubs/dnf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_RECORD/dnf.args"
EOF
cat >"$stubs/podman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_RECORD/podman.args"
exit "${STUB_PODMAN_EXIT:-0}"
EOF
chmod +x "$stubs"/*

# Every child: the stubs first, git isolated from the developer's
# configuration, and fixed identities and dates so each row is repeatable.
export PATH="$stubs:$PATH" HOME="$tmp/home" TMPDIR="$tmp" STUB_RECORD="$record"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CEILING_DIRECTORIES="$tmp"
export GIT_AUTHOR_NAME="Ada Packager" GIT_AUTHOR_EMAIL="ada@example.org" GIT_COMMITTER_NAME="Ada Packager" GIT_COMMITTER_EMAIL="ada@example.org"
export GIT_AUTHOR_DATE="2026-09-27T23:30:00-05:00" GIT_COMMITTER_DATE="2026-09-27T23:30:00-05:00"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
# No inherited GIT_CONFIG_COUNT, KEY_<n> or VALUE_<n>: the rows set their own.
while read -r name; do unset "$name"; done < <(compgen -v GIT_CONFIG_ | grep -E '^GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+)$')

# A scratch repository with the files the scripts read and COMMITS commits.
fixture() { # DIR COMMITS
  local dir="$1" i
  mkdir -p "$dir/bin" "$dir/packaging/fedora" "$dir/.copr" "$dir/scripts/lib"
  cp -- "$repo/bin/vgsh" "$dir/bin/"
  cp -- "$repo/scripts/lib/release-tarball.sh" "$dir/scripts/lib/"
  cp -- "$repo/VERSION" "$dir/"
  cp -- "$repo/packaging/fedora/srpm.sh" "$repo/packaging/fedora/vgs.spec" "$repo/packaging/fedora/vgs-git.spec" "$dir/packaging/fedora/"
  cp -- "$repo/.copr/Makefile" "$dir/.copr/"
  cp -- "$repo/scripts/fedora-container.sh" "$dir/scripts/"
  git init -q -b main "$dir"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "commit 1"
  for ((i = 2; i <= $2; i++)); do git -C "$dir" commit -q --allow-empty -m "commit $i"; done
}
# The tarball scripts/release makes for VERSION at tag v<VERSION>, through
# the builder it calls.
release_tarball() { # DIR OUT
  local v
  v="$(<"$1/VERSION")"
  "$1/scripts/lib/release-tarball.sh" "v$v" "$v" "$2" >/dev/null
}

# run DIR CMD...: status in $status, stdout in $out, first stderr line in $err.
run() {
  local dir="$1"; shift
  rm -rf -- "${record:?}"/* "$tmp/out"
  set +e
  out="$(cd -- "$dir" && "$@" 2>"$tmp/err")"
  status=$?
  set -e
  err=""
  [[ -s $tmp/err ]] && IFS= read -r err <"$tmp/err"
  return 0
}
refused() { # NAME WANT_STATUS WANT_ERR
  if [[ $status == "$2" && $err == "$3" ]]; then ok "$1"; else fail "$1: exit=$status want=$2 stderr=[$err] want=[$3]"; fi
}
tar_files() { tar -tzf "$1" | grep -v '/$' | LC_ALL=C sort; }
# Whether the last run's Source0 holds DIR's HEAD files under vgs-<commit>/.
snapshot_files() { # DIR
  local h
  h="$(git -C "$1" rev-parse HEAD)" || return 1
  cmp -s <(tar_files "$record/vgs-$h.tar.gz") <(git -C "$1" ls-tree -r --name-only HEAD | sed "s|^|vgs-$h/|" | LC_ALL=C sort)
}

version="$(<"$repo/VERSION")"

# --- vgs-git ---------------------------------------------------------------
fx="$tmp/snapshot"
fixture "$fx" 3
head="$(git -C "$fx" rev-parse HEAD)"
short="$(git -C "$fx" rev-parse --short HEAD)"
run "$fx" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec --outdir "$tmp/out"
want="$version^3.git$short"
check "vgs-git with no release tag counts every commit" test "$status:$out" = "0:srpm: ok path=$tmp/out/vgs-git-$want-1.src.rpm version=$want"
describe="$(cd "$fx" && bin/vgsh --version)"
check "vgs-git's version is vgsh --version in RPM form" test "$describe" = "vgs $version.r3.g$short"
check "the build spec defines vgs_version first" test "$(sed -n 1p "$record/built.spec")" = "%global vgs_version $want"
check "the build spec defines vgs_commit second" test "$(sed -n 2p "$record/built.spec")" = "%global vgs_commit $head"
check "the build spec holds the template after the two definitions" cmp -s <(tail -n +3 "$record/built.spec" | head -n "$(wc -l <"$repo/packaging/fedora/vgs-git.spec")") "$repo/packaging/fedora/vgs-git.spec"
check "the changelog entry carries the commit's author and UTC date" test "$(tail -n 2 "$record/built.spec" | head -n 1)" = "* Mon Sep 28 2026 Ada Packager <ada@example.org> - $want-1"
check "the changelog entry names the commit" test "$(tail -n 1 "$record/built.spec")" = "- Snapshot of commit $head"
check "Source0 is the commit's tarball alone" test "$(cat "$record/sources")" = "vgs-$head.tar.gz"
check "the tarball is the commit's files under vgs-<commit>/" snapshot_files "$fx"
cp -- "$record/vgs-$head.tar.gz" "$tmp/first.tar.gz"
run "$fx" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec --outdir "$tmp/out"
check "one commit packs the same tarball bytes twice" cmp -s "$tmp/first.tar.gz" "$record/vgs-$head.tar.gz"
check "rpmbuild builds the source RPM alone" grep -qxF -- -bs "$record/rpmbuild.args"

git -C "$fx" tag "v$version" HEAD~1
run "$fx" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec --outdir "$tmp/out"
check "vgs-git counts from the newest release tag" test "$status:${out##* }" = "0:version=$version^1.git$short"

run "$tmp" git clone -q --depth 1 "file://$fx" "$tmp/shallow"
run "$tmp/shallow" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec --outdir "$tmp/out"
refused "a shallow clone is refused" 1 "srpm: refused: clone=shallow path=$tmp/shallow"

run "$fx" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec --outdir "$tmp/out" --tarball "$tmp/first.tar.gz"
refused "--tarball with vgs-git is a usage error" 2 "srpm: refused: argument=--tarball package=vgs-git"

# --- COPR's entry point ----------------------------------------------------
run "$fx" make -s -f .copr/Makefile srpm outdir="$tmp/out" spec=packaging/fedora/vgs-git.spec
check "make srpm writes the vgs-git source RPM" test "$status:${out##*$'\n'}" = "0:srpm: ok path=$tmp/out/vgs-git-$version^1.git$short-1.src.rpm version=$version^1.git$short"
check "make srpm installs the builder's tools first" test "$(cat "$record/dnf.args")" = "-y install bash curl git-core gzip rpm-build tar"
run "$tmp" make -s -f "$fx/.copr/Makefile" srpm outdir="$tmp/out" spec="$fx/packaging/fedora/vgs-git.spec"
check "make srpm finds srpm.sh from any directory" test "$status" = 0

# --- vgs -------------------------------------------------------------------
rel="$tmp/release"
fixture "$rel" 2
git -C "$rel" tag "v$version"
release_tarball "$rel" "$tmp/vgs-$version.tar.gz"
run "$rel" packaging/fedora/srpm.sh --spec packaging/fedora/vgs.spec --outdir "$tmp/out" --tarball "$tmp/vgs-$version.tar.gz"
check "vgs at its tag writes the release source RPM" test "$status:$out" = "0:srpm: ok path=$tmp/out/vgs-$version-1.src.rpm version=$version"
check "the release build spec is vgs.spec unchanged" cmp -s "$record/built.spec" "$repo/packaging/fedora/vgs.spec"
check "the release Source0 is the tarball under its release name" cmp -s "$record/vgs-$version.tar.gz" "$tmp/vgs-$version.tar.gz"

run "$rel" packaging/fedora/srpm.sh --spec packaging/fedora/vgs.spec --outdir "$tmp/out"
refused "a failed download is refused" 1 "srpm: refused: download=failed url=https://github.com/vanillagreencom/vgs/releases/download/v$version/vgs-$version.tar.gz"
check "the download is HTTPS only" grep -qxF -- "--proto" "$record/curl.args"
check "the download names the release asset" test "$(tail -n 1 "$record/curl.args")" = "https://github.com/vanillagreencom/vgs/releases/download/v$version/vgs-$version.tar.gz"
STUB_CURL_TARBALL="$tmp/vgs-$version.tar.gz" run "$rel" packaging/fedora/srpm.sh --spec packaging/fedora/vgs.spec --outdir "$tmp/out"
check "a downloaded release tarball builds" test "$status:$out" = "0:srpm: ok path=$tmp/out/vgs-$version-1.src.rpm version=$version"

run "$rel" packaging/fedora/srpm.sh --spec packaging/fedora/vgs.spec --outdir "$tmp/out" --tarball "$tmp/missing.tar.gz"
refused "a missing tarball is refused" 1 "srpm: refused: tarball=missing path=$tmp/missing.tar.gz"

mkdir -p "$tmp/wrong/vgs-$version"
printf '9.9.9\n' >"$tmp/wrong/vgs-$version/VERSION"
tar -C "$tmp/wrong" -czf "$tmp/wrong.tar.gz" "vgs-$version"
run "$rel" packaging/fedora/srpm.sh --spec packaging/fedora/vgs.spec --outdir "$tmp/out" --tarball "$tmp/wrong.tar.gz"
refused "a tarball of another version is refused" 1 "srpm: refused: tarball-version=9.9.9 version=$version"
tar -C "$tmp/wrong" -czf "$tmp/unprefixed.tar.gz" .
run "$rel" packaging/fedora/srpm.sh --spec packaging/fedora/vgs.spec --outdir "$tmp/out" --tarball "$tmp/unprefixed.tar.gz"
refused "a tarball without vgs-<VERSION>/ is refused" 1 "srpm: refused: tarball=unreadable want=vgs-$version/VERSION"

git -C "$rel" commit -q --allow-empty -m "after the tag"
run "$rel" packaging/fedora/srpm.sh --spec packaging/fedora/vgs.spec --outdir "$tmp/out" --tarball "$tmp/vgs-$version.tar.gz"
refused "vgs past its tag is refused" 1 "srpm: refused: checkout=not-at-tag want=v$version describe=$version.r1.g$(git -C "$rel" rev-parse --short HEAD)"

run "$fx" packaging/fedora/srpm.sh --spec packaging/fedora/vgs.spec --outdir "$tmp/out" --tarball "$tmp/vgs-$version.tar.gz"
refused "vgs with the tag behind it is refused" 1 "srpm: refused: checkout=not-at-tag want=v$version describe=$version.r1.g$short"

bumped="$tmp/bumped"
fixture "$bumped" 1
printf '9.9.9\n' >"$bumped/VERSION"
git -C "$bumped" commit -q -am "bump"
git -C "$bumped" tag v9.9.9
run "$bumped" packaging/fedora/srpm.sh --spec packaging/fedora/vgs.spec --outdir "$tmp/out" --tarball "$tmp/vgs-$version.tar.gz"
refused "a spec Version off VERSION is refused" 1 "srpm: refused: spec-version=$version version=9.9.9"

# --- arguments, the checkout and the tools ---------------------------------
run "$fx" packaging/fedora/srpm.sh --spec "$repo/packaging/fedora/vgs.spec" --outdir "$tmp/out"
refused "a spec from another checkout is refused" 1 "srpm: refused: spec=unknown path=$repo/packaging/fedora/vgs.spec"
run "$fx" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec
refused "a missing --outdir is a usage error" 2 "srpm: refused: argument=--outdir value=missing"
run "$fx" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec --outdir "$tmp/out" --extra
refused "an unknown argument is a usage error" 2 "srpm: refused: argument=--extra"

exported="$tmp/exported"
mkdir -p "$exported"
git -C "$fx" archive HEAD | tar -C "$exported" -x
run "$exported" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec --outdir "$tmp/out"
refused "an exported tree is refused" 1 "srpm: refused: checkout=missing path=$exported"

mkdir -p "$tmp/no-rpmbuild"
for tool in bash git gzip rpmspec readlink dirname sed cat; do ln -sf -- "$(PATH="$stubs:$PATH" command -v "$tool")" "$tmp/no-rpmbuild/$tool"; done
run "$fx" env PATH="$tmp/no-rpmbuild" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec --outdir "$tmp/out"
refused "a missing rpmbuild is refused" 1 "srpm: refused: tool=missing name=rpmbuild"

STUB_RPMBUILD_EXIT=1 run "$fx" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec --outdir "$tmp/out"
check "a failed rpmbuild is refused" test "$status:${err%% spec=*}" = "1:srpm: refused: rpmbuild=failed"
check "the failed rpmbuild's log follows the refusal" grep -qxF "error: stub rpmbuild failed" "$tmp/err"

# COPR's chroot clones as another user; srpm.sh trusts its own checkout
# through the environment and keeps the caller's entries.
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=Caller run "$fx" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec --outdir "$tmp/out"
check "srpm.sh trusts its checkout after the caller's git entries" test "$status:$(tr '\n' ' ' <"$record/git-config.env")" = "0:GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_KEY_1=safe.directory GIT_CONFIG_VALUE_0=Caller GIT_CONFIG_VALUE_1=$fx "
run "$fx" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec --outdir "$tmp/out"
check "srpm.sh trusts its checkout with no caller entries" test "$(tr '\n' ' ' <"$record/git-config.env")" = "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=$fx "

# --- scripts/fedora-container.sh on the host --------------------------------
cf="$tmp/container"
fixture "$cf" 1
run "$cf" scripts/fedora-container.sh --image
refused "the container runner refuses --image with no value" 2 "fedora-container: refused: argument=--image value=missing"
run "$cf" scripts/fedora-container.sh --bogus
refused "the container runner refuses an unknown argument" 2 "fedora-container: refused: argument=--bogus"
mkdir -p "$tmp/no-podman"
for tool in bash git readlink dirname sed; do ln -sf -- "$(command -v "$tool")" "$tmp/no-podman/$tool"; done
run "$cf" env PATH="$tmp/no-podman" scripts/fedora-container.sh
refused "the container runner without podman is not measured" 77 "fedora-container: status=not-measured missing=podman"
: >"$cf/untracked"
run "$cf" scripts/fedora-container.sh
refused "the container runner refuses a dirty tree" 2 "fedora-container: refused: tree=dirty"
rm -f -- "$cf/untracked"
run "$cf" scripts/fedora-container.sh --image example.org/fedora:45
check "the container runner starts one container on the named image" test "$status:$(tr '\n' ' ' <"$record/podman.args")" = "0:run --rm --pull=missing -v $(sed -n 5p "$record/podman.args" | cut -d: -f1):/work:Z example.org/fedora:45 bash /work/run.sh --inside "
STUB_PODMAN_EXIT=125 run "$cf" scripts/fedora-container.sh
refused "a podman error is not measured" 77 "fedora-container: status=not-measured reason=podman image=registry.fedoraproject.org/fedora:44"
STUB_PODMAN_EXIT=1 run "$cf" scripts/fedora-container.sh
check "a failed check inside the container fails the run" test "$status" = 1
check "the container runner removes its scratch clone" test -z "$(find "$tmp" -maxdepth 1 -name 'vgs-fedora.*')"

# --- control ---------------------------------------------------------------
# A copy of srpm.sh that packs vgs-git under the release's directory, not
# the commit's: the tarball row must fail on it.
copy_with snapshot-directory "$repo/packaging/fedora/srpm.sh" '"$commit" "$commit" "$sources/vgs-$commit.tar.gz"' '"$commit" "$version" "$sources/vgs-$commit.tar.gz"'
ctl="$tmp/control-snapshot"
fixture "$ctl" 1
cp -- "$copy" "$ctl/packaging/fedora/srpm.sh"
run "$ctl" packaging/fedora/srpm.sh --spec packaging/fedora/vgs-git.spec --outdir "$tmp/out"
if [[ $status == 0 ]] && ! snapshot_files "$ctl"; then
  ok "control: the tarball row fails on a srpm.sh that packs vgs-git under vgs-<VERSION>/"
else
  fail "control: snapshot-directory: exit=$status, or the tarball row passed on the copy"
fi

if ((failures > 0)); then
  echo "test-fedora-srpm: failures=$failures"
  exit 1
fi
echo "test-fedora-srpm: ok"
