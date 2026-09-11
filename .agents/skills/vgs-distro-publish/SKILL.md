---
name: vgs-distro-publish
description: Publish a cut VGS release to every distribution channel, and verify each from its public install command.
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Publishing VGS to distributions

Run after the tag builds and the published-checksum update merges.

1. Read `packaging/DEVELOPMENT.md` for channel commands, credentials and artifact verification.
2. Publish the recipes from `packaging/`. Use `scripts/publish-aur.sh` for AUR, `scripts/publish-gentoo.sh` for the Gentoo overlay, and `scripts/publish-ppa.sh` for the Ubuntu PPA when the release run's `ppa` job did not publish.
3. Verify the requested version through each channel's public install command from `packaging/README.md`. Verify published artifacts as described in the development guide; a successful build alone is insufficient.
4. Record every failed, unavailable or untested channel in the release notes. A recipe-only channel is not a published package.
5. Verify the README install commands against the public locations before declaring the release complete.
