#!/usr/bin/env bash
# Publish the in-repo Arch recipes to their AUR repositories.
#
# The AUR keeps a git repository per package and pulls nothing from here, so
# `packaging/arch/` only reaches users when something pushes it. That something
# is this script — used by .github/workflows/publish-aur.yml and by the release
# procedure in .agents/skills/vgs-release/SKILL.md. The AUR side is never edited
# by hand: a change made there is drift the next run overwrites, and
# scripts/check-aur-sync.py --remote reports in the meantime.
#
# Usage:
#   scripts/publish-aur.sh --dry-run [package...]   # read-only, shows the diff
#   scripts/publish-aur.sh [package...]             # commits and pushes (needs
#                                                   # an AUR account with commit
#                                                   # rights and its SSH key)
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

dry_run=0
packages=()
for argument in "$@"; do
  case "$argument" in
    --dry-run) dry_run=1 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "publish-aur: unknown option $argument" >&2; exit 2 ;;
    *) packages+=("$argument") ;;
  esac
done
if [[ ${#packages[@]} -eq 0 ]]; then
  packages=(vgs-shell vgs-shell-git)
fi

directory_for() {
  case "$1" in
    vgs-shell) echo "packaging/arch" ;;
    vgs-shell-git) echo "packaging/arch/vgs-shell-git" ;;
    *) echo "publish-aur: no in-repo recipe for '$1'" >&2; return 1 ;;
  esac
}

files_for() {
  case "$1" in
    vgs-shell) echo "PKGBUILD .SRCINFO vgs-shell.install" ;;
    vgs-shell-git) echo "PKGBUILD .SRCINFO vgs-shell-git.install" ;;
  esac
}

# Never publish a recipe whose own PKGBUILD and .SRCINFO disagree: .SRCINFO is
# what the AUR serves to paru and yay, so pushing a stale one ships metadata
# nobody can see is wrong.
"$root/scripts/check-aur-sync.py"

revision="$(git -C "$root" rev-parse --short HEAD)"
message="sync from vanillagreencom/vgs $revision"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

status=0
for package in "${packages[@]}"; do
  source_dir="$root/$(directory_for "$package")"
  clone="$tmp/$package"

  if [[ "$dry_run" -eq 1 ]]; then
    remote="https://aur.archlinux.org/$package.git"
  else
    remote="ssh://aur@aur.archlinux.org/$package.git"
  fi

  if ! git clone --quiet "$remote" "$clone"; then
    echo "publish-aur: cannot clone $remote; NOTHING was published for $package" >&2
    status=1
    continue
  fi

  for file in $(files_for "$package"); do
    install -m 644 "$source_dir/$file" "$clone/$file"
  done

  # Intent-to-add first: a file the AUR does not carry at all lands untracked,
  # and `git diff` ignores untracked files. Neither AUR repository publishes its
  # .install scriptlet today, so without this a package whose PKGBUILD and
  # .SRCINFO already match would report as current and the missing scriptlet
  # would never be pushed — and --dry-run would not show it either.
  git -C "$clone" add --intent-to-add --all

  if git -C "$clone" diff --quiet --exit-code; then
    echo "publish-aur: $package is already what this repo holds"
    continue
  fi

  echo "publish-aur: $package changes"
  git -C "$clone" --no-pager diff --stat

  if [[ "$dry_run" -eq 1 ]]; then
    git -C "$clone" --no-pager diff
    echo "publish-aur: --dry-run, so $package was NOT pushed"
    continue
  fi

  git -C "$clone" add --all
  # The AUR rejects a push with no committer identity, and a CI runner has
  # none configured. AUR_COMMIT_NAME/EMAIL let the caller name the account.
  identity=()
  if ! git -C "$clone" config user.email >/dev/null; then
    identity=(
      -c "user.name=${AUR_COMMIT_NAME:-VGS packaging}"
      -c "user.email=${AUR_COMMIT_EMAIL:-packaging@vanillagreen}"
    )
  fi
  git -C "$clone" "${identity[@]}" commit --quiet -m "$message"
  git -C "$clone" push --quiet origin HEAD:master
  echo "publish-aur: pushed $package ($message)"
done

exit "$status"
