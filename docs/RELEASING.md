# Releasing

The maintainer cuts every release from their own machine, with their own gpg key, GitHub login and AUR SSH key. VGS has no CI workflow for releases or package publication: [D040](decisions/D040-one-shared-install-tree.md). Two scripts do the work. Their headers, which `--help` prints, state every refusal, output line and exit status.

- `scripts/release X.Y.Z` makes the GitHub release `vX.Y.Z` from the pushed tag: the source archive `vgs-X.Y.Z.tar.gz`, `install.sh`, `SHA256SUMS` and its detached signature `SHA256SUMS.asc`, written to `dist/`.
- `scripts/publish-aur.sh vgs vgs-git` pushes the recipes under `packaging/arch/` to the AUR. It holds `vgs` back until the release asset's sha256 is the one the recipe pins.

Both take `--dry-run`, which makes every check and changes nothing outside `dist/`. `scripts/test-release.sh` and `scripts/test-publish-aur.sh` prove them with stub `gh`, `gpg` and `ssh`, in the `cli` area of `scripts/validate`.

## Before the first release

- Set `release_key` in `install.sh` to the full upper-case fingerprint of the release signing key, the `fpr` value `gpg --list-keys --with-colons` prints. The release signs `SHA256SUMS` with that key, and the curl installer verifies the signature against the same value. `scripts/release` refuses while it is empty.
- Log in with `gh auth login`, as an account that may create releases in `vanillagreencom/vgs`.
- Register the SSH public key of the AUR account that maintains `vgs` and `vgs-git`. The publisher reads the private key from `AUR_SSH_KEY_FILE` and nothing under `~/.ssh`. It pins the AUR's host keys in `packaging/aur-known-hosts`.

## Versions

- `VERSION` holds the release's SemVer version, and the tag is `v` followed by it: [distribution.md § Version](architecture/distribution.md#version).
- While VGS is at 0.x, a minor bump marks a breaking change to `shell.json`, the plugin API, the manifest or the theme package format. A patch bump marks fixes only.
- Plugin manifest versions change independently of `VERSION`.
- The archive name carries no architecture. v1's `install.sh`, still served from the `v1` branch, looks for `vgs-X.Y.Z-linux-<arch>.tar.gz` in the newest release, so it stops with an error rather than unpacking v2 over a v1 install.

## Flow

1. Prepare the version. `scripts/check-packaging.js` refuses a recipe whose version differs from `VERSION`, so every file below moves to `X.Y.Z` in the same commit:
   - `VERSION`: the one line `X.Y.Z`.
   - `packaging/arch/vgs/PKGBUILD`: `pkgver=X.Y.Z`, `pkgrel=1` and `sha256sums=('SKIP')`. The sum stays `SKIP` until the archive exists; a sum left from the previous release passes the check but makes `scripts/publish-aur.sh` hold `vgs` back.
   - `packaging/arch/vgs/.SRCINFO`: regenerated from that PKGBUILD, which the check compares byte for byte.
   - `packaging/fedora/vgs.spec`: `Version: X.Y.Z`, `Release: 1%{?dist}`, and a new first `%changelog` entry whose header line ends in `- X.Y.Z-1`.
   - The version's changelog entry.

   ```bash
   printf '%s\n' X.Y.Z >VERSION
   # packaging/arch/vgs/PKGBUILD: pkgver=X.Y.Z, pkgrel=1, sha256sums=('SKIP')
   (cd packaging/arch/vgs && makepkg --printsrcinfo > .SRCINFO)
   # packaging/fedora/vgs.spec: Version, Release and the new %changelog entry
   node scripts/check-packaging.js
   ```

2. Run `scripts/validate --full` once. A release is an explicit full sweep. Then commit on `main` and push.
3. Tag and push the tag:

   ```bash
   git tag -s vX.Y.Z -m "VGS X.Y.Z"
   git push origin vX.Y.Z
   ```

4. Make the release. The last lines name the archive's sha256.

   ```bash
   scripts/release --dry-run X.Y.Z
   scripts/release X.Y.Z
   ```

5. Pin that sha256 in the `vgs` recipe, check it and push it. `scripts/check-packaging.js` refuses `SKIP` once the tag exists.

   ```bash
   # packaging/arch/vgs/PKGBUILD: sha256sums=('<the release: sha256 value>')
   (cd packaging/arch/vgs && makepkg --printsrcinfo > .SRCINFO)
   node scripts/check-packaging.js
   git commit -am "packaging: pin the vgs X.Y.Z tarball" && git push origin main
   ```

6. Publish both recipes. Exit 75 means a package was held back; its `deferred` line names the reason.

   ```bash
   scripts/publish-aur.sh --dry-run vgs vgs-git
   AUR_SSH_KEY_FILE=~/.ssh/aur scripts/publish-aur.sh vgs vgs-git
   ```

7. Rebuild the Fedora package: [distribution-fedora.md § Publication](architecture/distribution-fedora.md#publication).
8. Verify every channel, as below.

## Verification

Each check reads the published channel, never the checkout.

```bash
# The release's assets and their signature.
gh release download vX.Y.Z --repo vanillagreencom/vgs --dir /tmp/vgs-X.Y.Z
(cd /tmp/vgs-X.Y.Z && sha256sum -c SHA256SUMS && gpg --verify SHA256SUMS.asc SHA256SUMS)

# The AUR's view of both packages.
curl -fsS 'https://aur.archlinux.org/rpc/v5/info?arg[]=vgs&arg[]=vgs-git'

# Each AUR package, built and installed in a clean Arch container.
for pkg in vgs vgs-git; do
  podman run --rm docker.io/library/archlinux:latest bash -euc '
    pacman -Syu --noconfirm --needed base-devel git sudo
    useradd -m builder
    echo "builder ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/builder
    runuser -u builder -- bash -c "cd && git clone https://aur.archlinux.org/$1.git && cd $1 && makepkg -si --noconfirm"
    vgsh --version' _ "$pkg"
done

# The curl installer, as a user, on Arch.
podman run --rm docker.io/library/archlinux:latest bash -euc '
  pacman -Syu --noconfirm --needed quickshell hyprland nodejs python git curl
  useradd -m user
  runuser -u user -- bash -c "curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vgs/main/install.sh | bash && ~/.local/bin/vgsh --version"'

# The flake at the tag.
podman run --rm -e NIX_CONFIG='experimental-features = nix-command flakes' docker.io/nixos/nix:2.35.2 \
  nix run github:vanillagreencom/vgs/vX.Y.Z -- --version
```

Every command prints `vgs X.Y.Z`: an installed tree is not a checkout, so `vgs-git` prints its `VERSION` too. Then run `vgsh run` from each install inside the nested sandbox: [validation-smoke.md](architecture/validation-smoke.md).

## Omarchy comparison

At `basecamp/omarchy` `main` `e332dc9`, the repository holds no release or publish script. Omarchy builds its packages in the separate `omarchy-pkgs` repository and serves them from its own pacman repository. VGS keeps its recipes beside the source, so one checkout both tags the release and publishes the recipes that build it.
