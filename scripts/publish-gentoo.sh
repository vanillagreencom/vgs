#!/usr/bin/env bash
# Publish packaging/gentoo to the VanillaGreen Gentoo overlay.
#
# Usage: scripts/publish-gentoo.sh [--dry-run | --check]
#
# --dry-run: show the proposed changes without pushing.
# --check: inspect changes and fail when the overlay differs.
# -h, --help: print this help.
#
# A normal run commits and pushes the updated ebuild and Manifest.
# Read-only modes use public HTTPS; publishing uses SSH by default.
# VGS_GENTOO_OVERLAY_URL selects a different remote.
# An absent release archive defers publication.
# The Manifest size and digests come from the downloaded archive.
# The overlay retains only the ebuild for VERSION.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
category=gui-apps
package=vgs-shell

dry_run=0
check=0
for argument in "$@"; do
  case "$argument" in
    --dry-run) dry_run=1 ;;
    # --check fails on drift so an installable but stale overlay remains detectable.
    --check) dry_run=1; check=1 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "publish-gentoo: unknown option $argument" >&2; exit 2 ;;
  esac
done

# Use public HTTPS for read-only modes so they do not require an SSH key or host-key setup.
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

# Return 3 when the release is absent, 0 when published, and 1/2 on failure.
# Deferral must remain distinct from clone or push failure so non-delivery cannot pass silently.
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

# The Manifest size and digests require the actual release archive bytes.
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
# The overlay serves one release. Retained ebuilds keep older versions available to emerge.
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
