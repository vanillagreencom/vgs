# Distribution

Covers: LICENSE, VERSION, README.md, packaging/, bin/lib/self.js, scripts/check-install-tree.sh, scripts/test-install-tree.sh, scripts/test-vgsh-self.sh, scripts/smoke/rows/read-only-prefix.sh, flake.nix, flake.lock, scripts/test-flake.sh

This file holds how VGS is licensed, versioned, packaged and installed, and how an install knows it is behind. The channels themselves are added here as they land.

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

## Install methods

`vgsh self status` names how this tree was installed and whether its channel offers something newer. `vgsh self update` updates the tree where VGS owns it. `bin/lib/self.js` is the one judge of the method and of `behind`; `bin/vgsh` makes every git call and hands it the facts. The command's header in `bin/vgsh` states every output and refusal.

### The four methods

The judge tries each method in this order, on the real path of the tree beside `bin/`:

| Method | The tree is | `current` | `latest` | Behind while |
|---|---|---|---|---|
| `checkout` | the top level of its own git checkout, as `vgsh version` decides | `HEAD` in the describe form | the upstream commit in the describe form, after a fetch | the upstream holds commits `HEAD` lacks |
| `nix` | inside the Nix store: `$NIX_STORE_DIR`, else `/nix/store` | `VERSION` | the newest release | the newest release is newer |
| `curl` | the directory `${XDG_DATA_HOME:-~/.local/share}/vgs/current` resolves to, a directory of `…/vgs` | `VERSION` | the newest release | the newest release is newer |
| `package` | owned, through its `VERSION`, by the primary package manager, as the package `vgs` or `vgs-git` | the package's installed version | `vgs`: the newest release; `vgs-git`: the commit `main` points at | `vgs`: the newest release is newer; `vgs-git`: `main` is not the commit its version names |

- Any other tree is refused as `method=unknown path=<root>`. So is a package other than `vgs` and `vgs-git`, as `package=<name> manager=<id> reason=not-vgs`.
- The owner query is the package layer's: `vgsh pkg owner <path>` runs the primary manager's owner and installed queries from `shell/Core/PackageManagers.js` ([packages.md § Queries](packages.md#queries)). pacman, apt and dnf answer both; xbps and emerge name the owner only.
- A `vgs-git` version ends in the commit it was built from: the AUR form `X.Y.Z.r<N>.g<hash>` and the COPR form `X.Y.Z^<N>.git<hash>`. Any other `vgs-git` version is refused as `reason=not-a-version`.
- A checkout's fetch is `plugin outdated`'s fetch ([manager.md § Outdated](manager.md#outdated)): no hook, no prompt, no askpass, no `FETCH_HEAD`, ended at 10 s. `main`'s commit for `vgs-git` is `git ls-remote https://github.com/vanillagreencom/vgs.git refs/heads/main` under the same rules. The package recipe builds from that URL.
- The newest release is `GET https://api.github.com/repos/vanillagreencom/vgs/releases/latest`, ended at 10 s. Its tag must be `v<X.Y.Z>`. A repository with no release is `release=none`.

### Output

- `vgsh self status --json` prints one line `{ version, method, package, current, latest, behind, error }`. `version` is `VERSION`'s line. `package` is `vgs`, `vgs-git` or null. `behind` is a boolean.
- The text form prints the same fields that are set, as `key=value` words on one line.
- A step that fails does not fail the command. Its keyed refusal line becomes `error`, `latest` and `behind` are null, and the exit status is 0. The fields read before the failure stay: a checkout whose fetch fails still names its `current`.
- The planned consumer is the Updates plugin's check, which reads the JSON form beside the other update sources.

### Update

- A checkout fast-forwards to its upstream, as `plugin update` does, with no diff and no question: VGS is the program the user runs, not third-party code. A modified checkout, a missing upstream and an upstream that rewrote its history are refused with `plugin update`'s keys.
- A curl install is replaced by the newest release under `${XDG_DATA_HOME:-~/.local/share}/vgs/.self.lock`. A second update is refused `self=busy` with exit 75. The steps are the curl installer's: download `vgs-X.Y.Z.tar.gz` and `SHA256SUMS` from the release's assets into a staging directory under `…/vgs`, check the archive's sha256 against its one `SHA256SUMS` line, unpack it, require one top directory `vgs-X.Y.Z` whose `VERSION` is `X.Y.Z`, run its own `packaging/install-system.sh`, move the runtime tree to `…/vgs/X.Y.Z`, and rename a new `current` link over the old one. The tree that was current stays, so a running shell keeps its files until it restarts; every other version directory is removed. A failure removes the staging directory and leaves `current` as it was.
- A download is https, at most 128 MiB for the archive, and ended at 120 s. VGS publishes no release signing key yet, so the update checks the sha256 alone.
- A package and a Nix tree are refused, `method=package package=<name> manager=<id>` and `method=nix`. The package manager or the flake owns the tree, and `vgsh self update` changes neither.
- After an update, a running shell restarts from the updated tree's `vgsh`. The restart's status becomes the command's. With no shell running, the last line is `shell=not-running`.
- `VGS_RELEASE_API` replaces the API base only in a test run, and only with `http://127.0.0.1:<port>`. Any other value is refused, so no environment redirects a real update.

### Curl layout

This is the layout the curl installer builds and `vgsh self update` keeps:

- `${XDG_DATA_HOME:-~/.local/share}/vgs/X.Y.Z/` holds one release's runtime tree: `bin shell config themes VERSION`, as `packaging/install-system.sh` lays it out under `share/vgs`.
- `…/vgs/current` is a symlink to `X.Y.Z`, relative, replaced by rename only.
- `~/.local/bin/vgsh` is a symlink to `…/vgs/current/bin/vgsh`. `vgsh` resolves its root from its real path, so the running tree is the version directory.
- `…/vgs/.self.lock` is the lock every writer of `…/vgs` holds with `flock`. `…/vgs/.self-update-*` is a staging directory; one found under the lock is a dead run's and is removed.
- `install.sh --git` clones into `…/vgs/git`. That tree is a checkout, not a curl install.

### Verification

`scripts/test-vgsh-self.sh` builds one fixture tree per method: a clone of a local bare repository, a curl layout under a fixture `XDG_DATA_HOME`, a package tree owned by a stub `pacman` under a fixture Arch os-release bound under `unshare -rm`, and a tree under a fixture `NIX_STORE_DIR`. The newest release is a local release fixture served on 127.0.0.1. Its controls are copies of `self.js` that call every tree a checkout, accept a loopback API outside a test run, or skip the checksum comparison. `scripts/test-vgsh-pkg.js` pins the owner and installed queries.

## Omarchy comparison

- Omarchy's user Hyprland file loads `(os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua"`. Its command layer and docs assume `/usr/share/omarchy`, with development overrides through `OMARCHY_PATH`.
- Omarchy installs as a whole distribution. It owns defaults, system package flows, migrations, theme templates and many helper commands under one `/usr/share/omarchy` tree.
- VGS installs one shell tree beside a user's own Hyprland configuration. It writes user state to XDG configuration and state directories, not beside the install tree.
- Omarchy ships no Nix package: at `main` `e332dc9` it has no `flake.nix` and no reference to nixpkgs. The VGS flake follows the nixpkgs conventions for a script package instead.
- Omarchy's development channel is a git checkout at `$OMARCHY_PATH`. `omarchy-update-available` fetches it with a 10 s timeout and counts the commits behind its upstream, and `omarchy-update-dev` runs `git pull --ff-only`. For a package it filters `checkupdates` for `omarchy` or `omarchy-dev`. VGS takes the checkout flow, and supports three more install forms: the `vgs` and `vgs-git` packages, a curl install and a Nix tree. VGS reads `vgs-git`'s commit itself, because an AUR helper reports a `-git` package behind only when its recipe's version changes. A checkout with no upstream is an error in VGS, where Omarchy skips it, so the Updates plugin never shows a silent "up to date".
- VGS uses `/usr/share/vgs` rather than `/usr/lib/vgs` because the shipped payload is architecture-independent scripts, QML, JSON, themes and fonts. It does not use `/etc/xdg/quickshell` because `vgsh` must own the instance lock, version read and install-method root.
