---
name: vgs-release
description: Cut and publish a VGS release across GitHub and every maintained install channel.
---

# VGS release

1. Set `VERSION`; update matching versions in `quickshell/vshell/VERSION` and `packaging/`.
2. Run `scripts/check-release.sh` and the normal scoped validation from `AGENTS.md`.
3. Commit with `chore(release): prepare vX.Y.Z` on a branch, open a PR, and merge
   it. Not `release:` and not a push to `main`: the commit-msg guard accepts only
   conventional types, and a repository rule requires every change to `main` to
   arrive through a pull request. Then create and push the signed tag `vX.Y.Z`.
4. Verify GitHub Actions publishes both Linux bundles, the source archive, and `SHA256SUMS`.
5. Test `install.sh --version vX.Y.Z --no-start` in a clean temporary HOME.
6. Pin the published checksums. `sha256sums` in `packaging/arch/PKGBUILD`,
   `packaging/arch/.SRCINFO` and `packaging/void/template` can only be the real
   ones once the tag has built, so they land in a follow-up PR that copies them
   from the release's `SHA256SUMS`.
7. Update maintained package channels from `packaging/`: AUR, COPR/RPM, OBS/Debian, Ubuntu Launchpad PPA, Gentoo, Void, and Nix. Ubuntu 26.04 requires both `ppa:avengemedia/danklinux` for Quickshell 0.3.0 and `ppa:vanillagreen/vgs-shell` for VGS. Never claim a channel until its public install command succeeds.
8. Add failed or unavailable channels to release notes; do not silently skip them.
9. Verify README commands against public URLs.

Publishing per channel: `project-skills/skills/vgs-distro-publish/SKILL.md`.
