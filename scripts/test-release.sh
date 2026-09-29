#!/usr/bin/env bash
# Controls for scripts/release. Each row runs a copy of the script as
# scripts/release of a scratch git repository at version 1.2.3, tagged
# v1.2.3 at HEAD, under env -i with a fixture HOME whose url.insteadOf
# turns the GitHub URL into a local bare repository, the tag's GitHub
# stand-in. Stub gpg and gh first on PATH record their arguments: the stub
# gpg holds the secret keys STUB_GPG_SECRET names and writes a signature
# naming the sha256 of the file it signed; the stub gh records its working
# directory and the files there.
#
# The real-tree row runs the dry run on this repository's working tree, as
# `git add -A` would commit it, with a fixture fingerprint in its
# install.sh, and installs the archive it built with the archive's own
# installer and install-tree check.
#
# No production edit of `gzip -n` alone reddens the archive row: gzip reads
# a pipe, so it writes no name and a zero time either way. The row pins
# that header, and the header's XFL byte, which only `gzip -9` sets to 02.
#
# The parity rows run a channel build's host side in the release fixture,
# with a stub podman that keeps the directory the container would mount.
# The tarball the channel hands its container must be the release asset of
# the same commit, byte for byte. The fixture keeps the builder,
# scripts/lib/release-tarball.sh, out of its commit, so a row can hand the
# channel a builder copy without changing the files the tarball holds.
#
# The controls at the end run copies of the script, or of the builder, with
# one rule removed each, and the row that judges that rule must turn red on
# its copy.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

suite=test-release
for tool in git gzip tar sha256sum python3; do
  command -v "$tool" >/dev/null || { echo "$suite: status=not-measured missing=$tool"; exit 77; }
done

script="$repo/scripts/release"
builder="$repo/scripts/lib/release-tarball.sh"
fpr=0123456789ABCDEF0123456789ABCDEF01234567
github=https://github.com/vanillagreencom/vgs.git
record="$tmp/record"; stubs="$tmp/release-stubs"; scratch="$tmp/scratch"; gnupg="$tmp/gnupg-empty"
mkdir -p "$record" "$stubs" "$scratch"
mkdir -m 700 "$gnupg"

cat >"$stubs/gpg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_RECORD/gpg"
signed="${*: -1}"
case " $* " in
  *" --list-secret-keys "*)
    [[ -n ${STUB_GPG_SECRET:-} && $signed == "$STUB_GPG_SECRET" ]] ;;
  *" --detach-sign "*)
    [[ -z ${STUB_GPG_FAIL:-} ]] || exit 2
    out=""
    while [[ $# -gt 0 ]]; do [[ $1 == --output ]] && out="$2"; shift; done
    sum="$(sha256sum -- "$signed")" || exit 2
    printf 'stub signature of %s\n' "${sum%% *}" >"$out" ;;
  *) exit 64 ;;
esac
EOF
cat >"$stubs/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_RECORD/gh"
printf '%s\n' "$(pwd -P)" >"$STUB_RECORD/gh.cwd"
ls -A >"$STUB_RECORD/gh.ls"
exit "${STUB_GH_EXIT:-0}"
EOF
cat >"$stubs/podman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_RECORD/podman"
[[ $1 == run ]] || exit 0
while [[ $# -gt 0 ]]; do
  [[ $1 == -v ]] && { cp -R -- "${2%%:*}" "$STUB_RECORD/mount"; exit 0; }
  shift
done
exit 64
EOF
chmod +x "$stubs/gpg" "$stubs/gh" "$stubs/podman"

# fixture NAME SCRIPT: sets r to a new scratch repository holding SCRIPT as
# scripts/release, the builder as an ignored scripts/lib/release-tarball.sh
# and an install.sh whose release_key is $fpr, tagged
# v1.2.3 at HEAD and pushed with main to its GitHub stand-in $r.git, and h
# to a home whose git configuration reaches that stand-in. Every call makes
# new directories, so a control's copy never meets a row's repository. A
# fixture that cannot be built stops the suite.
fixtures=0
fixture() {
  fixtures=$((fixtures + 1))
  r="$tmp/rows/$fixtures-$1"
  h="$tmp/homes/$fixtures-$1"
  {
    mkdir -p "$r/scripts/lib" "$r/docs" "$h" &&
      cp -- "$2" "$r/scripts/release" && cp -- "$builder" "$r/scripts/lib/release-tarball.sh" &&
      printf '1.2.3\n' >"$r/VERSION" &&
      printf '#!/usr/bin/env bash\n{\nmain() {\n  release_key="%s"\n}\nmain "$@"\n}\n' "$fpr" >"$r/install.sh" &&
      printf 'fixture\n' >"$r/docs/README.md" &&
      printf 'dist/\ntmp/\nscripts/lib/\n' >"$r/.gitignore" &&
      g init -q "$r" && g -C "$r" add -A && g -C "$r" commit -q -m release &&
      g -C "$r" tag -a v1.2.3 -m "VGS 1.2.3" &&
      g init -q --bare "$r.git" && g -C "$r" push -q "$r.git" main v1.2.3 &&
      g config --file "$h/.gitconfig" "url.file://$r.git.insteadOf" "$github"
  } || { echo "$suite: fixture=$1" >&2; exit 1; }
}
# retag MESSAGE: moves v1.2.3 to HEAD with MESSAGE and pushes it.
retag() { g -C "$r" tag -fa v1.2.3 -m "$1" >/dev/null && g -C "$r" push -qf "$r.git" v1.2.3 2>/dev/null; }
# key_line VALUE: commits install.sh with release_key="VALUE" and retags.
key_line() { sed -i "s/^  release_key=.*/  release_key=\"$1\"/" "$r/install.sh" && g -C "$r" commit -q -am key && retag key; }

# run_file FILE ARGS...: FILE from $h. Stdout lands in $tmp/out, stderr in
# $tmp/err, the exit status in $status; the stubs' records start empty.
# RUN_SECRET replaces the key the stub gpg holds. run ARGS... runs
# $r/scripts/release.
run_file() {
  rm -rf -- "${record:?}"/*
  status=0
  env -i PATH="$stubs:$base_path" HOME="$h" GIT_CONFIG_NOSYSTEM=1 GNUPGHOME="$gnupg" TMPDIR="$scratch" \
    STUB_RECORD="$record" STUB_GPG_SECRET="${RUN_SECRET-$fpr}" STUB_GPG_FAIL="${RUN_GPG_FAIL:-}" STUB_GH_EXIT="${RUN_GH_EXIT:-0}" \
    bash "$@" >"$tmp/out" 2>"$tmp/err" </dev/null || status=$?
}
run() { run_file "$r/scripts/release" "$@"; }
first_err() { local line=""; [[ -s $tmp/err ]] && IFS= read -r line <"$tmp/err"; printf '%s' "$line"; }
last_out() { local line=""; [[ -s $tmp/out ]] && line="$(tail -n 1 -- "$tmp/out")"; printf '%s' "$line"; }
recorded() { [[ -f $record/$1 ]] && grep -qxF -- "$2" "$record/$1"; }
sha_of() { local s; s="$(sha256sum -- "$1")" && printf '%s' "${s%% *}"; }
assets=(vgs-1.2.3.tar.gz install.sh SHA256SUMS SHA256SUMS.asc)

# The rows each judge one rule, on the script SCRIPT names, so a control
# can run them again on a copy with that rule removed.

archive_row() { # SCRIPT: the tarball is git archive of the tag under vgs-1.2.3/, gzip -9 with no name and no time
  local header want got
  fixture archive "$1"
  run 1.2.3
  [[ $status == 0 ]] || return 1
  want="$(g -C "$r" ls-tree -r --name-only v1.2.3 | sed 's|^|vgs-1.2.3/|' | LC_ALL=C sort)" || return 1
  got="$(tar -tzf "$r/dist/vgs-1.2.3.tar.gz" | grep -v '/$' | LC_ALL=C sort)" || return 1
  header="$(od -An -tx1 -N9 -- "$r/dist/vgs-1.2.3.tar.gz" | tr -d ' \n')" || return 1
  [[ $got == "$want" && $header == 1f8b08000000000002 ]] &&
    grep -qxF -- "release: sha256 name=vgs-1.2.3.tar.gz value=$(sha_of "$r/dist/vgs-1.2.3.tar.gz")" "$tmp/out"
}
sums_row() { # SCRIPT: SHA256SUMS lists the tarball and the tag's install.sh, one line each
  fixture sums "$1"
  run 1.2.3
  [[ $status == 0 ]] || return 1
  cmp -s -- "$r/dist/install.sh" <(g -C "$r" show v1.2.3:install.sh) &&
    [[ $(cat -- "$r/dist/SHA256SUMS") == "$(sha_of "$r/dist/vgs-1.2.3.tar.gz")  vgs-1.2.3.tar.gz
$(sha_of "$r/dist/install.sh")  install.sh" ]]
}
sign_row() { # SCRIPT: gpg signs the published SHA256SUMS with the release key
  fixture sign "$1"
  run 1.2.3
  [[ $status == 0 ]] &&
    grep -qE -- "^--local-user $fpr --armor --detach-sign --output $r/dist/\.release\.[A-Za-z0-9]+/SHA256SUMS\.asc -- $r/dist/\.release\.[A-Za-z0-9]+/SHA256SUMS\$" "$record/gpg" &&
    [[ $(cat -- "$r/dist/SHA256SUMS.asc") == "stub signature of $(sha_of "$r/dist/SHA256SUMS")" ]]
}
upload_row() { # SCRIPT: gh creates the release from the verified tag with the four assets alone
  fixture upload "$1"
  mkdir -p "$r/dist"
  printf 'other\n' >"$r/dist/notes.txt"
  run 1.2.3
  [[ $status == 0 && $(last_out) == "release: ok tag=v1.2.3 dry-run=false" ]] &&
    recorded gh "release create --repo vanillagreencom/vgs --verify-tag --title VGS 1.2.3 --generate-notes -- v1.2.3 ${assets[*]}" &&
    [[ $(wc -l <"$record/gh") == 1 && $(cat -- "$record/gh.cwd") == "$r/dist" ]] &&
    [[ $(cat -- "$record/gh.ls") == "$(printf '%s\n' "${assets[@]}" notes.txt | LC_ALL=C sort)" ]] &&
    [[ $(cat -- "$r/dist/notes.txt") == other ]]
}
dry_row() { # SCRIPT: --dry-run checks and builds, and neither signs nor uploads
  fixture dry "$1"
  run --dry-run 1.2.3
  [[ $status == 0 && $(last_out) == "release: ok tag=v1.2.3 dry-run=true" ]] &&
    [[ ! -e $record/gh && $(cat -- "$record/gpg") == "--batch --list-secret-keys -- $fpr" ]] &&
    [[ -f $r/dist/vgs-1.2.3.tar.gz && -f $r/dist/SHA256SUMS && -f $r/dist/install.sh && ! -e $r/dist/SHA256SUMS.asc ]] &&
    grep -qxF -- "release: would-sign key=$fpr name=SHA256SUMS" "$tmp/out"
}
stale_row() { # SCRIPT: an asset an earlier run left in dist/ is replaced or removed
  fixture stale "$1"
  mkdir -p "$r/dist"
  printf 'stale\n' >"$r/dist/SHA256SUMS.asc"
  printf 'stale\n' >"$r/dist/SHA256SUMS"
  run --dry-run 1.2.3
  [[ $status == 0 && ! -e $r/dist/SHA256SUMS.asc && $(cat -- "$r/dist/SHA256SUMS") != stale ]]
}
sign_failure_row() { # SCRIPT: a failed signature refuses before gh and publishes nothing into dist/
  fixture sign-failure "$1"
  RUN_GPG_FAIL=1 run 1.2.3
  [[ $status == 1 && $(first_err) == "release: refused: gpg=sign-failed key=$fpr" && ! -e $record/gh ]] &&
    [[ -z $(find "$r/dist" -mindepth 1 -print -quit) ]]
}
gh_failure_row() { # SCRIPT: a failed gh refuses
  fixture gh-failure "$1"
  RUN_GH_EXIT=1 run 1.2.3
  [[ $status == 1 && $(first_err) == "release: refused: gh=release-create tag=v1.2.3" ]]
}

# The channel builds whose host side packs the release tarball: the script
# | the tarball under the directory it mounts | the recipe there that pins
# the tarball's sum, or none | that recipe's pin line, %s for the sum.
declare -A channels=(
  [arch]="scripts/arch-packages.sh|vgs/vgs-1.2.3.tar.gz|vgs/PKGBUILD|sha256sums=('%s')"
  [fedora]="scripts/fedora-container.sh|vgs-1.2.3.tar.gz||"
)
# parity_row BUILDER CHANNEL [SCRIPT]: SCRIPT, default the channel's own,
# is committed as the channel's script.
parity_row() { # BUILDER CHANNEL [SCRIPT]: the tarball CHANNEL hands its container, packed by BUILDER, is the release asset of the same commit
  local command tarball recipe pin sum
  IFS='|' read -r command tarball recipe pin <<<"${channels[$2]}"
  fixture "parity-$2" "$script"
  { mkdir -p "$r/packaging" && cp -R -- "$repo/packaging/arch" "$r/packaging/" &&
    cp -- "$repo/scripts/arch-packages.sh" "$repo/scripts/fedora-container.sh" "$r/scripts/" &&
    cp -- "${3:-$repo/$command}" "$r/$command" && g -C "$r" add -A && g -C "$r" commit -q -m channels && retag channels; } || { echo "$suite: fixture=parity-$2" >&2; exit 1; }
  run --dry-run 1.2.3
  [[ $status == 0 ]] || return 1
  sum="$(sed -n 's/^release: sha256 name=vgs-1\.2\.3\.tar\.gz value=\([0-9a-f]\{64\}\)$/\1/p' "$tmp/out")" || return 1
  [[ -n $sum && $sum == "$(sha_of "$r/dist/vgs-1.2.3.tar.gz")" ]] || return 1
  cp -- "$1" "$r/scripts/lib/release-tarball.sh" && chmod 755 "$r/scripts/lib/release-tarball.sh" || return 1
  run_file "$r/$command"
  [[ $status == 0 && -f $record/mount/$tarball && $(sha_of "$record/mount/$tarball") == "$sum" ]] || return 1
  [[ -z $recipe ]] || grep -qxF -- "${pin//%s/$sum}" "$record/mount/$recipe"
}

# Refusals before anything is written: name | the fixture change | the
# arguments | exit status | the first stderr line, %r the repository and
# %h its HEAD. Each leaves no dist/ and calls no gh.
tweak_none() { :; }
tweak_dirty() { printf 'x\n' >"$r/untracked"; }
tweak_untagged() { g -C "$r" tag -d v1.2.3 >/dev/null; }
tweak_moved() { printf 'more\n' >>"$r/docs/README.md" && g -C "$r" commit -q -am more; }
tweak_unpushed() { g -C "$r.git" tag -d v1.2.3 >/dev/null; }
tweak_retagged() { g -C "$r" tag -fa v1.2.3 -m "VGS 1.2.3 again" >/dev/null; }
tweak_unset() { key_line ""; }
tweak_lower() { key_line 0123456789abcdef0123456789abcdef01234567; }
tweak_twice() { printf '  release_key=""\n' >>"$r/install.sh" && g -C "$r" commit -q -am twice && retag twice; }
declare -A refusals=(
  [no-argument]="tweak_none||2|release: refused: argument=missing"
  [not-a-version]="tweak_none|1.2|2|release: refused: version=1.2 reason=not-a-version"
  [version-mismatch]="tweak_none|1.2.4|1|release: refused: version=mismatch want=1.2.3 got=1.2.4"
  [dirty]="tweak_dirty|1.2.3|1|release: refused: tree=dirty path=%r"
  [tag-missing]="tweak_untagged|1.2.3|1|release: refused: tag=missing name=v1.2.3"
  [tag-not-head]="tweak_moved|1.2.3|1|release: refused: tag=not-head name=v1.2.3 commit=* head=%h"
  [key-unset]="tweak_unset|1.2.3|1|release: refused: release-key=unset path=install.sh"
  [key-malformed]="tweak_lower|1.2.3|1|release: refused: release-key=malformed value=0123456789abcdef0123456789abcdef01234567 path=install.sh"
  [key-twice]="tweak_twice|1.2.3|1|release: refused: release-key=unreadable path=install.sh count=2"
  [no-secret-key]="tweak_none|1.2.3|1|release: refused: release-key=no-secret-key key=$fpr"
  [tag-not-pushed]="tweak_unpushed|1.2.3|1|release: refused: tag=not-pushed name=v1.2.3 url=$github"
  [tag-differs]="tweak_retagged|1.2.3|1|release: refused: tag=differs name=v1.2.3 local=* remote=*"
)
refusal_row() { # SCRIPT NAME
  local entry tweak args want_status want_err err
  entry="${refusals[$2]}"
  IFS='|' read -r tweak args want_status want_err <<<"$entry"
  fixture "refuse-$2" "$1"
  "$tweak" || { echo "$suite: fixture=$tweak" >&2; exit 1; }
  want_err="${want_err//%r/$r}"
  want_err="${want_err//%h/$(g -C "$r" rev-parse HEAD)}"
  # shellcheck disable=SC2086 # args holds zero or one word
  if [[ $2 == no-secret-key ]]; then RUN_SECRET="" run $args; else run $args; fi
  err="$(first_err)" || return 1
  # shellcheck disable=SC2053 # want_err is a glob: * stands for an object id
  [[ $status == "$want_status" && $err == $want_err && ! -e $r/dist && ! -e $record/gh ]]
}

echo "rows"
check "the release archive is the tag under vgs-1.2.3/ with no gzip name or time" archive_row "$script"
check "SHA256SUMS lists the archive and the tag's install.sh" sums_row "$script"
check "the release key signs the published SHA256SUMS" sign_row "$script"
check "gh creates the release from the verified tag with the four assets" upload_row "$script"
check "--dry-run neither signs nor uploads" dry_row "$script"
check "assets an earlier run left in dist/ are replaced or removed" stale_row "$script"
check "a failed signature uploads nothing" sign_failure_row "$script"
check "a failed gh refuses" gh_failure_row "$script"
for name in $(printf '%s\n' "${!channels[@]}" | LC_ALL=C sort); do
  check "parity: the $name build hands its container the release asset of its commit" parity_row "$builder" "$name"
done
for name in $(printf '%s\n' "${!refusals[@]}" | LC_ALL=C sort); do
  check "refusal: $name" refusal_row "$script" "$name"
done

# The dry run on this repository's working tree, with a fixture release
# key pinned in its install.sh and its tag pushed to a stand-in.
real_tree_row() {
  local version dest unpacked
  r="$tmp/real"
  work_tree_repo "$r"
  version="$(cat -- "$r/VERSION")"
  python3 - "$r/install.sh" "$fpr" <<'PY' || return 1
import re, sys
path, fpr = sys.argv[1:]
text = open(path).read()
changed, n = re.subn(r'^(\s*release_key=)"[^"]*"$', lambda m: m.group(1) + '"' + fpr + '"', text, flags=re.M)
if n != 1:
    sys.exit("release_key assignments: %d" % n)
open(path, "w").write(changed)
PY
  h="$tmp/homes/real"
  { g -C "$r" commit -q -am "pin a fixture release key" && g -C "$r" tag -a "v$version" -m "VGS $version" &&
    g init -q --bare "$r.git" && g -C "$r" push -q "$r.git" "v$version" && mkdir -p "$h" &&
    g config --file "$h/.gitconfig" "url.file://$r.git.insteadOf" "$github"; } || { echo "$suite: fixture=real-tree" >&2; exit 1; }
  run --dry-run "$version"
  [[ $status == 0 && $(last_out) == "release: ok tag=v$version dry-run=true" ]] || { cat -- "$tmp/err"; return 1; }
  # The archive holds exactly the tag's files, and installs with its own
  # installer into the tree its own manifest lists.
  unpacked="$tmp/real-unpacked"; dest="$tmp/real-dest"
  mkdir -p "$unpacked" && tar -C "$unpacked" -xzf "$r/dist/vgs-$version.tar.gz" || return 1
  [[ $(ls -A "$unpacked") == "vgs-$version" && $(cat -- "$unpacked/vgs-$version/VERSION") == "$version" ]] &&
    [[ $(cd -- "$unpacked/vgs-$version" && find . -type f -o -type l | sed 's|^\./||' | LC_ALL=C sort) == "$(g -C "$r" ls-tree -r --name-only "v$version" | LC_ALL=C sort)" ]] &&
    env DESTDIR="$dest" PREFIX=/usr "$unpacked/vgs-$version/packaging/install-system.sh" >/dev/null &&
    "$unpacked/vgs-$version/scripts/check-install-tree.sh" "$dest" /usr >/dev/null
}
check "the dry run on this working tree builds an archive that installs" real_tree_row

echo "controls"
# rule NAME ROW NEEDLE REPLACEMENT [ROW_ARG]: a copy of the script without
# one rule, NEEDLE replaced, on which ROW must fail.
rule() {
  copy_with "$1" "$script" "$3" "$4"
  if "$2" "$copy" ${5:+"$5"} >/dev/null; then fail "control: $1: $2 passed on the copy"; else ok "control: a copy without the $1 rule"; fi
}
rule version refusal_row '[[ $version == "$want" ]] ||' '[[ $version == "$version" ]] ||' version-mismatch
rule dirty-tree refusal_row '[[ -z $changes ]] ||' 'true ||' dirty
rule tag-at-head refusal_row '[[ $tag_commit == "$head" ]] ||' '[[ $tag_commit == "$tag_commit" ]] ||' tag-not-head
rule tag-pushed refusal_row '[[ -n $remote_object ]] ||' 'true ||' tag-not-pushed
rule same-tag refusal_row '[[ $remote_object == "$tag_object" ]] ||' 'true ||' tag-differs
rule key-set refusal_row '[[ -n $key ]] ||' 'true ||' key-unset
rule key-format refusal_row '[[ $key =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] ||' 'true ||' key-malformed
rule secret-key refusal_row 'gpg --batch --list-secret-keys -- "$key" >/dev/null 2>&1 ||' 'true ||' no-secret-key
rule archive-version archive_row '"$tag_commit" "$version" "$stage/$archive"' '"$tag_commit" "0.0.0" "$stage/$archive"'
rule sums-cover-installer sums_row 'sha256sum -- "$archive" install.sh >SHA256SUMS' 'sha256sum -- "$archive" >SHA256SUMS'
rule signing-key sign_row '--local-user "$key" ' ''
rule verify-tag upload_row '--repo "$repository" --verify-tag' '--repo "$repository"'
rule dry-run-signs-nothing dry_row 'if [[ $dry_run == false ]]; then' 'if true; then'
rule stale-assets stale_row 'rm -f -- "${dist:?}/$name" ||' 'true ||'
rule sign-failure sign_failure_row '"$stage/SHA256SUMS" ||' '"$stage/SHA256SUMS" || true ||'
rule gh-failure gh_failure_row '(cd -- "$dist" && "${create[@]}") ||' '(cd -- "$dist" && "${create[@]}") || true ||'
# builder_rule NAME NEEDLE REPLACEMENT: a builder copy that packs another
# way, NEEDLE replaced, handed to each channel alone; every channel's parity
# row must fail on it.
builder_rule() {
  local name
  copy_with "builder-$1" "$builder" "$2" "$3"
  for name in $(printf '%s\n' "${!channels[@]}" | LC_ALL=C sort); do
    if parity_row "$copy" "$name" >/dev/null; then fail "control: builder-$1: parity_row $name passed on the copy"; else ok "control: the $name parity row fails on a builder that changes the $1"; fi
  done
}
builder_rule prefix '--prefix="vgs-$version/"' '--prefix="vgs/"'
builder_rule compression '| gzip -n -9 >"$out"' '| gzip -n >"$out"'
# channel_rule CHANNEL NEEDLE REPLACEMENT: a copy of the channel's script
# that packs its tarball under another name; its parity row must fail.
channel_rule() {
  local command
  command="${channels[$1]%%|*}"
  copy_with "channel-$1" "$repo/$command" "$2" "$3"
  if parity_row "$builder" "$1" "$copy" >/dev/null; then fail "control: channel-$1: parity_row passed on the copy"; else ok "control: the $1 parity row fails on a channel copy that passes the builder another version"; fi
}
channel_rule arch '"$commit" "$version" "$scratch/in/vgs/' '"$commit" "$commit" "$scratch/in/vgs/'
channel_rule fedora '"$head" "$version" "$work/' '"$head" "$head" "$work/'

rows_done "$suite"
