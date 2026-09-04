# Package maintenance

This guide holds package-generation and publishing mechanics. Release sequencing belongs to [../.agents/skills/vgs-release/SKILL.md](../.agents/skills/vgs-release/SKILL.md); channel completion belongs to [../.agents/skills/vgs-distro-publish/SKILL.md](../.agents/skills/vgs-distro-publish/SKILL.md).

## Dependency declarations

`config/vshell/dependencies.json` declares feature commands. `packaging/optional-packages.json` supplies package mappings, required commands, unsupported mappings and notification conflicts. `scripts/gen-package-metadata.py` verifies the recipes; its `--write` mode updates generated blocks. Do not hand-edit those blocks.

Default UI commands require hard dependencies. Optional features must report missing tools without failing the shell. The generator reports unsupported mappings with their recorded reasons.

Fedora uses `Suggests` to avoid installing optional compositors and login managers by default. Void has no weak-dependency list; `INSTALL.msg` and `vshell deps status` identify optional tools. Terminal choice belongs to the helper's existing resolver.

## Bundles and catalog

`install-system.sh` accepts `VGS_THEME_BUNDLE=core|extras|all`. Each package recipe declares its bundle. `scripts/check-package-assets.sh` and `scripts/check-release.sh` check package and archive contents.

The core archive includes the download catalog and catalog previews. The extras archive includes optional themes and icons. `scripts/gen-theme-catalog.py` owns catalog generation and release-pin checks.

## Signing

Use the release signing key `C23A00D650F28E947AD8EEBA6CB466C12AA86B98`, configured as `user.signingkey`. Always supply a tag message. Headless signing requires a cached PIN in gpg-agent; unlock it from a terminal when needed. If signing is unavailable, an annotated tag is permitted only with the unsigned status recorded in the release notes.

## Publishers

AUR and Gentoo are separate publishing repositories. Changes here reach users through `scripts/publish-aur.sh` and `scripts/publish-gentoo.sh`; edits made directly in those repositories are overwritten.

The AUR publisher defers missing release assets or mismatched published checksums. Other network and authentication failures fail the publish. It needs `AUR_SSH_PRIVATE_KEY` and `AUR_SSH_KNOWN_HOSTS`; verify the stored host-key fingerprint against Arch's published fingerprint. The Gentoo publisher requires overlay commit rights.

## Manual channel commands

Replace version placeholders before use. Keep build work in a temporary directory outside the source checkout. The OBS and Ubuntu commands prepare publication artifacts, not installation checks.

```bash
# Gentoo overlay
scripts/publish-gentoo.sh                     # needs overlay commit rights
scripts/publish-gentoo.sh --check             # drift; also runs weekly in CI

# Fedora COPR
copr-cli build vanillagreen/vgs-shell packaging/fedora/vgs-shell.spec

# openSUSE + Debian 13 (one OBS package, three build targets)
osc checkout home:vanillagreen vgs-shell -o /tmp/obs
( cd /tmp/obs                                 # subshell: this cd must not leak
  # update _service (version + source sha256), vgs-shell.spec, and the .dsc +
  # debian.tar.xz built from packaging/debian/
  osc commit -m "Update to vX.Y.Z" )
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


Configure `vgs-ppa` in `~/.dput.cf` with `fqdn = ppa.launchpad.net` and `incoming = ~vanillagreen/ubuntu/vgs-shell/`. Check dput's output as well as its status; an unknown host can report success. Ubuntu signing uses the package signing key, separate from the release tag key.

## Artifact verification

The checks below compare the requested version with published repository metadata. They supplement the public installation checks required by the publishing skill. AUR RPC metadata can lag its git repository; a successful COPR or OBS build can precede repository publication.

```bash
V=$(cat VERSION); bad=0

# AUR — recipes match this repo byte for byte
scripts/check-aur-sync.py --remote || bad=1

# Fedora COPR — the chroot's DNF metadata, which is what dnf resolves against.
# A build can succeed while repository regeneration lags or fails.
for c in fedora-43-x86_64 fedora-43-aarch64 fedora-44-x86_64 fedora-44-aarch64; do
  u="https://download.copr.fedorainfracloud.org/results/vanillagreen/vgs-shell/$c"
  pri=$(curl -sL "$u/repodata/repomd.xml" | grep -oE 'repodata/[a-f0-9]+-primary\.xml\.[a-z]+' | head -1)
  # Bound to the vgs-shell package: a bare version grep matches any entry, so a
  # current vgs-shell-assets would vouch for a missing or stale base package.
  curl -sL "$u/$pri" | { zstd -dc 2>/dev/null || zcat; } | python3 -c '
import sys, xml.etree.ElementTree as ET
ns = {"c": "http://linux.duke.edu/metadata/common"}
want = sys.argv[1]
root = ET.fromstring(sys.stdin.read())
ok = any(p.find("c:name", ns).text == "vgs-shell"
         and p.find("c:version", ns).get("ver") == want
         for p in root.findall("c:package", ns))
sys.exit(0 if ok else 1)' "$V" && echo "$c ok" || { echo "$c NOT $V"; bad=1; }
done

# openSUSE + Debian — the repository index, not osc results
for r in openSUSE_Tumbleweed/x86_64 openSUSE_Slowroll/x86_64; do
  curl -s "https://download.opensuse.org/repositories/home:/vanillagreen/$r/" \
    | grep -q "vgs-shell-$V-" && echo "$r ok" || { echo "$r NOT $V"; bad=1; }
done
curl -s https://download.opensuse.org/repositories/home:/vanillagreen/Debian_13/amd64/ \
  | grep -q "vgs-shell_$V-" && echo "Debian_13 ok" || { echo "Debian_13 NOT $V"; bad=1; }

# Ubuntu — the published BINARIES, per architecture. A source can be accepted
# and published while a build fails, and then nobody can install it.
for a in amd64 arm64; do
  curl -s "https://api.launchpad.net/1.0/~vanillagreen/+archive/ubuntu/vgs-shell?ws.op=getPublishedBinaries&binary_name=vgs-shell&version=$V-1~ubuntu26.04.1&status=Published" \
    | grep -q "/$a" && echo "PPA $a ok" || { echo "PPA $a NOT $V"; bad=1; }
done

# Gentoo — the overlay's ebuild
scripts/publish-gentoo.sh --check || bad=1

# Nix — BUILD the flake. Evaluating .version only reads back the VERSION file
# the derivation was handed, so it passes on a package that cannot build.
F="github:vanillagreencom/vgs/v$V"
nix build --no-link "$F#packages.x86_64-linux.default" || bad=1
# flake.nix declares aarch64-linux too. Its derivation is evaluated here; a full
# aarch64 BUILD needs an aarch64 builder — run it there when one exists.
# `nix flake check` evaluates every output. It does NOT instantiate
# homeManagerModules.default against a real Home Manager configuration, so a
# broken module body can still reach users; that needs home-manager as a flake
# input and is not done here.
nix eval --raw "$F#packages.aarch64-linux.default.drvPath" >/dev/null || bad=1
nix flake check "$F" || bad=1

# A per-channel report that always exits 0 is how a stale channel gets claimed
# as shipped. Every miss above sets bad; this is the block's answer.
exit "$bad"
```


The Nix ARM evaluation does not prove an ARM build. The flake check does not instantiate the Home Manager module with a real configuration. Record these limits if suitable builders or environments are unavailable.
