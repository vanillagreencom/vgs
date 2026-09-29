# Distribution

Covers: LICENSE, VERSION, README.md, packaging/install-system.sh, packaging/install-tree.manifest, scripts/check-install-tree.sh, scripts/test-install-tree.sh, scripts/smoke/rows/read-only-prefix.sh, scripts/check-packaging.js, scripts/test-check-packaging.js, scripts/release, scripts/test-release.sh

This file holds how VGS is licensed and versioned, the install tree every channel shares and the check every package recipe passes. Each channel and the install-method judge have their own file:

- [distribution-methods.md](distribution-methods.md): `vgsh self status` and `vgsh self update`, and how an install knows it is behind.
- [distribution-curl.md](distribution-curl.md): `install.sh` and the curl layout.
- [distribution-arch.md](distribution-arch.md): the `vgs` and `vgs-git` Arch recipes and their AUR publication.
- [distribution-fedora.md](distribution-fedora.md): the Fedora specs and COPR `vanillagreen/vgs`.
- [distribution-nix.md](distribution-nix.md): the Nix flake.
- [RELEASING.md](../RELEASING.md): the release flow, `scripts/release` and `scripts/publish-aur.sh`.

## Licence

- `LICENSE` is the MIT licence, `Copyright (c) 2026 VanillaGreen`. MIT is v1's licence and the owner's choice.
- Bundled files keep their own licences, in files beside them. The fonts JetBrains Mono and Inter are under the SIL Open Font License 1.1: `shell/assets/fonts/JetBrainsMono-OFL.txt` and `shell/assets/fonts/InterVariable-OFL.txt`. The Lucide icon data is under ISC: `shell/Ui/icons/LICENSE`.
- The SPDX licence expression of a VGS package is `MIT AND OFL-1.1 AND ISC`.

## Version

- `VERSION` holds the release's version: one line `X.Y.Z` of digits and dots, ending in a newline. A release tag is `v` followed by that line.
- `vgsh --version` and `vgsh version` print `vgs <version>`. They read `VERSION` beside `bin/`, so an exported tree and every package channel print the same version without asking a package manager. They need no shell running and never contact it.
- In a git checkout they print the describe form, `vgs X.Y.Z.r<N>.g<hash>`. With a release tag reachable from `HEAD`, `X.Y.Z` is the newest such tag's version and `N` counts the commits since it: `git describe --long --tags` over tags of `v`, digits and dots only, so `v1-beta` and `nightly` never count. With no release tag, `X.Y.Z` is `VERSION`'s and `N` counts every commit. The hash has 7 hex digits, more only when 7 are ambiguous, whatever the repository's `core.abbrev` says. The form follows the AUR `-git` package version convention, `git describe --long --tags --abbrev=7`, so it agrees with the `vgs-git` package's version and grows with every commit after the first tag.
- The tree is a checkout only when git's top level for it is the tree itself. An exported tree unpacked inside another repository never reports that repository's commits. `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and `GIT_COMMON_DIR` from the caller are unset first, so they cannot point the check at another repository. Without git the tree is not a checkout.
- `vgsh version --json` prints one line `{"version":"<VERSION>","describe":"X.Y.Z.r<N>.g<hash>"}`, with `describe` null outside a checkout. `version` is always `VERSION`'s line. The planned consumers are `vgsh self status` and the Updates plugin.
- Refusals exit 1 with a keyed first line on stderr and nothing on stdout: `version=missing` or `version=malformed path=<file>`, `tag=<tag> reason=not-a-version` for a tag of `v`, digits and dots that is not `v<X.Y.Z>`, and `git=describe` or `git=rev-list path=<tree>` for a failed git call, a checkout with no commit included. An extra argument exits 2. `scripts/test-vgsh-version.sh` holds the rows.
- Omarchy's `omarchy-version` prints `dev (<hash>)` for a checkout and the pacman package's version otherwise. VGS reads its own `VERSION` instead, so every channel prints one version, and a checkout adds the commit distance.

## Install tree

- `packaging/install-system.sh` is the one installer for system packages, the flake and the curl installer. Call it with `DESTDIR` and `PREFIX`. Package recipes use `PREFIX=/usr`, and a user-local installer can use `PREFIX=$HOME/.local`.
- The runtime tree is `$PREFIX/share/vgs/`. It contains `bin/`, `shell/`, `config/`, `themes/` and `VERSION`.
- `$PREFIX/bin/vgsh` is a symlink to `../share/vgs/bin/vgsh`. `vgsh` resolves its root from the real script path, so the symlink starts the installed tree and reads that tree's `VERSION`.
- The installer copies `README.md` to `$PREFIX/share/doc/vgs/README.md` and `LICENSE` to `$PREFIX/share/licenses/vgs/LICENSE`.
- The installer drops developer markdown under `shell/`: `AGENTS.md`, `CLAUDE.md` and `README.md`. The runtime never reads those files. The root `README.md` still installs as documentation.
- The installer refuses an existing non-empty runtime tree. It also refuses an existing `$PREFIX/bin/vgsh` unless it is the expected symlink. An upgrade uses a fresh `DESTDIR`, or removes the old runtime tree and command path before installing.
- The installer writes only under `DESTDIR`. It must run from a read-only source tree, such as the Nix store.
- `scripts/check-install-tree.sh DESTDIR PREFIX` compares the installed files and symlinks with `packaging/install-tree.manifest`. Missing entries and extra entries fail with keyed lines. After a legitimate shipped file is added, install into a scratch `DESTDIR`, then run `scripts/check-install-tree.sh --write DESTDIR PREFIX` and commit the manifest update.
- `scripts/test-install-tree.sh` proves the installer, the manifest checker, the `vgsh` symlink, the markdown drop, target freshness and the `--write` path. Its controls plant missing, extra, wrong-link, stale-target, enumerator-failure and shell-markdown defects.
- The nested smoke's `read-only-prefix` row installs into its sandbox, verifies the pristine tree against the manifest, replaces installed `themes/targets` with the sandbox's fixture targets, runs `chmod -R a-w` on the staged prefix, restarts the shell from `$PREFIX/bin/vgsh`, runs `vgsh theme apply vgs` from the installed command, checks the installed shell log, and compares the installed tree before and after. A root-owned prefix is not available in the test, so a user-owned non-writable tree is the stand-in. Any attempted write either fails on mode bits or changes the snapshot.

## Recipe check

- `scripts/check-packaging.js` is the one offline check of every package recipe in this repository, in the `cli` area. Its header lists every rule and its keyed refusals.
- One reader builds the requirement list. It reads the core list and every shipped plugin's requirements ([requirements.md](requirements.md)) through the manifest judge, and the `preflight_floor` rows of `bin/vgsh` ([runtime.md § Process](runtime.md#process)). A floor row attaches to the requirement whose command is its probe command, or adds one: Quickshell and Hyprland have no requirement entry. A floor makes its requirement required. Its package on a channel is the one the requirement names for that manager, else the row's tool name. A floor bump in `bin/vgsh` fails the check until every channel's recipes follow.
- `CHANNELS` in the checker has one entry per package manager id whose recipes live here: `pacman` for the Arch recipes and `dnf` for the Fedora specs. An entry names its recipes, reads each into hard and soft dependencies, and sets the fields the shared rules read: `managers`, the requirement's package keys it uses; `hardScopes`, whether a required plugin requirement is hard; `exact`, whether the dependency set must equal the requirements' set; `floorExact`, whether a floor constraint must equal the floor or may exceed it; and `epochs`, the non-zero package epochs a floor must carry. Its `rules` hold the channel's own recipe rules, and `freshness` any comparison with generated metadata.
- The shared rules apply to every channel: each requirement's package is a hard or soft dependency as the fields decide, each floored package carries its floor, `exact` refuses a dependency no requirement asks for, and every recipe of a channel declares the same dependencies.
- `pacman` is not `exact`: `optdepends` names optional tools no requirement declares yet. A required plugin requirement may be a soft dependency there. `dnf` is `exact` and `floorExact`, with `nodejs` at epoch 1.
- A new channel is one `CHANNELS` entry beside the others, with its reader, fields, rules and freshness check, and its rows in `ROWS` of `scripts/test-check-packaging.js`. It changes no shared rule and no reader. A channel whose semantics differ adds a field, never a branch on its id.
- `scripts/test-check-packaging.js` plants one defect per rule in a scratch copy. Each row reads its expected values from the copy it edits, so a release step, such as a VERSION bump, a pinned checksum or a raised floor, does not break it.

## Omarchy comparison

- Omarchy's user Hyprland file loads `(os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua"`. Its command layer and docs assume `/usr/share/omarchy`, with development overrides through `OMARCHY_PATH`.
- Omarchy installs as a whole distribution. It owns defaults, system package flows, migrations, theme templates and many helper commands under one `/usr/share/omarchy` tree.
- VGS installs one shell tree beside a user's own Hyprland configuration. It writes user state to XDG configuration and state directories, not beside the install tree.
- VGS uses `/usr/share/vgs` rather than `/usr/lib/vgs` because the shipped payload is architecture-independent scripts, QML, JSON, themes and fonts. It does not use `/etc/xdg/quickshell` because `vgsh` must own the instance lock, version read and install-method root.
