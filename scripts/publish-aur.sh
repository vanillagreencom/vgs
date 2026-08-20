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

# A recipe whose source_* point at release tarballs cannot be published before
# those tarballs exist: `yay -S vgs-shell` would fail to download its source for
# every user until the tag was built. This is the whole reason the stable
# package is published from release.yml. Checking the URLs rather than assuming
# lets a routine packaging change — a dependency fix that leaves pkgver alone —
# reach stable users immediately instead of waiting for the next release.
#
# Three outcomes, and the difference between the last two is the whole point:
#   0  every source resolves            -> publish
#   1  a source is definitively absent  -> defer this package, run stays green
#   2  the check could not be made      -> FAIL the run
#
# "Not released yet" and "the runner's DNS blinked" look identical if you only
# ask whether curl succeeded, and treating the second as the first is silent
# non-delivery — the exact failure VGS-5 and VGS-53 are about, reintroduced in
# the tool meant to end it. curl can tell them apart, so it is asked to: a
# transport error is a transport error, and only 404/410 means "not there".
sources_exist() {
  local package="$1" url sources code rc

  if ! sources="$("$root/scripts/check-aur-sync.py" --print-sources "$package")"; then
    echo "publish-aur: cannot read the source URLs of $package, so whether they resolve is unknown." >&2
    return 2
  fi

  while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    # `rc=0; x=$(...) || rc=$?` rather than assign-then-read-$?: under `set -e`
    # a failing command substitution in a bare assignment aborts the script, so
    # the classification below would never run. It survives today only because
    # every caller invokes this function in a `||` list, which suspends errexit
    # for the whole body — a property of the call site, not of this code.
    rc=0
    code="$(curl -sSL --head --max-time 30 --retry 2 -o /dev/null -w '%{http_code}' "$url")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "publish-aur: cannot reach $url (curl exit $rc), so whether $package's source exists is unknown." >&2
      echo "publish-aur: not treating an unreachable host as a missing release — that would skip the publish and leave the AUR stale with a green run." >&2
      return 2
    fi
    case "$code" in
      2??) ;;
      404|410)
        echo "publish-aur: $package is NOT published: its source $url returned $code." >&2
        echo "publish-aur: that is expected between a version bump and its release tag — release.yml publishes it once the tarballs are up. If no release is pending, the source URL is wrong." >&2
        return 1
        ;;
      *)
        echo "publish-aur: $url returned $code, which is neither a working source nor a missing one." >&2
        echo "publish-aur: failing rather than guessing; a 403 or a 5xx is a fault to look at, not a release that has not happened yet." >&2
        return 2
        ;;
    esac
  done <<< "$sources"
  return 0
}

# A source that EXISTS is not yet a source that INSTALLS. Between a version bump
# and the checksum pin, `source_x86_64` names the new tarball while
# `sha256sums_x86_64` still holds the previous release's digest — every URL
# resolves, the check above is satisfied, and `makepkg` fails validity checking
# for every user who runs `yay -S vgs-shell`. release.yml calls this script
# immediately after a tag builds, which is precisely that window, so existence
# alone is the wrong question to stop at.
#
# The release publishes SHA256SUMS beside the tarballs, so the answer costs one
# 283-byte fetch rather than 2 GiB of downloads. Same three outcomes as above,
# and for the same reason: a digest that disagrees is a recipe waiting for its
# pin (defer), and a SHA256SUMS that cannot be read is not evidence of anything
# (fail).
checksums_match() {
  local package="$1" pairs url digest sums_url sums code rc name

  if ! pairs="$("$root/scripts/check-aur-sync.py" --print-source-checksums "$package")"; then
    echo "publish-aur: cannot read the declared checksums of $package, so whether they are current is unknown." >&2
    return 2
  fi

  while IFS=$'\t' read -r url digest; do
    [[ -n "$url" ]] || continue
    sums_url="${url%/*}/SHA256SUMS"
    rc=0
    sums="$(curl -sSL --max-time 30 --retry 2 -w '\n%{http_code}' "$sums_url")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "publish-aur: cannot reach $sums_url (curl exit $rc), so whether $package's checksums are current is unknown." >&2
      return 2
    fi
    code="${sums##*$'\n'}"
    sums="${sums%$'\n'*}"
    if [[ "$code" != 2?? ]]; then
      echo "publish-aur: $sums_url returned $code; refusing to publish $package without reading the release's own checksums." >&2
      return 2
    fi

    name="${url##*/}"
    # `awk` rather than `grep`, so a filename that is a prefix of another cannot
    # match the wrong row.
    if ! echo "$sums" | awk -v want="$digest" -v file="$name" '
      { published = $1; sub(/^\*/, "", $2) }
      $2 == file { found = 1; if (published == want) ok = 1 }
      END { exit (found && ok) ? 0 : 1 }
    '; then
      echo "publish-aur: $package declares a sha256 for $name that the release does not publish." >&2
      echo "publish-aur: that is the state between a version bump and its checksum pin. Pin the sums from $sums_url and publish again; shipping this recipe would fail makepkg's validity check for every user." >&2
      return 1
    fi
  done <<< "$pairs"
  return 0
}

status=0
published=()
for package in "${packages[@]}"; do
  source_dir="$root/$(directory_for "$package")"
  clone="$tmp/$package"

  sources_exist "$package" || case "$?" in
    1) continue ;;          # deferred by design; release.yml owns it
    *) status=1; continue ;;  # could not check: never green
  esac

  checksums_match "$package" || case "$?" in
    1) continue ;;          # awaiting its checksum pin
    *) status=1; continue ;;  # could not check: never green
  esac

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
    published+=("$package")
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
  published+=("$package")
done

# Prove the push landed, for exactly the packages this run published. Scoping
# matters: verifying a package that was deliberately not published — one whose
# release tarballs do not exist yet — would report drift that is expected and
# turn a successful publish red.
if [[ "$dry_run" -eq 0 && ${#published[@]} -gt 0 ]]; then
  "$root/scripts/check-aur-sync.py" --remote "${published[@]}" || status=1
fi

exit "$status"
