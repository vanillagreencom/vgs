#!/usr/bin/env bash
# Publish packaging/gentoo/ to the VanillaGreen Gentoo overlay.
#
# The overlay is a separate repository that pulls nothing from here, so an
# ebuild fix reaches Gentoo users only when something pushes it. Nothing did:
# the overlay served 0.1.0 with none of the packaging fixes while every other
# channel had them, exactly as the AUR did before publish-aur.sh existed
# (VGS-5, VGS-53, VGS-204). A stale overlay emerges and installs perfectly
# well, so nothing complains — which is why this has to be checked rather than
# assumed.
#
# Usage:
#   scripts/publish-gentoo.sh --dry-run   # read-only, shows the diff
#   scripts/publish-gentoo.sh             # commits and pushes
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
category=gui-apps
package=vgs-shell

dry_run=0
check=0
for argument in "$@"; do
  case "$argument" in
    --dry-run) dry_run=1 ;;
    # Like --dry-run, but drift is a FAILURE rather than a report. This is the
    # scheduled alarm: a stale overlay emerges and installs perfectly well, so
    # the only way it surfaces is something failing on purpose.
    --check) dry_run=1; check=1 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "publish-gentoo: unknown option $argument" >&2; exit 2 ;;
  esac
done

# A read-only run must not need a key. --dry-run and --check clone over public
# HTTPS unless the caller names a remote, so they work on a fresh runner — the
# workflow deliberately skips SSH setup for them, and an SSH clone there would
# fail host-key verification before it could show anything. Publishing keeps SSH.
if [[ -n "${VGS_GENTOO_OVERLAY_URL:-}" ]]; then
  overlay_url="$VGS_GENTOO_OVERLAY_URL"
elif [[ "$dry_run" -eq 1 ]]; then
  overlay_url="https://github.com/vanillagreencom/gentoo-overlay.git"
else
  overlay_url="git@github.com:vanillagreencom/gentoo-overlay.git"
fi

version="$(cat "$root/VERSION")"
ebuild="$root/packaging/gentoo/$package-$version.ebuild"
if [[ ! -f "$ebuild" ]]; then
  echo "publish-gentoo: $ebuild does not exist; the release rename was skipped." >&2
  exit 2
fi

archive="vgs-$version-source.tar.gz"
url="https://github.com/vanillagreencom/vgs/releases/download/v$version/$archive"

# Same three outcomes as publish-aur.sh, and for the same reason: an ebuild
# whose SRC_URI does not exist yet must DEFER without failing the run, while a
# check that could not be made must FAIL rather than pass as "not released".
#   0 published   3 deferred, release absent   1/2 failed
#
# The defer code is DISTINCT (3) rather than 1. Sharing 1 with clone, commit and
# push failures is what lets a publish that delivered nothing report success:
# the caller cannot tell "the release is not out yet" from "the push failed",
# and it will forgive both. That is the silent non-delivery this script exists
# to prevent, so its own exit codes must not reintroduce it.
rc=0
code="$(curl -sSL --head --max-time 30 --retry 2 -o /dev/null -w '%{http_code}' "$url")" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "publish-gentoo: cannot reach $url (curl exit $rc), so whether the release exists is unknown." >&2
  echo "publish-gentoo: refusing to treat an unreachable host as an unreleased version." >&2
  exit 2
fi
case "$code" in
  2??) ;;
  404|410)
    echo "publish-gentoo: v$version is not released yet ($url returned $code); nothing published." >&2
    exit 3
    ;;
  *)
    echo "publish-gentoo: $url returned $code, which is neither a working source nor a missing one." >&2
    exit 2
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The Manifest pins the release archive by size and two digests, so it can only
# be written from the archive's actual bytes. Downloading ~1.1 GiB is the cost of
# not inventing them.
echo "publish-gentoo: fetching $archive to compute its Manifest digests"
curl -fsSL "$url" -o "$tmp/$archive"
size="$(stat -c%s "$tmp/$archive")"
blake2b="$(b2sum "$tmp/$archive" | cut -d' ' -f1)"
sha512="$(sha512sum "$tmp/$archive" | cut -d' ' -f1)"

clone="$tmp/overlay"
if ! git clone --quiet "$overlay_url" "$clone"; then
  echo "publish-gentoo: cannot clone $overlay_url; NOTHING was published" >&2
  exit 1
fi

dir="$clone/$category/$package"
mkdir -p "$dir"
# Remove other versions' ebuilds: the overlay serves one release, and leaving the
# previous ebuild beside the new one keeps offering it to `emerge`.
find "$dir" -maxdepth 1 -name "$package-*.ebuild" -delete
install -m 644 "$ebuild" "$dir/$package-$version.ebuild"
printf 'DIST %s %s BLAKE2B %s SHA512 %s\n' "$archive" "$size" "$blake2b" "$sha512" > "$dir/Manifest"

git -C "$clone" add --all
if git -C "$clone" diff --quiet --cached --exit-code; then
  echo "publish-gentoo: the overlay is already what this repo holds"
  exit 0
fi

echo "publish-gentoo: overlay changes"
git -C "$clone" --no-pager diff --cached --stat

if [[ "$dry_run" -eq 1 ]]; then
  if [[ "$check" -eq 1 ]]; then
    echo "publish-gentoo: the overlay has DRIFTED from this repo; publish it." >&2
    exit 1
  fi
  echo "publish-gentoo: --dry-run, so nothing was pushed"
  exit 0
fi

identity=()
if ! git -C "$clone" config user.email >/dev/null; then
  identity=(
    -c "user.name=${GENTOO_COMMIT_NAME:-VGS packaging}"
    -c "user.email=${GENTOO_COMMIT_EMAIL:-packaging@vanillagreen}"
  )
fi
git -C "$clone" "${identity[@]}" commit --quiet \
  -m "$category/$package: version bump to $version" \
  -m "Synced from vanillagreencom/vgs $(git -C "$root" rev-parse --short HEAD)."
git -C "$clone" push --quiet origin HEAD
echo "publish-gentoo: pushed $package-$version"
