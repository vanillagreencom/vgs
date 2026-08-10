# Package channels

VGS installs under `/usr/lib/vshell`, exposes `/usr/bin/vshell`, and installs the user service. Mutable state remains in `~/.config/vshell`.

## Activation

Native packages install `vshell.service` but do not enable or start it automatically, and cannot:
a systemd *user* unit is enabled per account, and package scriptlets run as root with no reliable
way to know which accounts want VGS. `systemctl --global enable` would opt every account on the
machine in, which is not a decision a package gets to make. Every channel therefore prints the
activation step instead:

```bash
systemctl --user enable --now vshell.service
```

| Channel | Where the message comes from |
|---|---|
| Arch | `arch/vgs-shell.install`, `arch/vgs-shell-git/vgs-shell-git.install` (declared by `install=` inside the `package_vgs-shell*` functions) |
| Debian | `debian/vgs-shell.postinst` |
| Fedora / openSUSE / OBS | `%post` in `fedora/vgs-shell.spec` |
| Gentoo | `pkg_postinst` in `gentoo/vgs-shell-0.1.0.ebuild` |
| Void | `void/INSTALL.msg`, installed alongside `void/template` in `srcpkgs/vgs-shell/` |
| Nix / Home Manager | the Home Manager module owns the unit |
| `install.sh` | enables and starts the unit unless `--no-start` is passed |

## Dependencies

`config/vshell/dependencies.json` is the source of truth for which commands back which VGS feature
group, and `optional-packages.json` maps those commands to distribution package names and marks
which of them are *required*. `scripts/gen-package-metadata.py` joins the two and rewrites the
generated blocks in **every** shipped channel's recipe — hard dependencies in all six, plus the
optional list in the four that have a weak-dependency mechanism:

| Channel | Hard dependencies | Optional list |
|---|---|---|
| Arch, Debian, Fedora, Gentoo | generated | generated |
| Void | generated | none — xbps has no weak dependencies; `INSTALL.msg` and `vshell deps status` cover them |
| Nix | generated into the `wrapProgram` PATH | none — the wrapper is a PATH, not a package relation |
| Ubuntu | n/a — the PPA builds from `packaging/debian` | n/a |


```bash
scripts/gen-package-metadata.py            # verify the recipes match the manifest
scripts/gen-package-metadata.py --write    # regenerate them
```

The verify mode runs in `scripts/check-release.sh` and in CI, and a command added to the manifest
without a package mapping fails the check rather than silently going unadvertised. Do not hand-edit
anything between the `BEGIN`/`END GENERATED` markers, or the generated `RDEPEND` in the ebuild.

`optdepends` and `Suggests` are advisory: no package manager installs them by default. A command
behind a default bar button or modal therefore has to be a **hard** dependency, or a stock install
ships UI that reports missing tools — which is what the screenshot button did on a fresh
`vgs-shell-git` (VGS-53). The `"required"` section of `optional-packages.json` names those commands;
everything else stays optional and must stay absent-tolerant in the UI. `tailscale` is the reference
case: a network daemon with its own account and system service never becomes a dependency, it just
has to say plainly in-module that it is not installed.

A required command with no package on one of those channels **fails** the generator. Leaving it out
quietly would ship, one channel down, exactly the stock install the list exists to prevent, so it has
to be waived by name in `"required".unsupported` with a reason — and every run prints the waivers it
honoured. Three are live today: `hyprpicker` on Gentoo (no ebuild in `::gentoo`, so capture and OCR
under Hyprland report it missing there), and `sudo` and `visudo` on Nix (`pkgs.sudo` on the wrapper's
PATH would shadow the setuid wrapper in `/run/wrappers/bin` with a binary that cannot elevate).
The run prints them all, so that list is the authority if this paragraph ever falls behind.

The same rule covers the notification-daemon conflicts. `org.freedesktop.Notifications` is a
first-come, first-served bus name, so every channel has to declare that a second daemon is not
supported (VGS-56) — and every channel was declaring something slightly different. The one list is
the `"conflicts"` section: Gentoo's blockers are generated into its `RDEPEND`, the other channels
declare conflicts in shapes too file-specific to template and are **verified** against it — by
reading the declaration, not by searching the file, so a daemon named in a comment does not count —
and a daemon a channel has no package for must be waived with a reason exactly like a required
command. Five waivers are live: `notification-daemon` on Gentoo and Void (neither has such a virtual
package; the daemons are blocked by name), `dunst` on Arch and Debian (both provide the
`notification-daemon` virtual, which is already conflicted), and `swaync` on Gentoo (not packaged).

Verification covers every file that ships a declaration, which is not one per channel: Arch alone has
four — both PKGBUILDs and both `.SRCINFO`s — and those are the files published to the AUR.

The channel list itself is checked too. A directory under `packaging/` that is neither generated nor
declared unGenerated with a reason fails the run. That check exists because Void was hand-maintained
and silently skipped: it kept `depends="quickshell jq python3"` through two rounds of packaging
fixes, still shipping the VGS-53 defect after every generated channel was correct.

Terminals are the open exception. Eight are listed as alternatives, packaging cannot express "any
one of these", and none is required — so a fresh install has no terminal for password prompts. That
needs an `xdg-terminal-exec` style resolver rather than an eight-way optional list.

Fedora uses `Suggests:` rather than `Recommends:` because dnf installs weak `Recommends` by default,
and the list includes a login manager (`greetd`) and both supported compositors. Void has no
weak-dependency mechanism, so its optional tools are covered by `INSTALL.msg` and
`vshell deps status` only.

## The AUR is a publishing target, not a source

The AUR keeps its own git repository per package and pulls nothing from this one — `source=('git+…')`
tracks the *source tree*, never the recipe. So `packaging/arch/` reaches users only when something
pushes it, and twice nothing did: `VGS_THEME_BUNDLE` (VGS-5) and all 38 `optdepends` (VGS-53) were
both fixed here and closed while every AUR install kept the old behaviour.

```bash
scripts/check-aur-sync.py            # PKGBUILD vs .SRCINFO, offline; runs in CI
scripts/check-aur-sync.py --remote   # also diffs aur.archlinux.org; needs network
scripts/publish-aur.sh --dry-run     # what a publish would change
scripts/publish-aur.sh               # publish (needs AUR commit rights)
```

The offline check runs on every PR. The remote check and the push belong to
`.github/workflows/publish-aur.yml`, which publishes both packages whenever a packaging change lands
on main, is called again by `release.yml` after a tag, and runs a weekly drift check because a stale
AUR package builds and installs perfectly well.

`vgs-shell` points its `source_*` at release tarballs, so publishing it before those exist would
leave `yay -S vgs-shell` unable to download its source. `publish-aur.sh` checks the URLs rather than
assuming: it publishes the package when they resolve — so a dependency fix that leaves `pkgver`
alone reaches stable users the day it lands — and defers only that package, with an explanation,
between a version bump and its tag. Only a `404`/`410` defers. A DNS failure, a timeout, a `403` or
a `5xx` **fails the run**: "not released yet" and "the runner could not reach GitHub" look identical
if you only ask whether `curl` succeeded, and quietly skipping the publish for the second is the
silent non-delivery this whole section exists to end. Each run then verifies exactly what it published; a package it
deferred is not verified, because reporting expected drift as a failure would make the delivery
signal worthless.

Publishing needs two pieces of configuration, and the workflow **fails** rather than skipping when
either is absent:

- `AUR_SSH_PRIVATE_KEY` — a secret holding an SSH key with commit rights on both AUR packages.
- `AUR_SSH_KNOWN_HOSTS` — a repository variable holding the `aur.archlinux.org` host key line.

There is deliberately no built-in fallback host key. An earlier revision of this workflow shipped
one and it was **GitLab's** ed25519 key, so every real publish would have failed host-key
verification; a plausible-looking blob in a workflow file is exactly the kind of thing nobody
re-derives. Blind `ssh-keyscan` is not the alternative — it trusts whatever answers. Set the
variable once, from a key you have verified:

```bash
ssh-keyscan -t ed25519 aur.archlinux.org            # the line to store
ssh-keyscan -t ed25519 aur.archlinux.org | ssh-keygen -lf -   # its fingerprint, to compare
```

Compare that fingerprint against the ones Arch publishes on the [Arch User
Repository](https://wiki.archlinux.org/title/Arch_User_Repository) wiki page before storing it. Each
run prints the fingerprint it trusted, so a wrong value shows up in the log rather than only as a
confusing verification failure.

Never edit the AUR side by hand — the next publish overwrites it.

## Theme bundles

`install-system.sh` takes `VGS_THEME_BUNDLE=core|extras|all`. `core` is the default because `all`
costs roughly 1.1 GiB of themes and wallpapers, so a recipe that forgets the variable now ships
too little rather than too much. This is the authoritative statement of that figure — other docs
reference it rather than repeating the number. Derive it: `du -sh themes` measures what `all`
installs (the whole `themes/` tree), and `.totalSize` in `themes/catalog.json` is the committed
equivalent for the published themes (regenerated by `scripts/gen-theme-catalog.py --write`, kept
fresh in CI by `scripts/check-package-assets.sh`). The vendored icon themes are not part of `all`:
`install-system.sh` strips `config/vshell/icons` from `core` and `all` alike, so they ship only
with `extras` — size them with `du -sh config/vshell/icons`. `scripts/check-package-assets.sh`
fails if any in-repo recipe runs the installer without stating a bundle.

| Channel | Bundle |
|---|---|
| Arch | `core` for `vgs-shell`, `extras` for `vgs-shell-assets` |
| Debian | `core` for `vgs-shell`, `extras` for `vgs-shell-assets` |
| Fedora | `core` for `vgs-shell`, `extras` for `vgs-shell-assets` |
| Gentoo | `core`, plus `extras` with `USE=extra-themes` (on by default) |
| Void | `core` for `vgs-shell`, `extras` for `vgs-shell-assets` |
| Nix | `all`; the flake has no split output |

`core` additionally installs `themes/catalog.json` and `themes/catalog-previews/<name>.png` —
the download catalog plus every non-installed theme's screenshot (a rounding error against the
gigabyte-scale asset payload, sized above, that motivated the split). Without them, Settings →
Themes → **Download More Themes** could list the other themes but not show any of them, and a
base install would offer exactly one theme with no way to get the rest. `extras` ships neither;
`all` needs neither, because every theme carries its own `preview.png`. Regenerate the catalog with
`scripts/gen-theme-catalog.py --write` after adding or editing a theme package —
`scripts/check-package-assets.sh` fails when it is stale, because a stale manifest makes every
download of a changed theme fail its checksum.

Downloads resolve against `source.refs`: the pinned release tag first, then `main`. The checksums are
generated from the working tree, so between releases an edited theme is served only by the moving
ref — that fallback is what keeps `vgs-shell-git` (which builds from `main`) able to download edited
themes. Only checksum-matching bytes are ever accepted, from either location.

**Every release must repoint the pin**: `scripts/gen-theme-catalog.py --ref vX.Y.Z --write` as part of
step 1 of the release flow, with `themes/` committed before `check-release.sh` runs.
`scripts/gen-theme-catalog.py --check-release-pin $VERSION` (invoked from `check-release.sh`) fails
both when the ref does not match `VERSION` and when `themes/` has uncommitted changes, since the tag
captures the commit rather than the working tree. On ordinary PRs, `--check` compares the tree against
the pinned ref with git and reports which themes now resolve through `main`, failing outright if the
manifest describes content no declared ref can serve.

## Channels

| System | Channel | Status |
|---|---|---|
| Arch | [AUR `vgs-shell`](https://aur.archlinux.org/packages/vgs-shell), [`vgs-shell-git`](https://aur.archlinux.org/packages/vgs-shell-git) | Published |
| Fedora 43/44 | [COPR `vanillagreen/vgs-shell`](https://copr.fedorainfracloud.org/coprs/vanillagreen/vgs-shell/) | Published |
| openSUSE Tumbleweed/Slowroll | [OBS `home:vanillagreen`](https://build.opensuse.org/package/show/home:vanillagreen/vgs-shell) | Published |
| Debian 13 | [OBS `home:vanillagreen`](https://build.opensuse.org/package/show/home:vanillagreen/vgs-shell) | Published |
| Ubuntu 26.04 | [Launchpad PPA `vanillagreen/vgs-shell`](https://launchpad.net/~vanillagreen/+archive/ubuntu/vgs-shell) | Published; Quickshell from `ppa:avengemedia/danklinux` |
| Gentoo | [VanillaGreen overlay](https://github.com/vanillagreencom/gentoo-overlay) | Published; Quickshell from GURU; [GURU PR #530](https://github.com/gentoo/guru/pull/530) pending |
| Nix | [`github:vanillagreencom/vgs`](../flake.nix) | Published flake and Home Manager module |
| Void | [`void/template`](void/template) plus [`void/INSTALL.msg`](void/INSTALL.msg) | Recipe only; Void does not package Quickshell 0.3.0 |

Arch:

```bash
yay -S vgs-shell
```

The base package includes the `coppernight` default theme and stays small enough
for routine updates. Install the optional asset collection to add every bundled
theme, wallpaper, and vendored Yaru icon theme:

```bash
yay -S vgs-shell-assets
```

For development builds, use `vgs-shell-assets-git` with `vgs-shell-git`.

Fedora:

```bash
sudo dnf copr enable vanillagreen/vgs-shell
sudo dnf install vgs-shell
```

Debian and Fedora split the same way as Arch: `vgs-shell-assets` carries the
themes, wallpapers, and icon themes that `vgs-shell` leaves out.

openSUSE Tumbleweed:

```bash
sudo zypper ar -f https://download.opensuse.org/repositories/home:/vanillagreen/openSUSE_Tumbleweed/ vanillagreen-vgs
sudo zypper --gpg-auto-import-keys refresh
sudo zypper install vgs-shell
```

Debian 13:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.opensuse.org/repositories/home:/vanillagreen/Debian_13/Release.key | sudo tee /etc/apt/keyrings/vanillagreen-vgs.asc >/dev/null
echo 'deb [signed-by=/etc/apt/keyrings/vanillagreen-vgs.asc] https://download.opensuse.org/repositories/home:/vanillagreen/Debian_13/ /' | sudo tee /etc/apt/sources.list.d/vanillagreen-vgs.list
sudo apt update
sudo apt install vgs-shell
```

Ubuntu 26.04:

```bash
sudo add-apt-repository ppa:avengemedia/danklinux
sudo add-apt-repository ppa:vanillagreen/vgs-shell
sudo apt update
sudo apt install vgs-shell
```

Gentoo:

```bash
sudo eselect repository enable guru
sudo eselect repository add vanillagreen git https://github.com/vanillagreencom/gentoo-overlay.git
sudo emaint sync -a
sudo emerge --ask gui-apps/vgs-shell
```

Maintainer recipes remain in `arch/`, `fedora/`, `debian/`, `ubuntu/`, `gentoo/`, and `void/`. Guix needs a packaged Quickshell dependency before VGS can publish a truthful channel. Release procedure: `.agents/skills/vgs-release/SKILL.md`.
