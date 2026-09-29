#!/usr/bin/env bash
# Controls for scripts/publish-aur.sh. Each row runs a copy of the script
# inside a clone of this repository's working tree, as `git add -A` would
# commit it, so the recipes and scripts/check-packaging.js it runs are the
# real ones. Rows run under env -i with a fixture HOME that holds the git
# identity and, for --dry-run, a url.insteadOf that turns
# https://aur.archlinux.org/ into a directory of local bare repositories,
# the AUR's stand-in. A stub ssh first on PATH records its arguments and
# serves the ssh:// clone and push from that directory with git's own
# upload-pack and receive-pack. A stub gh records its arguments and answers
# `release list` and `release view` from fixture JSON.
#
# The pinned fixture tags the clone v<VERSION> and pins a fixture sha256 in
# the vgs recipe and its .SRCINFO, which makepkg writes, so the recipe
# check passes as it does after a release.
#
# The controls at the end run copies of the script with one rule removed
# each, and the row that judges that rule must turn red on its copy.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

suite=test-publish-aur
for tool in git makepkg python3 tar; do
  command -v "$tool" >/dev/null || { echo "$suite: status=not-measured missing=$tool"; exit 77; }
done

script="$repo/scripts/publish-aur.sh"
sha="$(printf '%064d' 7)"
record="$tmp/record"; stubs="$tmp/publish-stubs"; gh_dir="$tmp/gh"; scratch="$tmp/scratch"
mkdir -p "$record" "$stubs" "$gh_dir" "$scratch"
key="$tmp/aur_key"
printf 'fixture key\n' >"$key"

cat >"$stubs/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_RECORD/ssh.$(ls "$STUB_RECORD" | grep -c '^ssh\.')"
command="${*: -1}"
[[ $command =~ ^git-(upload-pack|receive-pack)\ \'/([a-z-]+\.git)\'$ ]] || exit 64
exec git "${BASH_REMATCH[1]}" "$STUB_AUR/${BASH_REMATCH[2]}"
EOF
cat >"$stubs/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_RECORD/gh"
case "$1 $2" in
  "release list") [[ ! -f $STUB_GH/list.exit ]] || exit "$(cat "$STUB_GH/list.exit")"; cat "$STUB_GH/list.json" ;;
  "release view") cat "$STUB_GH/view.json" ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$stubs/ssh" "$stubs/gh"

base="$tmp/base"
work_tree_repo "$base"
version="$(cat -- "$base/VERSION")"

# fixture NAME SCRIPT: sets r to a new clone of $base holding SCRIPT as
# scripts/publish-aur.sh, aur to its AUR stand-in with an empty bare
# repository per package whose HEAD is master, as the AUR's is, and h to
# its home. The gh answers start as no
# release. A fixture that cannot be built stops the suite.
fixtures=0
fixture() {
  fixtures=$((fixtures + 1))
  r="$tmp/rows/$fixtures-$1"
  aur="$tmp/aur/$fixtures-$1"
  h="$tmp/homes/$fixtures-$1"
  {
    g clone -q "$base" "$r" && cp -- "$2" "$r/scripts/publish-aur.sh" &&
      mkdir -p "$aur" "$h" && g init -q --bare -b master "$aur/vgs.git" && g init -q --bare -b master "$aur/vgs-git.git" &&
      g config --file "$h/.gitconfig" user.name maintainer && g config --file "$h/.gitconfig" user.email maintainer@example.invalid &&
      g config --file "$h/.gitconfig" "url.file://$aur/.insteadOf" https://aur.archlinux.org/ &&
      printf '[]\n' >"$gh_dir/list.json" && printf '{"assets":[]}\n' >"$gh_dir/view.json" && rm -f -- "$gh_dir/list.exit"
  } || { echo "$suite: fixture=$1" >&2; exit 1; }
}
# pin: tags the fixture v$version and pins $sha in the vgs recipe, as the
# release step does.
pin() {
  {
    g -C "$r" tag -a "v$version" -m "VGS $version" &&
      python3 - "$r/packaging/arch/vgs/PKGBUILD" "$sha" <<'PY' &&
import re, sys
path, sha = sys.argv[1:]
text = open(path).read()
changed, n = re.subn(r"^sha256sums=\('SKIP'\)$", "sha256sums=('" + sha + "')", text, flags=re.M)
if n != 1:
    sys.exit("sha256sums lines: %d" % n)
open(path, "w").write(changed)
PY
      (cd -- "$r/packaging/arch/vgs" && makepkg --printsrcinfo >.SRCINFO) && g -C "$r" commit -q -am pin
  } || { echo "$suite: fixture=pin" >&2; exit 1; }
}
# release_answer TAG DRAFT DIGEST: gh lists TAG, a draft when DRAFT is
# true, whose asset vgs-$version.tar.gz has DIGEST; an empty DIGEST lists
# no asset, and `null` a null digest.
release_answer() {
  printf '[{"tagName":"%s","isDraft":%s}]\n' "$1" "$2" >"$gh_dir/list.json"
  if [[ -z $3 ]]; then
    printf '{"assets":[{"name":"SHA256SUMS","digest":"sha256:%s"}]}\n' "$sha" >"$gh_dir/view.json"
  elif [[ $3 == null ]]; then
    printf '{"assets":[{"name":"vgs-%s.tar.gz","digest":null}]}\n' "$version" >"$gh_dir/view.json"
  else
    printf '{"assets":[{"name":"vgs-%s.tar.gz","digest":"sha256:%s"}]}\n' "$version" "$3" >"$gh_dir/view.json"
  fi
}

# run ARGS...: $r/scripts/publish-aur.sh from $h with AUR_SSH_KEY_FILE,
# RUN_KEY replacing it and an empty RUN_KEY unsetting it. Stdout lands in
# $tmp/out, stderr in $tmp/err, the exit status in $status; the stubs'
# records start empty.
run() {
  local -a key_env=()
  [[ -z ${RUN_KEY-$key} ]] || key_env=(AUR_SSH_KEY_FILE="${RUN_KEY-$key}")
  rm -f -- "$record"/*
  status=0
  env -i PATH="$stubs:$base_path" HOME="$h" GIT_CONFIG_NOSYSTEM=1 TMPDIR="$scratch" STUB_RECORD="$record" \
    STUB_AUR="$aur" STUB_GH="$gh_dir" "${key_env[@]}" \
    bash "$r/scripts/publish-aur.sh" "$@" >"$tmp/out" 2>"$tmp/err" </dev/null || status=$?
}
# The first stderr line of the script's own: the recipe check's lines come
# before it.
first_err() { grep -m1 '^publish-aur: ' "$tmp/err" || (($? == 1)); }
has_out() { grep -qxF -- "$1" "$tmp/out"; }
recipe() { # PACKAGE KEY: the value of KEY in the fixture's .SRCINFO for PACKAGE
  awk -F' = ' -v k=$'\t'"$2" '$1 == k { print $2 }' "$r/packaging/arch/$1/.SRCINFO"
}
# aur_holds PACKAGE: the AUR stand-in's master holds exactly the recipe's
# PKGBUILD and .SRCINFO.
aur_holds() {
  local tree="$tmp/check-$fixtures-$1"
  g clone -q "$aur/$1.git" "$tree" 2>/dev/null &&
    [[ $(g -C "$tree" rev-parse --abbrev-ref HEAD) == master && $(g -C "$tree" ls-files | LC_ALL=C sort) == $'.SRCINFO\nPKGBUILD' ]] &&
    cmp -s -- "$tree/PKGBUILD" "$r/packaging/arch/$1/PKGBUILD" && cmp -s -- "$tree/.SRCINFO" "$r/packaging/arch/$1/.SRCINFO"
}
aur_empty() { [[ -z $(g -C "$aur/$1.git" for-each-ref) ]]; }

# The rows each judge one rule, on the script SCRIPT names, so a control
# can run them again on a copy with that rule removed.

publish_row() { # SCRIPT: vgs-git is committed as its version and pushed to master
  local v
  fixture publish "$1"
  run vgs-git
  v="$(recipe vgs-git pkgver)-$(recipe vgs-git pkgrel)"
  [[ $status == 0 ]] && aur_holds vgs-git &&
    has_out "publish-aur: published package=vgs-git version=$v commit=$(g -C "$aur/vgs-git.git" rev-parse master)" &&
    [[ $(g -C "$aur/vgs-git.git" log -1 --format=%s%n%b master) == "vgs-git $v"$'\n'"From vanillagreencom/vgs $(g -C "$r" rev-parse HEAD)" ]]
}
ssh_row() { # SCRIPT: ssh reads the key and the pinned host keys, and no ~/.ssh or /etc/ssh file
  fixture ssh "$1"
  run vgs-git
  local want options=(-F /dev/null -i "$key" -o IdentitiesOnly=yes -o "UserKnownHostsFile=$r/packaging/aur-known-hosts"
    -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o UpdateHostKeys=no)
  want="$(printf '%s\n' "${options[@]}")" || return 1
  [[ $status == 0 && -f $record/ssh.0 && -f $record/ssh.1 ]] &&
    [[ $(head -n 14 -- "$record/ssh.0") == "$want" && $(head -n 14 -- "$record/ssh.1") == "$want" ]] &&
    grep -qxF aur@aur.archlinux.org "$record/ssh.0"
}
unchanged_row() { # SCRIPT: a second run finds nothing to commit
  fixture unchanged "$1"
  run vgs-git
  run vgs-git
  [[ $status == 0 ]] && has_out "publish-aur: unchanged package=vgs-git version=$(recipe vgs-git pkgver)-$(recipe vgs-git pkgrel)" &&
    [[ $(g -C "$aur/vgs-git.git" rev-list --count master) == 1 ]]
}
mirror_row() { # SCRIPT: a file only the AUR holds is removed and an AUR edit overwritten
  local seed
  fixture mirror "$1"
  seed="$tmp/seed-$fixtures"
  { g clone -q "$aur/vgs-git.git" "$seed" 2>/dev/null && printf 'old\n' >"$seed/vgs-git.install" && printf 'edited\n' >"$seed/PKGBUILD" &&
    g -C "$seed" add -A && g -C "$seed" commit -q -m seed && g -C "$seed" push -q origin HEAD:master; } || { echo "$suite: fixture=seed" >&2; exit 1; }
  run vgs-git
  [[ $status == 0 ]] && aur_holds vgs-git
}
dry_row() { # SCRIPT: --dry-run clones over HTTPS, needs no key and pushes nothing
  fixture dry "$1"
  RUN_KEY="" run --dry-run vgs-git
  [[ $status == 0 ]] && has_out "publish-aur: would-publish package=vgs-git version=$(recipe vgs-git pkgver)-$(recipe vgs-git pkgrel)" &&
    ! compgen -G "$record/ssh.*" >/dev/null && aur_empty vgs-git
}
release_row() { # SCRIPT: vgs is published once GitHub's digest of its asset is the pinned sha256
  fixture release "$1"
  pin
  release_answer "v$version" false "$sha"
  run vgs
  [[ $status == 0 ]] && aur_holds vgs &&
    [[ $(cat -- "$record/gh") == "release list --repo vanillagreencom/vgs --limit 1000 --json tagName,isDraft
release view v$version --repo vanillagreencom/vgs --json assets" ]]
}

# Deferrals of vgs: name | fixture: pinned or base | the gh answer | the
# reason. vgs-git, named after it, is still published, and the run exits 75.
declare -A deferrals=(
  [unpinned]="base||unpinned"
  [no-release]="pinned|v0.0.1 false $sha|no-release"
  [draft]="pinned|v$version true $sha|draft"
  [no-asset]="pinned|v$version false |no-asset"
  [checksum-mismatch]="pinned|v$version false $(printf '%064d' 8)|checksum-mismatch recipe=$sha asset=$(printf '%064d' 8)"
)
deferral_row() { # SCRIPT NAME
  local kind answer reason
  IFS='|' read -r kind answer reason <<<"${deferrals[$2]}"
  fixture "defer-$2" "$1"
  [[ $kind == base ]] || pin
  # shellcheck disable=SC2086 # answer holds the three release_answer words, the last possibly empty
  [[ -z $answer ]] || release_answer $answer ""
  run vgs vgs-git
  [[ $status == 75 ]] && has_out "publish-aur: deferred package=vgs reason=$reason" && aur_empty vgs && aur_holds vgs-git &&
    { [[ $kind == pinned ]] || [[ ! -e $record/gh ]]; }
}

# Refusals: name | fixture change | the arguments | exit status | the first
# keyed stderr line, %r the fixture. Each leaves the AUR stand-in empty.
tweak_none() { :; }
tweak_stale() { sed -i "s/^pkgdesc='/pkgdesc='Stale /" "$r/packaging/arch/vgs-git/PKGBUILD" && g -C "$r" commit -q -am stale; }
tweak_untracked() { printf 'x\n' >"$r/packaging/arch/vgs-git/notes"; }
tweak_no_key() { RUN_KEY=""; }
tweak_absent_key() { RUN_KEY="$tmp/absent_key"; }
tweak_gh_down() { pin && printf '1\n' >"$gh_dir/list.exit"; }
tweak_null_digest() { pin && release_answer "v$version" false null; }
tweak_no_aur() { rm -rf -- "${aur:?}/vgs-git.git"; }
declare -A refusals=(
  [no-argument]="tweak_none||2|publish-aur: refused: argument=missing"
  [unknown-package]="tweak_none|vgs-shell|2|publish-aur: refused: package=vgs-shell reason=unknown"
  [repeated-package]="tweak_none|vgs-git vgs-git|2|publish-aur: refused: package=vgs-git reason=repeated"
  [stale-srcinfo]="tweak_stale|vgs-git|1|publish-aur: refused: recipes=refused status=1"
  [uncommitted]="tweak_untracked|vgs-git|1|publish-aur: refused: recipe=uncommitted package=vgs-git"
  [no-key]="tweak_no_key|vgs-git|1|publish-aur: refused: secret=missing name=AUR_SSH_KEY_FILE"
  [absent-key]="tweak_absent_key|vgs-git|1|publish-aur: refused: secret=missing name=AUR_SSH_KEY_FILE path=$tmp/absent_key"
  [gh-down]="tweak_gh_down|vgs|1|publish-aur: refused: gh=release-list repo=vanillagreencom/vgs"
  [null-digest]="tweak_null_digest|vgs|1|publish-aur: refused: gh=asset-digest-unreadable tag=v$version name=vgs-$version.tar.gz status=5"
  [no-aur-repository]="tweak_no_aur|vgs-git|1|publish-aur: refused: git=clone url=ssh://aur@aur.archlinux.org/vgs-git.git"
)
refusal_row() { # SCRIPT NAME
  local tweak args want_status want_err
  IFS='|' read -r tweak args want_status want_err <<<"${refusals[$2]}"
  fixture "refuse-$2" "$1"
  RUN_KEY="$key"
  "$tweak" || { echo "$suite: fixture=$tweak" >&2; exit 1; }
  # shellcheck disable=SC2086 # args holds zero, one or two words
  run $args
  [[ $status == "$want_status" && $(first_err) == "$want_err" ]] && aur_empty vgs &&
    { [[ ! -d $aur/vgs-git.git ]] || aur_empty vgs-git; }
}

echo "rows"
check "vgs-git is committed as its version and pushed to master" publish_row "$script"
check "ssh reads the key and the pinned host keys alone" ssh_row "$script"
check "an unchanged recipe commits nothing" unchanged_row "$script"
check "the AUR repository ends up holding the recipe's files alone" mirror_row "$script"
check "--dry-run clones over HTTPS and pushes nothing" dry_row "$script"
check "vgs is published once its asset's digest is the pinned sha256" release_row "$script"
for name in $(printf '%s\n' "${!deferrals[@]}" | LC_ALL=C sort); do
  check "deferral: $name" deferral_row "$script" "$name"
done
for name in $(printf '%s\n' "${!refusals[@]}" | LC_ALL=C sort); do
  check "refusal: $name" refusal_row "$script" "$name"
done
unset RUN_KEY

echo "controls"
# rule NAME ROW NEEDLE REPLACEMENT [ROW_ARG]: a copy of the script without
# one rule, NEEDLE replaced, on which ROW must fail.
rule() {
  copy_with "$1" "$script" "$3" "$4"
  if "$2" "$copy" ${5:+"$5"} >/dev/null; then fail "control: $1: $2 passed on the copy"; else ok "control: a copy without the $1 rule"; fi
  unset RUN_KEY
}
rule recipe-check refusal_row 'node "$repo/scripts/check-packaging.js" >&2 ||' 'true ||' stale-srcinfo
rule committed-recipe refusal_row '[[ -z $changes ]] || refuse 1 "recipe=uncommitted' 'true || refuse 1 "recipe=uncommitted' uncommitted
rule key-required refusal_row '[[ -n ${AUR_SSH_KEY_FILE:-} ]] ||' 'true ||' no-key
rule gh-failure refusal_row '--json tagName,isDraft)" ||' '--json tagName,isDraft)" || true ||' gh-down
rule strict-host-keys ssh_row '-o StrictHostKeyChecking=yes' '-o StrictHostKeyChecking=accept-new'
rule no-ssh-config ssh_row 'ssh -F /dev/null ' 'ssh '
rule mirror mirror_row 'git -C "$clone" rm -r --quiet --ignore-unmatch -- . ||' 'true ||'
rule dry-run-https dry_row 'url="https://aur.archlinux.org/$package.git"' 'url="ssh://aur@aur.archlinux.org/$package.git"'
rule dry-run-no-push dry_row 'if [[ $dry_run == true ]]; then printf' 'if false; then printf'
rule unpinned-defers deferral_row '[[ $2 != SKIP ]] ||' 'true ||' unpinned
rule draft-defers deferral_row 'found[0].isDraft ? "draft" : "published"' '"published"' draft
rule checksum-defers deferral_row 'elif [[ $state != "$2" ]]; then' 'elif false; then' checksum-mismatch
rule deferral-status deferral_row '((deferred == 0)) || exit 75' '((deferred == 0)) || exit 0' no-release

rows_done "$suite"
