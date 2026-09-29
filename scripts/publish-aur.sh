#!/usr/bin/env bash
# Publish the Arch recipes under packaging/arch to their AUR repositories.
#
#   scripts/publish-aur.sh [--dry-run] PACKAGE...    PACKAGE: vgs, vgs-git
#
# Run it from the checkout whose recipes are published; docs/RELEASING.md
# holds the whole flow. Before any package it refuses:
#   - recipes that fail `node scripts/check-packaging.js`, which holds each
#     .SRCINFO to `makepkg --printsrcinfo` of the PKGBUILD beside it and
#     pins vgs's sha256 once the tag v<pkgver> exists;
#   - a named recipe directory with uncommitted or untracked files, or with
#     a subdirectory, which the AUR refuses;
#   - without --dry-run, AUR_SSH_KEY_FILE unset or naming no file, and a
#     missing packaging/aur-known-hosts.
# Then, per package in argument order:
#   - vgs is deferred until the GitHub release v<pkgver> is published, not a
#     draft, and GitHub's sha256 digest of its asset vgs-<pkgver>.tar.gz is
#     the one sha256sums entry of the recipe's .SRCINFO (`gh release list`
#     and `gh release view`); a recipe still at SKIP is deferred unread;
#   - the AUR repository is cloned into a temporary directory:
#     ssh://aur@aur.archlinux.org/PACKAGE.git, with ssh reading no ~/.ssh
#     file, only AUR_SSH_KEY_FILE and the pinned host keys, or
#     https://aur.archlinux.org/PACKAGE.git for --dry-run;
#   - its files are replaced by the recipe directory's tracked files, so a
#     file edited on the AUR alone is overwritten and one the recipe dropped
#     is removed; with no change nothing is committed;
#   - otherwise the change is committed as `PACKAGE <pkgver>-<pkgrel>` with
#     the maintainer's git identity and pushed to master, which the AUR
#     serves. Its diff stat is printed first. --dry-run prints the stat and
#     neither commits nor pushes.
#
# Output, one keyed stdout line per package: `publish-aur: published package=<p>
# version=<v> commit=<sha>`, `publish-aur: unchanged package=<p>
# version=<v>`, `publish-aur: would-publish package=<p> version=<v>` or
# `publish-aur: deferred package=<p> reason=<r>`, reason unpinned,
# no-release, draft, no-asset or checksum-mismatch. A refusal is one line on
# stderr, `publish-aur: refused: <key>=<value> ...`, then English, and stops
# the run. Exit 0 when every package is published, unchanged or would be
# published; 75 when every package is done or deferred and one is
# deferred; 1 for a refusal; 2 for an argument.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd -P)"
repository=vanillagreencom/vgs

refuse() { # STATUS KEY [DETAIL...]
  local status="$1"
  printf 'publish-aur: refused: %s\n' "$2" >&2
  shift 2
  [[ $# -eq 0 ]] || printf '%s\n' "$@" >&2
  exit "$status"
}

dry_run=false
packages=()
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      [[ $dry_run == false ]] || refuse 2 "argument=$arg" "--dry-run is given once"
      dry_run=true ;;
    -h|--help) sed -n '2,/^[^#]/{/^#/{s/^# \{0,1\}//;p}}' "$self"; exit 0 ;;
    vgs|vgs-git)
      [[ " ${packages[*]-} " != *" $arg "* ]] || refuse 2 "package=$arg reason=repeated"
      packages+=("$arg") ;;
    -*) refuse 2 "argument=$arg" ;;
    *) refuse 2 "package=$arg reason=unknown" "the packages are vgs and vgs-git" ;;
  esac
done
[[ ${#packages[@]} -gt 0 ]] || refuse 2 "argument=missing" "usage: scripts/publish-aur.sh [--dry-run] PACKAGE..."

node "$repo/scripts/check-packaging.js" >&2 || refuse 1 "recipes=refused status=$?" "scripts/check-packaging.js names the recipe defect above"

for package in "${packages[@]}"; do
  dir="packaging/arch/$package"
  changes="$(git -C "$repo" status --porcelain --untracked-files=normal -- "$dir")" || refuse 1 "git=status path=$dir"
  [[ -z $changes ]] || refuse 1 "recipe=uncommitted package=$package" "commit the recipe before publishing it" "$changes"
done

if [[ $dry_run == false ]]; then
  [[ -n ${AUR_SSH_KEY_FILE:-} ]] || refuse 1 "secret=missing name=AUR_SSH_KEY_FILE" "set AUR_SSH_KEY_FILE to the private key of the AUR account that maintains the packages"
  [[ -f $AUR_SSH_KEY_FILE ]] || refuse 1 "secret=missing name=AUR_SSH_KEY_FILE path=$AUR_SSH_KEY_FILE"
  key_file="$(realpath -- "$AUR_SSH_KEY_FILE")" || refuse 1 "secret=unreadable path=$AUR_SSH_KEY_FILE"
  known_hosts="$repo/packaging/aur-known-hosts"
  [[ -f $known_hosts ]] || refuse 1 "known-hosts=missing path=$known_hosts"
  for path in "$key_file" "$known_hosts"; do
    [[ $path != *"'"* ]] || refuse 1 "path=unquotable value=$path" "GIT_SSH_COMMAND quotes paths in single quotes"
  done
  # git runs GIT_SSH_COMMAND through sh. -F /dev/null and
  # GlobalKnownHostsFile=/dev/null keep every ~/.ssh and /etc/ssh file out,
  # and UpdateHostKeys=no keeps ssh from writing the tracked host keys.
  export GIT_SSH_COMMAND="ssh -F /dev/null -i '$key_file' -o IdentitiesOnly=yes -o UserKnownHostsFile='$known_hosts' -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o UpdateHostKeys=no"
fi
export GIT_TERMINAL_PROMPT=0

work="$(mktemp -d)" || refuse 1 "scratch=mktemp-failed"
trap 'rm -rf -- "${work:?}"' EXIT
source_commit="$(git -C "$repo" rev-parse --verify HEAD)" || refuse 1 "git=rev-parse path=$repo"

srcinfo_value() { # PACKAGE KEY: the one `KEY = value` line of the recipe's .SRCINFO
  local line value="" count=0 path="$repo/packaging/arch/$1/.SRCINFO"
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == $'\t'"$2 = "* ]]; then
      value="${line#*= }"
      count=$((count + 1))
    fi
  done <"$path"
  ((count == 1)) || refuse 1 "srcinfo=unreadable key=$2 count=$count path=$path"
  printf '%s\n' "$value"
}

# Prints `ok`, or `deferred reason=<r>` while the release asset does not
# carry the sha256 the vgs recipe pins. A gh failure refuses: an unreachable
# GitHub is never read as a release not made yet.
release_state() { # PKGVER SHA256
  local tag="v$1" asset="vgs-$1.tar.gz" doc state
  [[ $2 != SKIP ]] || { echo "deferred reason=unpinned"; return 0; }
  doc="$(gh release list --repo "$repository" --limit 1000 --json tagName,isDraft)" ||
    refuse 1 "gh=release-list repo=$repository"
  state="$(node -e '
const [doc, tag] = process.argv.slice(1);
let list;
try { list = JSON.parse(doc); } catch (e) { process.exit(3); }
if (!Array.isArray(list)) process.exit(3);
const found = list.filter(r => r !== null && typeof r === "object" && r.tagName === tag);
if (found.length > 1 || (found.length === 1 && typeof found[0].isDraft !== "boolean")) process.exit(3);
if (found.length === 0 && list.length >= 1000) process.exit(4);
process.stdout.write(found.length === 0 ? "no-release" : found[0].isDraft ? "draft" : "published");
' "$doc" "$tag")" || refuse 1 "gh=release-list-unreadable repo=$repository status=$?"
  [[ $state == published ]] || { echo "deferred reason=$state"; return 0; }
  doc="$(gh release view "$tag" --repo "$repository" --json assets)" || refuse 1 "gh=release-view tag=$tag"
  state="$(node -e '
const [doc, name] = process.argv.slice(1);
let release;
try { release = JSON.parse(doc); } catch (e) { process.exit(3); }
if (release === null || typeof release !== "object" || !Array.isArray(release.assets)) process.exit(3);
const found = release.assets.filter(a => a !== null && typeof a === "object" && a.name === name);
if (found.length > 1) process.exit(3);
if (found.length === 0) { process.stdout.write("no-asset"); process.exit(0); }
const m = /^sha256:([0-9a-f]{64})$/.exec(found[0].digest);
if (m === null) process.exit(5);
process.stdout.write(m[1]);
' "$doc" "$asset")" || refuse 1 "gh=asset-digest-unreadable tag=$tag name=$asset status=$?"
  if [[ $state == no-asset ]]; then
    echo "deferred reason=no-asset"
  elif [[ $state != "$2" ]]; then
    printf 'deferred reason=checksum-mismatch recipe=%s asset=%s\n' "$2" "$state"
  else
    echo ok
  fi
}

# srcinfo_value and release_state refuse inside their command
# substitution, which prints the refusal; `|| exit 1` ends the run there.
deferred=0
for package in "${packages[@]}"; do
  pkgver="$(srcinfo_value "$package" pkgver)" || exit 1
  pkgrel="$(srcinfo_value "$package" pkgrel)" || exit 1
  version="$pkgver-$pkgrel"
  if [[ $package == vgs ]]; then
    sha="$(srcinfo_value vgs sha256sums)" || exit 1
    state="$(release_state "$pkgver" "$sha")" || exit 1
    if [[ $state != ok ]]; then
      printf 'publish-aur: deferred package=%s %s\n' "$package" "${state#deferred }"
      deferred=$((deferred + 1))
      continue
    fi
  fi

  files=()
  while IFS= read -r -d '' file; do
    [[ ${file#packaging/arch/"$package"/} != */* ]] || refuse 1 "recipe=subdirectory path=$file" "the AUR refuses subdirectories"
    files+=("$file")
  done < <(git -C "$repo" ls-files -z -- "packaging/arch/$package")
  [[ ${#files[@]} -gt 0 ]] || refuse 1 "recipe=missing package=$package"

  if [[ $dry_run == true ]]; then
    url="https://aur.archlinux.org/$package.git"
  else
    url="ssh://aur@aur.archlinux.org/$package.git"
  fi
  clone="$work/$package"
  git clone --quiet -- "$url" "$clone" || refuse 1 "git=clone url=$url"
  git -C "$clone" rm -r --quiet --ignore-unmatch -- . || refuse 1 "git=rm path=$clone"
  for file in "${files[@]}"; do
    cp -- "$repo/$file" "$clone/${file##*/}" || refuse 1 "copy=failed path=$file"
  done
  git -C "$clone" add -A || refuse 1 "git=add path=$clone"
  if git -C "$clone" diff --cached --quiet; then
    printf 'publish-aur: unchanged package=%s version=%s\n' "$package" "$version"
    continue
  fi
  git -C "$clone" --no-pager diff --cached --stat
  if [[ $dry_run == true ]]; then printf 'publish-aur: would-publish package=%s version=%s\n' "$package" "$version"; continue; fi
  git -C "$clone" commit --quiet -m "$package $version" -m "From $repository $source_commit" || refuse 1 "git=commit package=$package"
  git -C "$clone" push --quiet origin HEAD:master || refuse 1 "git=push url=$url"
  printf 'publish-aur: published package=%s version=%s commit=%s\n' "$package" "$version" "$(git -C "$clone" rev-parse HEAD)"
done

((deferred == 0)) || exit 75
