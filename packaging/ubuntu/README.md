# Ubuntu PPA

VGS supports Ubuntu 26.04 LTS through Launchpad:

- `ppa:avengemedia/danklinux` provides stable Quickshell 0.3.0.
- `ppa:vanillagreen/vgs-shell` provides VGS.

Users must enable both PPAs before installing `vgs-shell`.

## Publish a release

1. Build a Debian `3.0 (quilt)` source package from the deterministic GitHub source archive and `packaging/debian/`.
2. Use an Ubuntu revision such as `0.1.0-1~ubuntu26.04.1` and distribution `resolute`.
3. Sign the `.dsc`, `.buildinfo`, and `_source.changes` files with the Launchpad PPA signing key stored in 1Password.
4. Upload the signed source package:

   ```bash
   dput ppa:vanillagreen/vgs-shell vgs-shell_*_source.changes
   ```

5. Wait for both amd64 and arm64 builds to publish.
6. Install `vgs-shell` in a clean Ubuntu 26.04 container with both PPAs enabled and verify `vshell --version` before documenting the release.

Launchpad PPA: <https://launchpad.net/~vanillagreen/+archive/ubuntu/vgs-shell>
