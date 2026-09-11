# Ubuntu PPA

VGS supports Ubuntu 26.04 LTS through Launchpad:

- `ppa:avengemedia/danklinux` provides stable Quickshell 0.3.0.
- `ppa:vanillagreen/vgs-shell` provides VGS.

Users must enable both PPAs before installing `vgs-shell`.

## Publish a release

1. `release.yml` runs `scripts/publish-ppa.sh` through `publish-ppa.yml`. The script builds a `3.0 (quilt)` source package from the release archive and `packaging/debian/`, versions it `X.Y.Z-1~ubuntu26.04.N` for `resolute`, signs it with the Launchpad PPA signing key, and uploads it. [../DEVELOPMENT.md](../DEVELOPMENT.md) § Publishers names the variables it needs.
2. Wait for both amd64 and arm64 builds to publish.
3. Install `vgs-shell` in a clean Ubuntu 26.04 container with both PPAs enabled and verify `vshell --version` before documenting the release.

Launchpad PPA: <https://launchpad.net/~vanillagreen/+archive/ubuntu/vgs-shell>
