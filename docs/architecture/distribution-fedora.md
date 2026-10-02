# Fedora

Covers: packaging/fedora/, .copr/Makefile, scripts/test-fedora-srpm.sh, scripts/fedora-container.sh

VGS ships to Fedora in 0.1.x, not 0.1.0, through COPR `vanillagreen/vgs`. On 2026-10-02 the COPR API listed only that project for the owner: it has the chroots and repos of `packaging/fedora/copr-project` and the packages `vgs` and `vgs-git`, and no build has run. v1's `vanillagreen/vgs-shell` is deleted. The first builds wait for the `v0.1.0` tag, the 0.1.0 release tarball and a passing `scripts/fedora-container.sh`.

## Packages

- `packaging/fedora/vgs.spec` builds `vgs` from the release tarball, `vgs-<VERSION>.tar.gz` of release `v<VERSION>`. Its `Version` is `VERSION`'s line, and its newest `%changelog` entry is that version.
- `packaging/fedora/vgs-git.spec` builds `vgs-git` from a commit of `main`. Its version is `X.Y.Z^<count>.git<hash>`, the RPM form of the describe form `vgsh --version` prints in the same checkout, so `0.1.0.r215.gcffc73` becomes `0.1.0^215.gitcffc73`. RPM sorts `X.Y.Z^<count>` above `X.Y.Z` and below the next release, Fedora's rule for a snapshot after a release. Before the first release tag the count runs from the first commit and falls to 0 at the tag, so `vgs-git` is published only after `v0.1.0` exists; from then on the count only grows.
- `vgs-git` has `Provides: vgs = %{version}` and `Conflicts: vgs`, so dnf keeps one of the two, and a package that needs `vgs` accepts either. Both conflict with v1's `vgs-shell`. Neither obsoletes it: dnf must not swap v1 for v2 without the user asking.
- Both are `BuildArch: noarch`, install through `packaging/install-system.sh` with `PREFIX=/usr`, and run `scripts/check-install-tree.sh` in `%check`. A shipped file missing from the manifest fails the build.
- Fedora's build rewrites `#!/usr/bin/env bash`, `node` and `python3` to absolute interpreter paths, and RPM derives requirements on those interpreters. The manifest check lists files, not their content, so the rewrite passes it.

## Dependencies

- The block between `# begin runtime dependencies` and `# end runtime dependencies` is the same in both specs. `scripts/check-packaging.js` computes its `Requires` and `Recommends` lines from data and fails on a missing, extra or different line ([distribution.md § Recipe check](distribution.md#recipe-check)).
- Each row of the preflight floor in `bin/vgsh` is a `Requires`, with `>=` its floor: `quickshell >= 0.3.1`, `hyprland >= 0.56`, `nodejs >= 1:18`, `python3` and `git`. The package name is the `dnf` name `config/requirements.json` gives the row's probe command, else the row's tool name.
- Every other required entry of `config/requirements.json` and of the shipped plugins' `requirements` is a `Requires` by its `dnf` name: `util-linux-core` for `flock` and `util-linux` for `setpriv`, which Fedora ships only in the full package. Every optional one is a `Recommends`, which dnf installs by default and lets a user remove. A requirement with no `dnf` name has no Fedora line.
- The shared [recipe check](distribution.md#recipe-check) also requires the declared runtime library packages.
- Fedora's `nodejs` packages carry epoch 1, as `nodejs22` 1:22.23.1 does, so the node floor is written `1:18`. Written `18`, it reads as epoch 0, and any epoch-1 node would pass it, 1:16 included. The `epochs` field of the checker's `dnf` channel holds each non-zero epoch and refuses a floor with another, and the container test compares every floor's epoch with the installed package's.
- The Quickshell floor matters on Fedora: Fedora itself ships `quickshell` `0.2.1^git20260209.dacfa9d`, and without `>= 0.3.1` dnf would take it.

## Third-party COPRs

Fedora carries no Quickshell at the floor and no Hyprland at all, so the project depends on two COPRs VGS does not control. `packaging/fedora/copr-project` lists them with the project's chroots.

| COPR | Package | On 2026-09-28 | Risk |
|---|---|---|---|
| `errornointernet/quickshell` | `quickshell` | 0.3.1-2, built 2026-09-27, fedora-43 to rawhide | One maintainer. A late 0.3.x or 0.4 build holds Fedora users back. |
| `sdegler/hyprland` | `hyprland` | 0.56.2-2, built 2026-08-29, fedora-43 to rawhide | One maintainer. The older `solopasha/hyprland` stopped at 0.49.0, below the Lua floor. |

- The versioned `Requires` stop dnf from pairing VGS with an older Quickshell or Hyprland from any repository, and `vgsh run`'s preflight names a floor miss at start.
- The project lists both as `additional_repos`, which reach the build chroot, and as runtime dependencies, which `dnf copr enable vanillagreen/vgs` offers to enable with it. The noarch build itself needs neither.
- A new Fedora release's chroots join the project only after `scripts/fedora-container.sh --image registry.fedoraproject.org/fedora:<N>` passes.

## Source RPMs

- `packaging/fedora/srpm.sh --spec SPEC --outdir DIR` writes a package's source RPM from the checkout it sits in. For `vgs` the checkout must sit at `v<VERSION>`; it downloads the release tarball over HTTPS, or takes `--tarball FILE`, and refuses a tarball whose `vgs-<VERSION>/VERSION` is another version. For `vgs-git` it packs `HEAD` with the release tarball builder ([distribution.md § Release tarball](distribution.md#release-tarball)), prepends `vgs_version` and `vgs_commit` to a spec copy and appends one `%changelog` entry of the commit's author and UTC date. That date is the build's `SOURCE_DATE_EPOCH`. It refuses a shallow clone, whose commit count is short.
- `.copr/Makefile` is COPR's `make_srpm` entry. COPR runs it as root in a chroot over a clone another user owns, so `srpm.sh` trusts its own checkout through `GIT_CONFIG_*` and keeps any the caller set.

## Validation

- `scripts/validate` runs `scripts/check-packaging.js`, its controls `scripts/test-check-packaging.js`, and `scripts/test-fedora-srpm.sh`, which drives `srpm.sh`, `.copr/Makefile` and the container runner's host side with stub RPM tools, since the host has none.
- `scripts/fedora-container.sh` is the install test. It needs podman and the network, so it runs by hand, not in `validate`, and exits 77 when it cannot run. On the host it packs the release tarball of `HEAD` with the release's builder. In a clean `fedora:44` container it enables the listed COPRs, writes the `vgs-git` source RPM through `.copr/Makefile`, tags its scratch clone and writes the `vgs` source RPM from that tarball, rebuilds both as an unprivileged user and fails on any RPM warning. Then it installs `vgs`, checks `vgsh --version`, the `/usr/bin/vgsh` link and `rpm -V`, and runs the preflight twice. `vgsh run` must refuse at `preflight=hyprland have=unknown`, since no Hyprland runs, so the installed Quickshell met its floor. A stand-in `hyprctl` reporting the installed Hyprland package's version lets `vgsh restart` pass the whole floor and refuse at `shell=not-running`. Last it proves that each package refuses to install beside the other as a conflict, and that `--allowerasing` swaps `vgs` for `vgs-git`, which then provides `vgs` at its own version.
- On 2026-09-28 it passed on `fedora:44` with Quickshell 0.3.1-2 and Hyprland 0.56.2-2, for `vgs` 0.1.0 and a `vgs-git` `0.1.0^<count>.git<hash>` snapshot of the change that added it.

## Publication

These commands, run with a COPR API token, set up the project and its two packages. They also recreate it:

```bash
copr-cli create vgs --chroot fedora-44-x86_64 --chroot fedora-44-aarch64 \
  --repo copr://errornointernet/quickshell --repo copr://sdegler/hyprland \
  --runtime-repo-dependency copr://errornointernet/quickshell \
  --runtime-repo-dependency copr://sdegler/hyprland
copr-cli add-package-scm vgs --name vgs-git --clone-url https://github.com/vanillagreencom/vgs.git \
  --commit main --spec packaging/fedora/vgs-git.spec --method make_srpm --webhook-rebuild on
copr-cli add-package-scm vgs --name vgs --clone-url https://github.com/vanillagreencom/vgs.git \
  --commit v0.1.0 --spec packaging/fedora/vgs.spec --method make_srpm
```

Once the three conditions of the opening paragraph hold, the owner runs the first builds:

```bash
copr-cli build-package vgs --name vgs
copr-cli build-package vgs --name vgs-git
```

- `vgs-git` has webhook rebuild on, but on 2026-10-02 the GitHub repository does not yet send the project's webhook. The owner adds it in the repository's webhook settings only after the `v0.1.0` tag exists. `packaging/fedora/srpm.sh` builds `vgs-git` without a release tag, so a webhook added earlier publishes a pre-tag `vgs-git` on the next push to `main`. Its count sorts above the first builds after the tag ([§ Packages](#packages)), and a user who installed it gets no update until the count passes it.
- Each later release sets `vgs.spec`'s `Version`, `Release` and `%changelog` with `VERSION`, then runs `copr-cli edit-package-scm vgs --name vgs --commit vX.Y.Z` and `copr-cli build-package vgs --name vgs`. The GitHub webhook, added after the `v0.1.0` tag, rebuilds `vgs-git` on every push to `main`.
- A user installs with `sudo dnf copr enable vanillagreen/vgs`, accepting its two dependencies, then `sudo dnf install vgs`.
- Once the first build installs in a clean container from the published project, the README lists Fedora as supported rather than following.

## Omarchy comparison

- Omarchy is Arch-only. It publishes its packages to its own pacman repository, `pkgs.omarchy.org`, in stable, rc and edge channels (`default/pacman/pacman-*.conf` at `basecamp/omarchy` `main`, read 2026-09-28), and has no Fedora channel. VGS takes the same shape on Fedora: one repository the project owns, COPR `vanillagreen/vgs`, with a release package and a `main` package in place of channels. Unlike Omarchy, VGS does not package its runtime there: v1 co-hosted `quickshell` in the deleted COPR `vanillagreen/vgs-shell`, where it went stale at 0.3.0-3, below v1's own floor. So VGS depends on the two third-party COPRs, and its versioned `Requires` catch a lag.
