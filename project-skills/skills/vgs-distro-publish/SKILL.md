---
name: vgs-distro-publish
description: Publish a cut VGS release to every distribution channel, and verify each from its public install command.
---

# Publishing VGS to distributions

Run after the tag builds and `chore(release): pin published vX.Y.Z assets` merges.
Recipes live in `packaging/`; channel status and install commands in
`packaging/README.md`.

Never claim a channel until its public install command succeeds.

## Automatic

| Channel | Trigger |
|---|---|
| AUR `vgs-shell`, `vgs-shell-assets`, `vgs-shell-git` | `publish-aur.yml` on `packaging/arch/**` and after a tag |
| Nix | flake follows the tag |

`publish-aur.sh` defers a package whose release assets 404, or whose declared
`sha256sums` disagree with the release's `SHA256SUMS`. Both are expected before the
pin lands. Any other non-zero is a real failure.

## Manual

```bash
# Gentoo overlay
scripts/publish-gentoo.sh                     # needs overlay commit rights
scripts/publish-gentoo.sh --check             # drift; also runs weekly in CI

# Fedora COPR
copr-cli build vanillagreen/vgs-shell packaging/fedora/vgs-shell.spec

# openSUSE + Debian 13 (one OBS package, three build targets)
osc checkout home:vanillagreen vgs-shell -o /tmp/obs
cd /tmp/obs                                   # osc commit needs the working copy
# update _service (version + source sha256), vgs-shell.spec, and the .dsc +
# debian.tar.xz built from packaging/debian/
osc commit -m "Update to vX.Y.Z"
osc results home:vanillagreen vgs-shell

# Ubuntu PPA — debian/ must sit at the source root, and the signing key has a
# passphrase, so a person runs debsign.
R=$(git rev-parse --show-toplevel)              # before any cd
curl -fsSLO https://github.com/vanillagreencom/vgs/releases/download/vX.Y.Z/vgs-X.Y.Z-source.tar.gz
cp vgs-X.Y.Z-source.tar.gz vgs-shell_X.Y.Z.orig.tar.gz
tar -xzf vgs-X.Y.Z-source.tar.gz && cd vgs-X.Y.Z
cp -a "$R/packaging/debian" debian
sed -i '1s/.*/vgs-shell (X.Y.Z-1~ubuntu26.04.1) resolute; urgency=medium/' debian/changelog
dpkg-buildpackage -S -us -uc -d -nc           # -nc: dh clean needs debhelper
debsign -k <KEYID> ../vgs-shell_*_source.changes
dput vgs-ppa ../vgs-shell_*_source.changes    # host config in ~/.dput.cf
```

`dput` on Arch ships no `ppa:` shorthand and exits 0 when the host is unknown —
define `vgs-ppa` (`fqdn = ppa.launchpad.net`, `incoming = ~vanillagreen/ubuntu/vgs-shell/`)
and read its output, not its status.

Void ships a recipe only — Void has no Quickshell 0.3.0.

## Verify

Assert the NEW version, not merely that a package exists — an older release still
published makes every loose check pass. Read the published artefact, not the build
status: COPR and OBS report success for a build whose packages are not yet in the
repository, and the AUR's RPC index lags its git by minutes.

```bash
V=$(cat VERSION); bad=0

# AUR — recipes match this repo byte for byte
scripts/check-aur-sync.py --remote

# Fedora COPR — every declared chroot
for c in fedora-43-x86_64 fedora-43-aarch64 fedora-44-x86_64 fedora-44-aarch64; do
  b=$(curl -s "https://download.copr.fedorainfracloud.org/results/vanillagreen/vgs-shell/$c/" \
      | grep -oE '[0-9]{7,8}-vgs-shell' | tail -1)
  curl -s "https://download.copr.fedorainfracloud.org/results/vanillagreen/vgs-shell/$c/$b/results.json" \
    | grep -q "\"version\": \"$V\"" && echo "$c ok" || { echo "$c NOT $V"; bad=1; }
done

# openSUSE + Debian — the repository index, not osc results
for r in openSUSE_Tumbleweed/x86_64 openSUSE_Slowroll/x86_64; do
  curl -s "https://download.opensuse.org/repositories/home:/vanillagreen/$r/" \
    | grep -q "vgs-shell-$V-" && echo "$r ok" || { echo "$r NOT $V"; bad=1; }
done
curl -s https://download.opensuse.org/repositories/home:/vanillagreen/Debian_13/amd64/ \
  | grep -q "vgs-shell_$V-" && echo "Debian_13 ok" || { echo "Debian_13 NOT $V"; bad=1; }

# Ubuntu — the newest Published source
curl -s "https://api.launchpad.net/1.0/~vanillagreen/+archive/ubuntu/vgs-shell?ws.op=getPublishedSources" \
  | grep -q "\"source_package_version\": \"$V-1~" && echo "PPA ok" || { echo "PPA NOT $V"; bad=1; }

# Gentoo — the overlay's ebuild
scripts/publish-gentoo.sh --check || bad=1

# Nix — the public flake at the tag actually evaluates
nix eval --raw "github:vanillagreencom/vgs/v$V#packages.x86_64-linux.default.version" || bad=1

# A per-channel report that always exits 0 is how a stale channel gets claimed
# as shipped. Every miss above sets bad; this is the block's answer.
exit "$bad"
```

Name any channel that did not ship in the release notes.
