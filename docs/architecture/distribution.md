# Distribution

Covers: LICENSE, VERSION, README.md, packaging/, scripts/check-install-tree.sh, scripts/test-install-tree.sh, scripts/smoke/rows/read-only-prefix.sh, flake.nix, flake.lock, scripts/test-flake.sh

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

## Nix

- `flake.nix` exposes `packages.<system>.default` and `apps.<system>.default` for `x86_64-linux` and `aarch64-linux`. The app runs `vgsh`. Users run `nix run github:vanillagreencom/vgs/v<VERSION>`, or add the package to their configuration. There is no Home Manager module until autostart is settled.
- nixpkgs carries Quickshell 0.3.1 and Hyprland 0.56.2, which meet the runtime floor. `flake.lock` pins the `nixos-unstable` nixpkgs revision the package builds against.
- The package is a `stdenvNoCC` derivation. Its install phase calls `packaging/install-system.sh` once with `PREFIX=$out` and an empty `DESTDIR`, adds the runtime `PATH` line below, then runs `scripts/check-install-tree.sh` on `$out`. A tree that differs from `packaging/install-tree.manifest` fails the build. `$out/bin/vgsh` stays the installer's plain link.
- The runtime `PATH` is Quickshell plus one package per row of `config/requirements.json`: each row's `packages.nix` names a nixpkgs attribute. A required row without one fails evaluation, and an optional row without one stays off the `PATH`. Hyprland is not on it, because the session supplies `hyprctl`.
- Every bash script under `$out/share/vgs/bin` sets that `PATH` itself. A wrapper around the `$out/bin/vgsh` link would not reach them: `vgsh restart` has Hyprland exec the resolved `vgsh` path, and `vgsh-tui launch` hands its own path to a terminal. Neither process inherits the caller's environment, and a single-instance terminal starts from a process that was already running. The build adds one line marked `# vgs-nix-path` after each script's leading comment block, which the usage text is read from. The line prefixes the runtime path as one unit, only when `PATH` does not already hold it. The build fails when `vgsh` or `vgsh-tui` lacks the line.
- The fixup phase rewrites the runtime tree's `#!/usr/bin/env` and `#!/bin/bash` lines to the store's bash, node and python3.
- `scripts/test-flake.sh` runs `nix flake check`, `nix build` and `nix run .# -- --version` in the `nixos/nix` container, on a read-only copy of the tracked and untracked files. For `vgsh` and `vgsh-tui`, it checks that the `PATH` line alone resolves `qs` and every requirement command, does not resolve `hyprctl`, and adds itself once. It also checks that each script is its source plus only that line, placed after the comment block. Its controls cut the requirements from the runtime `PATH`, strip the line from a built `vgsh-tui`, narrow the build's insertion to `vgsh`, and plant a manifest entry the installer never writes. The container's nix store is a named podman or docker volume, so later runs reuse the downloads. No container runtime, no image and no route to `cache.nixos.org` each exit 77.

## Omarchy comparison

- Omarchy's user Hyprland file loads `(os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua"`. Its command layer and docs assume `/usr/share/omarchy`, with development overrides through `OMARCHY_PATH`.
- Omarchy installs as a whole distribution. It owns defaults, system package flows, migrations, theme templates and many helper commands under one `/usr/share/omarchy` tree.
- VGS installs one shell tree beside a user's own Hyprland configuration. It writes user state to XDG configuration and state directories, not beside the install tree.
- Omarchy ships no Nix package: at `main` `e332dc9` it has no `flake.nix` and no reference to nixpkgs. The VGS flake follows the nixpkgs conventions for a script package instead.
- VGS uses `/usr/share/vgs` rather than `/usr/lib/vgs` because the shipped payload is architecture-independent scripts, QML, JSON, themes and fonts. It does not use `/etc/xdg/quickshell` because `vgsh` must own the instance lock, version read and install-method root.
