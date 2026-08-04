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

## Optional dependencies

`config/vshell/dependencies.json` is the source of truth for which commands back which VGS feature
group, and `optional-packages.json` maps those commands to distribution package names.
`scripts/gen-package-metadata.py` joins the two and rewrites the generated blocks in the Arch,
Debian, Fedora, and Gentoo recipes:

```bash
scripts/gen-package-metadata.py            # verify the recipes match the manifest
scripts/gen-package-metadata.py --write    # regenerate them
```

The verify mode runs in `scripts/check-release.sh`, and a command added to the manifest without a
package mapping fails the check rather than silently going unadvertised. Do not hand-edit anything
between the `BEGIN`/`END GENERATED OPTIONAL DEPENDENCIES` markers.

Fedora uses `Suggests:` rather than `Recommends:` because dnf installs weak `Recommends` by default,
and the list includes a login manager (`greetd`) and both supported compositors. Void has no
weak-dependency mechanism, so its optional tools are covered by `INSTALL.msg` and
`vshell deps status` only.

## Theme bundles

`install-system.sh` takes `VGS_THEME_BUNDLE=core|extras|all`. `core` is the default because `all`
costs roughly 1.1 GiB of themes, wallpapers, and icon themes, so a recipe that forgets the variable
now ships too little rather than too much. `scripts/check-package-assets.sh` fails if any in-repo
recipe runs the installer without stating a bundle.

| Channel | Bundle |
|---|---|
| Arch | `core` for `vgs-shell`, `extras` for `vgs-shell-assets` |
| Debian | `core` for `vgs-shell`, `extras` for `vgs-shell-assets` |
| Fedora | `core` for `vgs-shell`, `extras` for `vgs-shell-assets` |
| Gentoo | `core`, plus `extras` with `USE=extra-themes` (on by default) |
| Void | `core` for `vgs-shell`, `extras` for `vgs-shell-assets` |
| Nix | `all`; the flake has no split output |

`core` additionally installs `themes/catalog.json` and `themes/catalog-previews/<name>.png` —
the download catalog plus every non-installed theme's screenshot (~23 MiB against the ~1.1 GiB
of wallpapers that motivated the split). Without them, Settings → Themes → **Download More
Themes** could list the other themes but not show any of them, and a base install would offer
exactly one theme with no way to get the rest. `extras` ships neither; `all` needs neither,
because every theme carries its own `preview.png`. Regenerate the catalog with
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
