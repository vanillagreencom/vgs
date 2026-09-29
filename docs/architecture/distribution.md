# Distribution

Covers: LICENSE, VERSION, scripts/test-vgsh-version.sh

This file holds how VGS is licensed and versioned. How it is packaged and installed is added here as those parts land.

## Licence

- `LICENSE` is the MIT licence, `Copyright (c) 2026 VanillaGreen`. MIT is v1's licence and the owner's choice.
- Bundled files keep their own licences, in files beside them. The fonts JetBrains Mono and Inter are under the SIL Open Font License 1.1: `shell/assets/fonts/JetBrainsMono-OFL.txt` and `shell/assets/fonts/InterVariable-OFL.txt`. The Lucide icon data is under ISC: `shell/Ui/icons/LICENSE`.
- The SPDX licence expression of a VGS package is `MIT AND OFL-1.1 AND ISC`.

## Version

- `VERSION` holds the release's version: one line `X.Y.Z` of digits and dots, ending in a newline. A release tag is `v` followed by that line.
- `vgsh --version` and `vgsh version` print `vgs <version>`. They read `VERSION` beside `bin/`, so an exported tree and every package channel print the same version without asking a package manager. They need no shell running and never contact it.
- In a git checkout they print the describe form, `vgs X.Y.Z.r<N>.g<hash>`. With a release tag reachable from `HEAD`, `X.Y.Z` is the newest such tag's version and `N` counts the commits since it: `git describe --long --tags` over tags of `v`, digits and dots only, so `v1-beta` and `nightly` never count. With no release tag, `X.Y.Z` is `VERSION`'s and `N` counts every commit. The form follows the AUR `-git` package version convention, so it agrees with the `vgs-git` package's version and grows with every commit after the first tag.
- The tree is a checkout only when git's top level for it is the tree itself. An exported tree unpacked inside another repository never reports that repository's commits. `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and `GIT_COMMON_DIR` from the caller are unset first, so they cannot point the check at another repository. Without git the tree is not a checkout.
- `vgsh version --json` prints one line `{"version":"<VERSION>","describe":"X.Y.Z.r<N>.g<hash>"}`, with `describe` null outside a checkout. `version` is always `VERSION`'s line. The planned consumers are `vgsh self status` and the Updates plugin.
- Refusals exit 1 with a keyed first line on stderr and nothing on stdout: `version=missing` or `version=malformed path=<file>`, `tag=<tag> reason=not-a-version` for a tag of `v`, digits and dots that is not `v<X.Y.Z>`, and `git=describe` or `git=rev-list path=<tree>` for a failed git call, a checkout with no commit included. An extra argument exits 2. `scripts/test-vgsh-version.sh` holds the rows.
- Omarchy's `omarchy-version` prints `dev (<hash>)` for a checkout and the pacman package's version otherwise. VGS reads its own `VERSION` instead, so every channel prints one version, and a checkout adds the commit distance.
