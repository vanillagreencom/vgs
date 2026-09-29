# Distribution

Covers: LICENSE, VERSION, README.md, install.sh, packaging/, bin/lib/self.js, scripts/check-install-tree.sh, scripts/test-install-tree.sh, scripts/test-vgsh-self.sh, scripts/test-install-sh.sh, scripts/smoke/rows/read-only-prefix.sh, flake.nix, flake.lock, scripts/test-flake.sh, .copr/Makefile, scripts/test-fedora-srpm.sh, scripts/fedora-container.sh, scripts/check-packaging.js, scripts/test-check-packaging.js, scripts/arch-packages.sh

This file holds how VGS is licensed, versioned, packaged and installed, and how an install knows it is behind. The channels themselves are added here as they land.

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
- A curl install is replaced by the newest release under `${XDG_DATA_HOME:-~/.local/share}/vgs/.self.lock`. A second update is refused `self=busy` with exit 75. The steps are the curl installer's: download `vgs-X.Y.Z.tar.gz` and `SHA256SUMS` from the release's assets into a staging directory under `…/vgs`, check the archive's sha256 against its one `SHA256SUMS` line, unpack it, require one top directory `vgs-X.Y.Z` whose `VERSION` is `X.Y.Z`, run its own `packaging/install-system.sh`, move the runtime tree to `…/vgs/X.Y.Z`, and rename a new `current` link over the old one. Three trees stay: the new one, the one the command ran from, and the one the running shell was started from, read from its command line (`qs -p <tree>/shell`). So a shell keeps its files until it restarts, even one whose earlier restart was refused. Every other version directory is removed. A running shell whose command line names no tree refuses the update as `shell=unreadable pid=<pid>`. A failure removes the staging directory and leaves `current` as it was.
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

`scripts/test-vgsh-self.sh` builds one fixture tree per method: a clone of a local bare repository, a curl layout under a fixture `XDG_DATA_HOME`, a package tree owned by a stub `pacman` under a fixture Arch os-release bound under `unshare -rm`, and a tree under a fixture `NIX_STORE_DIR`. The newest release is a local release fixture served on 127.0.0.1, and a stub `qs` whose pid sits in the instance lock stands in for a running shell. Its controls are copies of `self.js` that call every tree a checkout, accept a loopback API outside a test run, skip the checksum comparison, or remove the running shell's tree. `scripts/test-vgsh-pkg.js` pins the owner and installed queries.

## Curl installer

`install.sh` at the repository root builds the curl layout. It is also a release asset. Users run `curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vgs/main/install.sh | bash`, with `bash -s -- --version vX.Y.Z`, `--git` or `--uninstall` for the other forms. The script's header states every option, output and exit status.

- The whole script is one brace group: the definition of `main`, then its call with the script's arguments. A download cut short ends inside the group, so bash runs none of it, not even `main` without its arguments.
- It never runs sudo, starts the shell, writes a service unit or edits `hyprland.lua`. It prints the autostart line with the absolute path of `~/.local/bin/vgsh`, because Hyprland's `PATH` may lack `~/.local/bin`.
- Before it writes anything it refuses root, a system other than Linux, a system package and a `~/.local/bin/vgsh` it did not make. A system package is `/usr/bin/vgsh`, or `vgs` or `vgs-git` in the pacman, rpm or dpkg database. `--force` installs beside a system package or replaces the foreign command.
- The floor is `bin/vgsh`'s `preflight_floor` plus the required rows of `config/requirements.json`: Quickshell 0.3.1, Hyprland 0.56, node 18, python3, git and flock, and for a release curl, tar, gzip and sha256sum. Hyprland is read from `Hyprland --version`, which answers with no session running. On a miss the script names every tool below the floor, prints the install command of this system's primary package manager and exits 78.
- The primary manager and its install command follow the primary rows of `shell/Core/PackageManagers.js`, and each tool's package follows `config/requirements.json`. A command the table marks as needing root is printed after `Install them as root:`, with no elevation command. Quickshell and Hyprland have packages for `pacman` and `nix` only: the other managers' own repositories hold no version that meets the floor. On Fedora they come from the two COPRs [§ Third-party COPRs](#third-party-coprs) names.
- A release is read from `api.github.com`, and every fetch uses `curl --proto =https --tlsv1.2` into a `mktemp -d` directory, with `self.js`'s time and size bounds. The archive must match its one `SHA256SUMS` line. `SHA256SUMS.asc` is checked when the release has one and gpg holds the release key; a signature by any other key refuses. VGS publishes no release key yet, so the script's fingerprint is empty and the check prints `signature=unchecked reason=no-release-key`.
- Only a verified archive reaches `…/vgs`. Under `.self.lock` the script unpacks it in a `.self-update-*` staging directory, installs it with its own `packaging/install-system.sh`, moves the runtime tree to `…/vgs/X.Y.Z`, renames a new `current` link over the old one and links `~/.local/bin/vgsh`. A version already current is `ok up-to-date`, and a version directory that exists but is not current is refused as `target=exists`. The script removes no version directory; `vgsh self update` prunes them.
- `--git` clones `main` with no hook, prompt or askpass into a staging directory and renames it to `…/vgs/git`. A second `--git` is refused `git=exists`: `vgsh self update` fast-forwards the clone.
- `--uninstall` removes the version directories, `current`, `git`, the staging directories and the command link it made. It keeps `${XDG_CONFIG_HOME:-~/.config}/vgs`, `${XDG_STATE_HOME:-~/.local/state}/vgs`, a foreign command, any other file in `…/vgs` and `.self.lock`, whose inode a concurrent writer may already hold open. It refuses while the running shell was started from a tree under `…/vgs`, and, unless `--force`, a clone holding changes, a stash, or commits on `HEAD` or a local branch that no remote-tracking branch holds.
- `VGS_RELEASE_API` replaces the API base only in a test run, and only with a `file://` base, which then becomes the one protocol curl may use.

`scripts/test-install-sh.sh` runs the script under `env -i` with a fixture home against a `file://` release fixture, and with a fixture os-release bound over `/etc/os-release` under `unshare -rm` for the floor rows. Its drift rows hold the floor and package tables to `bin/vgsh` and `config/requirements.json`, and the printed install command to `vgsh pkg detect` and `vgsh pkg plan` on eleven distributions. The truncation row cuts at every line end, every 97th byte and every byte of the last 256. Its controls are copies of `install.sh` with one rule removed each: the `main` wrapper, the brace group around its call, the checksum comparison, the `SHA256SUMS` line count, the tag check, the archive layout, the lock, the root, operating-system and system-package refusals, the foreign-command refusal, each uninstall guard, the kept lock, the signing key match, a floor figure, a package name and the manager order.

## Arch packages

- `packaging/arch/vgs/` is the release package and `packaging/arch/vgs-git/` the development package, built from `main`. Each holds a `PKGBUILD` and the `.SRCINFO` that `makepkg --printsrcinfo` prints for it. Both are `arch=('any')`, with the licence expression from § Licence. Their `package()` runs `packaging/install-system.sh` with `PREFIX=/usr` and has no `build()`.
- `depends` and `optdepends` are hand-written and identical in both recipes. The depends are Quickshell and Hyprland, the programs the core runs (`bash`, `coreutils`, `util-linux`, `nodejs`, `python`, `git`), and the floating TUIs' `gum` and `xdg-terminal-exec`. A tool with a version floor in the `preflight_floor` table of `bin/vgsh` ([runtime.md § Process](runtime.md#process)) carries that floor as a `>=` constraint: `quickshell>=0.3.1`, `hyprland>=0.56`, `nodejs>=18`. Each optdepend names the feature that needs it after its colon. No recipe conflicts with a notification daemon.
- `vgs` takes the release tarball, `vgs-<version>.tar.gz` of the `v<version>` release, and `pkgver` is `VERSION`'s line. Its `sha256sums` is `SKIP` while the tag `v<pkgver>` does not exist, because no tarball exists to sum. After the release uploads the tarball, the recipe pins its sha256. `scripts/check-packaging.js` refuses `SKIP` once the tag exists.
- `vgs-git` takes `vgs::git+https://github.com/vanillagreencom/vgs.git`. Its `pkgver()` runs the checkout's own `bin/vgsh version` and refuses any output that is not `vgs X.Y.Z.r<N>.g<hash>`, so the package version and `vgsh --version` in that checkout agree (§ Version). It has `makedepends=('git')` and `provides=("vgs=$pkgver")`.
- `vgs` conflicts with v1's `vgs-shell` and `vgs-shell-git`, and `vgs-git` with those two and `vgs`, so pacman offers to remove the installed one. No recipe has `replaces`: the ArchWiki VCS package guidelines say it "generally causes unnecessary problems and should be avoided".
- `scripts/check-packaging.js` holds both recipes to the requirements and to the rules above: § Recipe check.
- `scripts/arch-packages.sh` builds both recipes and installs them in a rootless podman container from `archlinux:latest`, in the `package` area. It builds the working tree as `git add -A` would commit it. It installs a stand-in `vgs-shell` that owns v1's `/usr/bin/vshell`, then `vgs`, then `vgs-git`, each with `pacman -U --ask 4`, which answers yes to the conflict question. It asserts that each install removed the package before it, that `vgsh --version` prints `vgs <VERSION>`, that `/usr/bin/vgsh` links to `../share/vgs/bin/vgsh`, and that `vgs-git` provides `vgs=<pkgver>` with the built commit's hash. Exit 77 names podman missing, a failed image pull or container start, or a failed system update or dependency download. Its header holds the keyed lines.
- Omarchy keeps its PKGBUILDs in the separate `omarchy-pkgs` repository and serves them from its own pacman repository. Its `omarchy dev pkg-test` builds a package from a local checkout with `pkgver()` removed and installs it on the host. VGS keeps both recipes beside the source, publishes them to the AUR and runs no repository of its own. It tests in a throwaway container, so no test changes the host's packages.

## Recipe check

- `scripts/check-packaging.js` is the one offline check of every package recipe in this repository, in the `cli` area. Its header lists every rule and its keyed refusals.
- One reader builds the requirement list. It reads the core list and every shipped plugin's requirements ([requirements.md](requirements.md)) through the manifest judge, and the `preflight_floor` rows of `bin/vgsh` ([runtime.md § Process](runtime.md#process)). A floor row attaches to the requirement whose command is its probe command, or adds one: Quickshell and Hyprland have no requirement entry. A floor makes its requirement required. Its package on a channel is the one the requirement names for that manager, else the row's tool name. A floor bump in `bin/vgsh` fails the check until every channel's recipes follow.
- `CHANNELS` in the checker has one entry per package manager id whose recipes live here: `pacman` for the Arch recipes and `dnf` for the Fedora specs. An entry names its recipes, reads each into hard and soft dependencies, and sets the fields the shared rules read: `managers`, the requirement's package keys it uses; `hardScopes`, whether a required plugin requirement is hard; `exact`, whether the dependency set must equal the requirements' set; `floorExact`, whether a floor constraint must equal the floor or may exceed it; and `epochs`, the non-zero package epochs a floor must carry. Its `rules` hold the channel's own recipe rules, and `freshness` any comparison with generated metadata.
- The shared rules apply to every channel: each requirement's package is a hard or soft dependency as the fields decide, each floored package carries its floor, `exact` refuses a dependency no requirement asks for, and every recipe of a channel declares the same dependencies.
- `pacman` is not `exact`: `optdepends` names optional tools no requirement declares yet. A required plugin requirement may be a soft dependency there. `dnf` is `exact` and `floorExact`, with `nodejs` at epoch 1.
- A new channel is one `CHANNELS` entry beside the others, with its reader, fields, rules and freshness check, and its rows in `ROWS` of `scripts/test-check-packaging.js`. It changes no shared rule and no reader. A channel whose semantics differ adds a field, never a branch on its id.
- `scripts/test-check-packaging.js` plants one defect per rule in a scratch copy. Each row reads its expected values from the copy it edits, so a release step, such as a VERSION bump, a pinned checksum or a raised floor, does not break it.

## Fedora

VGS ships to Fedora in 0.1.x, not 0.1.0, through COPR `vanillagreen/vgs`. The project does not exist yet: on 2026-09-28 the COPR API listed only v1's `vanillagreen/vgs-shell` for the owner. Publication waits for the 0.1.0 release tarball and a passing `scripts/fedora-container.sh`.

### Packages

- `packaging/fedora/vgs.spec` builds `vgs` from the release tarball, `vgs-<VERSION>.tar.gz` of release `v<VERSION>`. Its `Version` is `VERSION`'s line, and its newest `%changelog` entry is that version.
- `packaging/fedora/vgs-git.spec` builds `vgs-git` from a commit of `main`. Its version is `X.Y.Z^<count>.git<hash>`, the RPM form of the describe form `vgsh --version` prints in the same checkout, so `0.1.0.r215.gcffc73` becomes `0.1.0^215.gitcffc73`. RPM sorts `X.Y.Z^<count>` above `X.Y.Z` and below the next release, Fedora's rule for a snapshot after a release. Before the first release tag the count runs from the first commit and falls to 0 at the tag, so `vgs-git` is published only after `v0.1.0` exists; from then on the count only grows.
- `vgs-git` has `Provides: vgs = %{version}` and `Conflicts: vgs`, so dnf keeps one of the two, and a package that needs `vgs` accepts either. Both conflict with v1's `vgs-shell`. Neither obsoletes it: dnf must not swap v1 for v2 without the user asking.
- Both are `BuildArch: noarch`, install through `packaging/install-system.sh` with `PREFIX=/usr`, and run `scripts/check-install-tree.sh` in `%check`. A shipped file missing from the manifest fails the build.
- Fedora's build rewrites `#!/usr/bin/env bash`, `node` and `python3` to absolute interpreter paths, and RPM derives requirements on those interpreters. The manifest check lists files, not their content, so the rewrite passes it.

### Dependencies

- The block between `# begin runtime dependencies` and `# end runtime dependencies` is the same in both specs. `scripts/check-packaging.js` computes its `Requires` and `Recommends` lines from data and fails on a missing, extra or different line (§ Recipe check).
- Each row of the preflight floor in `bin/vgsh` is a `Requires`, with `>=` its floor: `quickshell >= 0.3.1`, `hyprland >= 0.56`, `nodejs >= 1:18`, `python3` and `git`. The package name is the `dnf` name `config/requirements.json` gives the row's probe command, else the row's tool name.
- Every other required entry of `config/requirements.json` and of the shipped plugins' `requirements` is a `Requires` by its `dnf` name: `util-linux-core` for `flock`. Every optional one is a `Recommends`, which dnf installs by default and lets a user remove: `xdg-terminal-exec`, `gum` and `fzf`. A requirement with no `dnf` name has no Fedora line.
- Fedora's `nodejs` packages carry epoch 1, as `nodejs22` 1:22.23.1 does, so the node floor is written `1:18`. Written `18`, it reads as epoch 0, and any epoch-1 node would pass it, 1:16 included. The `epochs` field of the checker's `dnf` channel holds each non-zero epoch and refuses a floor with another, and the container test compares every floor's epoch with the installed package's.
- The Quickshell floor matters on Fedora: Fedora itself ships `quickshell` `0.2.1^git20260209.dacfa9d`, and without `>= 0.3.1` dnf would take it.

### Third-party COPRs

Fedora carries no Quickshell at the floor and no Hyprland at all, so the project depends on two COPRs VGS does not control. `packaging/fedora/copr-project` lists them with the project's chroots.

| COPR | Package | On 2026-09-28 | Risk |
|---|---|---|---|
| `errornointernet/quickshell` | `quickshell` | 0.3.1-2, built 2026-09-27, fedora-43 to rawhide | One maintainer. A late 0.3.x or 0.4 build holds Fedora users back. |
| `sdegler/hyprland` | `hyprland` | 0.56.2-2, built 2026-08-29, fedora-43 to rawhide | One maintainer. The older `solopasha/hyprland` stopped at 0.49.0, below the Lua floor. |

- The versioned `Requires` stop dnf from pairing VGS with an older Quickshell or Hyprland from any repository, and `vgsh run`'s preflight names a floor miss at start.
- The project lists both as `additional_repos`, which reach the build chroot, and as runtime dependencies, which `dnf copr enable vanillagreen/vgs` offers to enable with it. The noarch build itself needs neither.
- A new Fedora release's chroots join the project only after `scripts/fedora-container.sh --image registry.fedoraproject.org/fedora:<N>` passes.

### Source RPMs

- `packaging/fedora/srpm.sh --spec SPEC --outdir DIR` writes a package's source RPM from the checkout it sits in. For `vgs` the checkout must sit at `v<VERSION>`; it downloads the release tarball over HTTPS, or takes `--tarball FILE`, and refuses a tarball whose `vgs-<VERSION>/VERSION` is another version. For `vgs-git` it packs `HEAD` with `git archive` and `gzip -n`, prepends `vgs_version` and `vgs_commit` to a spec copy and appends one `%changelog` entry of the commit's author and UTC date. That date is the build's `SOURCE_DATE_EPOCH`. It refuses a shallow clone, whose commit count is short.
- `.copr/Makefile` is COPR's `make_srpm` entry. COPR runs it as root in a chroot over a clone another user owns, so `srpm.sh` trusts its own checkout through `GIT_CONFIG_*` and keeps any the caller set.

### Validation

- `scripts/validate` runs `scripts/check-packaging.js`, its controls `scripts/test-check-packaging.js`, and `scripts/test-fedora-srpm.sh`, which drives `srpm.sh`, `.copr/Makefile` and the container runner's host side with stub RPM tools, since the host has none.
- `scripts/fedora-container.sh` is the install test. It needs podman and the network, so it runs by hand, not in `validate`, and exits 77 when it cannot run. In a clean `fedora:44` container it enables the listed COPRs, writes the `vgs-git` source RPM through `.copr/Makefile`, tags its scratch clone and writes the `vgs` source RPM from a release-form tarball, rebuilds both as an unprivileged user and fails on any RPM warning. Then it installs `vgs`, checks `vgsh --version`, the `/usr/bin/vgsh` link and `rpm -V`, and runs the preflight twice. `vgsh run` must refuse at `preflight=hyprland have=unknown`, since no Hyprland runs, so the installed Quickshell met its floor. A stand-in `hyprctl` reporting the installed Hyprland package's version lets `vgsh restart` pass the whole floor and refuse at `shell=not-running`. Last it proves that each package refuses to install beside the other as a conflict, and that `--allowerasing` swaps `vgs` for `vgs-git`, which then provides `vgs` at its own version.
- On 2026-09-28 it passed on `fedora:44` with Quickshell 0.3.1-2 and Hyprland 0.56.2-2, for `vgs` 0.1.0 and a `vgs-git` `0.1.0^<count>.git<hash>` snapshot of the change that added it.

### Publication

The owner runs these once with a COPR API token, after 0.1.0 is released:

```bash
copr-cli create vgs --chroot fedora-44-x86_64 --chroot fedora-44-aarch64 \
  --repo copr://errornointernet/quickshell --repo copr://sdegler/hyprland \
  --runtime-repo-dependency copr://errornointernet/quickshell \
  --runtime-repo-dependency copr://sdegler/hyprland
copr-cli add-package-scm vgs --name vgs-git --clone-url https://github.com/vanillagreencom/vgs.git \
  --commit main --spec packaging/fedora/vgs-git.spec --method make_srpm --webhook-rebuild on
copr-cli add-package-scm vgs --name vgs --clone-url https://github.com/vanillagreencom/vgs.git \
  --commit v0.1.0 --spec packaging/fedora/vgs.spec --method make_srpm
copr-cli build-package vgs --name vgs
copr-cli build-package vgs --name vgs-git
```

- Each later release sets `vgs.spec`'s `Version`, `Release` and `%changelog` with `VERSION`, then runs `copr-cli edit-package-scm vgs --name vgs --commit vX.Y.Z` and `copr-cli build-package vgs --name vgs`. The GitHub webhook rebuilds `vgs-git` on every push to `main`.
- A user installs with `sudo dnf copr enable vanillagreen/vgs`, accepting its two dependencies, then `sudo dnf install vgs`.
- Once the first build installs in a clean container from the published project, the README lists Fedora as supported rather than following.

## Omarchy comparison

- Omarchy's user Hyprland file loads `(os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua"`. Its command layer and docs assume `/usr/share/omarchy`, with development overrides through `OMARCHY_PATH`.
- Omarchy installs as a whole distribution. It owns defaults, system package flows, migrations, theme templates and many helper commands under one `/usr/share/omarchy` tree.
- VGS installs one shell tree beside a user's own Hyprland configuration. It writes user state to XDG configuration and state directories, not beside the install tree.
- Omarchy ships no Nix package: at `main` `e332dc9` it has no `flake.nix` and no reference to nixpkgs. The VGS flake follows the nixpkgs conventions for a script package instead.
- Omarchy's development channel is a git checkout at `$OMARCHY_PATH`. `omarchy-update-available` fetches it with a 10 s timeout and counts the commits behind its upstream, and `omarchy-update-dev` runs `git pull --ff-only`. For a package it filters `checkupdates` for `omarchy` or `omarchy-dev`. VGS takes the checkout flow, and supports three more install forms: the `vgs` and `vgs-git` packages, a curl install and a Nix tree. VGS reads `vgs-git`'s commit itself, because an AUR helper reports a `-git` package behind only when its recipe's version changes. A checkout with no upstream is an error in VGS, where Omarchy skips it, so the Updates plugin never shows a silent "up to date".
- VGS uses `/usr/share/vgs` rather than `/usr/lib/vgs` because the shipped payload is architecture-independent scripts, QML, JSON, themes and fonts. It does not use `/etc/xdg/quickshell` because `vgsh` must own the instance lock, version read and install-method root.
- Omarchy is Arch-only. It publishes its packages to its own pacman repository, `pkgs.omarchy.org`, in stable, rc and edge channels (`default/pacman/pacman-*.conf` at `basecamp/omarchy` `main`, read 2026-09-28), and has no Fedora channel. VGS takes the same shape on Fedora: one repository the project owns, COPR `vanillagreen/vgs`, with a release package and a `main` package in place of channels. Unlike Omarchy, VGS does not package its runtime there: v1 co-hosted `quickshell` in COPR `vanillagreen/vgs-shell`, and it went stale at 0.3.0-3, below v1's own floor. So VGS depends on the two third-party COPRs, and its versioned `Requires` catch a lag.
- At `main` `e332dc9`, Omarchy installs as a distribution: `install/omarchy-base.packages` lists the system packages it installs, and its install helpers make system writes through `as_root`, which runs `sudo` for a user (`install/helpers/as-root.sh`). VGS is one shell beside a user's own system, so `install.sh` keeps v1's user-local model: it writes only under the user's home, runs no package manager and prints the command that installs a missing tool instead.
