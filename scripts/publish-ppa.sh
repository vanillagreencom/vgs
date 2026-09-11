#!/usr/bin/env bash
# Upload the VERSION source package to the Ubuntu PPA and wait for Launchpad to list it.
#
# Usage: scripts/publish-ppa.sh [--dry-run] [--revision N]
#
# --dry-run: build the unsigned source package, then stop before signing and upload.
# --revision N: upload X.Y.Z-1~ubuntu26.04.N (default 1). Launchpad refuses a
#   version it has seen before, so a second upload of one release needs a higher N.
# -h, --help: print this help.
#
# PPA_SIGNING_KEY_ID names the Launchpad signing key; PPA_SIGNING_PRIVATE_KEY_PASSWORD
# unlocks it. When PPA_SIGNING_PRIVATE_KEY holds an armored secret key, it is imported
# into a throwaway GNUPGHOME; otherwise the key must be in the caller's keyring.
# A version Launchpad already lists as Pending or Published is not uploaded again.
# PPA_ACCEPT_TIMEOUT bounds the wait for Launchpad to list the upload (seconds, default 1200).
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ppa_api="https://api.launchpad.net/1.0/~vanillagreen/+archive/ubuntu/vgs-shell"
series=resolute
series_version=26.04

fail() {
  printf 'publish-ppa: %s\n' "$1" >&2
  [[ -z "${2:-}" ]] || printf '%s\n' "$2" >&2
  exit "${3:-1}"
}

dry_run=0
revision=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --revision)
      [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || fail "usage: --revision needs a positive integer" "" 2
      revision="$2"
      shift
      ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) fail "usage: unknown option $1" "" 2 ;;
  esac
  shift
done

accept_timeout="${PPA_ACCEPT_TIMEOUT:-1200}"
[[ "$accept_timeout" =~ ^[1-9][0-9]*$ ]] || fail "usage: PPA_ACCEPT_TIMEOUT=$accept_timeout" "It must be a positive number of seconds." 2

version="$(cat "$root/VERSION")" || fail "version-unreadable=$root/VERSION"
package_version="$version-1~ubuntu$series_version.$revision"
changelog_version="$(sed -n '1s/^vgs-shell (\([^)]*\)).*/\1/p' "$root/packaging/debian/changelog")" ||
  fail "changelog-unreadable=packaging/debian/changelog"
[[ "$changelog_version" == "$version-1" ]] ||
  fail "changelog-version=$changelog_version" "packaging/debian/changelog does not start at $version-1; the release rename was skipped." 2

if [[ "$dry_run" -eq 0 ]]; then
  [[ -n "${PPA_SIGNING_KEY_ID:-}" ]] || fail "missing-env=PPA_SIGNING_KEY_ID" "Set it to the Launchpad PPA signing key, or pass --dry-run." 2
  [[ -n "${PPA_SIGNING_PRIVATE_KEY_PASSWORD:-}" ]] || fail "missing-env=PPA_SIGNING_PRIVATE_KEY_PASSWORD" "Set it to the signing key's passphrase, or pass --dry-run." 2
fi

# Launchpad keeps every version it accepted. A read failure says nothing about the
# PPA, so it is never taken as "absent".
launchpad_state() {
  local reply
  reply="$(curl -fsS --retry 3 "$ppa_api?ws.op=getPublishedSources&source_name=vgs-shell&exact_match=true&version=$package_version")" || return 1
  jq -er '[.entries[].status] |
    if length == 0 then "absent"
    elif any(. == "Published" or . == "Pending") then "listed"
    else "retired" end' <<<"$reply"
}

state="$(launchpad_state)" || fail "launchpad-unreadable=$ppa_api" "Could not read the PPA's source publications."
case "$state" in
  listed) echo "publish-ppa: vgs-shell $package_version is already in the PPA; nothing to upload."; exit 0 ;;
  retired) fail "version-retired=$package_version" "Launchpad has seen this version before and refuses it again; rerun with --revision $((revision + 1))." ;;
  absent) ;;
  *) fail "launchpad-state=$state" "The PPA query returned a state this script does not handle." ;;
esac

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

archive="vgs-$version-source.tar.gz"
release_url="https://github.com/vanillagreencom/vgs/releases/download/v$version"
curl -fsSL --retry 3 -o "$work/$archive" "$release_url/$archive" || fail "download-failed=$release_url/$archive"
curl -fsSL --retry 3 -o "$work/SHA256SUMS" "$release_url/SHA256SUMS" || fail "download-failed=$release_url/SHA256SUMS"
checksum="$(awk -v name="$archive" '$2 == name' "$work/SHA256SUMS")" || fail "checksum-unreadable=$work/SHA256SUMS"
[[ -n "$checksum" ]] || fail "checksum-missing=$archive" "The release SHA256SUMS has no line for the source archive."
(cd "$work" && sha256sum --quiet -c - <<<"$checksum") || fail "checksum-mismatch=$archive"

cp -- "$work/$archive" "$work/vgs-shell_$version.orig.tar.gz"
tar -xzf "$work/$archive" -C "$work"
source_dir="$work/vgs-$version"
[[ -d "$source_dir" ]] || fail "archive-layout=$archive" "The archive does not unpack to vgs-$version/."
cp -a -- "$root/packaging/debian" "$source_dir/debian"
sed -i "1s/^vgs-shell ($version-1) [^;]*;/vgs-shell ($package_version) $series;/" "$source_dir/debian/changelog"
[[ "$(head -n 1 "$source_dir/debian/changelog")" == "vgs-shell ($package_version) $series;"* ]] ||
  fail "changelog-rewrite-failed=$package_version" "The first changelog line did not take the Ubuntu version and series."

# -nc: dh clean needs debhelper, which a source-only build does not otherwise need.
(cd "$source_dir" && dpkg-buildpackage -S -us -uc -d -nc) || fail "source-build-failed=$package_version"
changes="$work/vgs-shell_${package_version}_source.changes"
[[ -f "$changes" ]] || fail "changes-missing=$changes"

if [[ "$dry_run" -eq 1 ]]; then
  echo "publish-ppa: built vgs-shell $package_version; dry run, so nothing was signed or uploaded."
  exit 0
fi

if [[ -n "${PPA_SIGNING_PRIVATE_KEY:-}" ]]; then
  export GNUPGHOME="$work/gnupg"
  install -d -m 700 -- "$GNUPGHOME"
  gpg --batch --quiet --import <<<"$PPA_SIGNING_PRIVATE_KEY" || fail "key-import-failed=PPA_SIGNING_PRIVATE_KEY"
fi
install -m 600 /dev/null "$work/passphrase"
printf '%s' "$PPA_SIGNING_PRIVATE_KEY_PASSWORD" >"$work/passphrase"
# debsign runs one program to sign; this one hands gpg the passphrase without a prompt.
printf '#!/bin/sh\nexec gpg --batch --pinentry-mode loopback --passphrase-file %q "$@"\n' "$work/passphrase" >"$work/gpg-loopback"
chmod 700 "$work/gpg-loopback"
debsign -p"$work/gpg-loopback" -k"$PPA_SIGNING_KEY_ID" "$changes" || fail "signing-failed=$PPA_SIGNING_KEY_ID"
[[ "$(head -n 1 "$changes")" == "-----BEGIN PGP SIGNED MESSAGE-----" ]] || fail "unsigned-changes=$changes"

cat >"$work/dput.cf" <<'EOF'
[vgs-ppa]
fqdn = ppa.launchpad.net
method = ftp
incoming = ~vanillagreen/ubuntu/vgs-shell/
login = anonymous
allow_unsigned_uploads = 0
EOF
# dput can exit 0 without uploading, so its own success line is required too.
upload_log="$(dput -c "$work/dput.cf" vgs-ppa "$changes" 2>&1)" || fail "upload-failed=$package_version" "$upload_log"
printf '%s\n' "$upload_log"
[[ "$upload_log" == *"Successfully uploaded packages."* ]] || fail "upload-unconfirmed=$package_version" "dput reported no successful upload."

deadline=$((SECONDS + accept_timeout))
while :; do
  state="$(launchpad_state)" || state=unreadable
  if [[ "$state" == listed ]]; then
    echo "publish-ppa: Launchpad lists vgs-shell $package_version; its builds follow."
    exit 0
  fi
  ((SECONDS < deadline)) ||
    fail "not-listed=$package_version state=$state" "Launchpad did not list the upload within ${accept_timeout}s. Its rejection email names the cause."
  sleep 30
done
