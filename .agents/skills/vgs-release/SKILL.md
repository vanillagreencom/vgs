---
name: vgs-release
description: Cut and publish a VGS release across GitHub and every maintained install channel.
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# VGS release

1. Set `VERSION` and matching runtime and package versions. Update the theme catalog release pin with `scripts/gen-theme-catalog.py --ref vX.Y.Z --write`.
2. Run `scripts/check-release.sh` and the scoped validation from the root `AGENTS.md`.
3. Merge the release preparation pull request, then create and push the signed tag: `git tag -s vX.Y.Z -m "vX.Y.Z"`. Read `packaging/DEVELOPMENT.md` for signing setup and the unsigned-tag exception.
4. Verify the release contains both Linux bundles, the source archive and `SHA256SUMS`. Test `install.sh --version vX.Y.Z --no-start` in a clean temporary HOME.
5. Copy the published checksums into the Arch and Void recipes in a follow-up pull request.
6. Run `.agents/skills/vgs-distro-publish/SKILL.md` for every maintained distribution channel.
