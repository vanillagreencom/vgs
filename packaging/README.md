# Package channels

VGS installs under `/usr/lib/vshell`, exposes `/usr/bin/vshell`, and installs the user service. Mutable state remains in `~/.config/vshell`.

| System | Channel | Status |
|---|---|---|
| Arch | [AUR `vgs-shell`](https://aur.archlinux.org/packages/vgs-shell), [`vgs-shell-git`](https://aur.archlinux.org/packages/vgs-shell-git) | Published |
| Fedora 43/44 | [COPR `vanillagreen/vgs-shell`](https://copr.fedorainfracloud.org/coprs/vanillagreen/vgs-shell/) | Published |
| openSUSE Tumbleweed/Slowroll | [OBS `home:vanillagreen`](https://build.opensuse.org/package/show/home:vanillagreen/vgs-shell) | Published |
| Debian 13 | [OBS `home:vanillagreen`](https://build.opensuse.org/package/show/home:vanillagreen/vgs-shell) | Published |
| Ubuntu 26.04 | [Launchpad PPA `vanillagreen/vgs-shell`](https://launchpad.net/~vanillagreen/+archive/ubuntu/vgs-shell) | Published; Quickshell from `ppa:avengemedia/danklinux` |
| Gentoo | [VanillaGreen overlay](https://github.com/vanillagreencom/gentoo-overlay) | Published; Quickshell from GURU; [GURU PR #530](https://github.com/gentoo/guru/pull/530) pending |
| Nix | [`github:vanillagreencom/vgs`](../flake.nix) | Published flake and Home Manager module |
| Void | [`void/template`](void/template) | Recipe only; Void does not package Quickshell 0.3.0 |

Arch:

```bash
yay -S vgs-shell
```

Fedora:

```bash
sudo dnf copr enable vanillagreen/vgs-shell
sudo dnf install vgs-shell
```

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
