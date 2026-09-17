# Package channels

Native packages install VGS under `/usr/lib/vshell` with the `vshell` command and a user service. User settings remain in `~/.config/vshell`.

## Activation

After a native package installation, finish the setup for your account:

```bash
vshell setup
```

It reports the optional feature dependencies and which app owns `org.freedesktop.Notifications`, then enables and starts `vshell.service`. The report comes first because the unit is `Type=simple`: taken after the start, it would answer while the shell is still loading and about to claim that name.

No VGS package ships a systemd preset. [`systemd.preset(5)`](https://www.freedesktop.org/software/systemd/man/latest/systemd.preset.html) advises against shipping a preset from the package that implements the unit, and asks that preset policy be centralised in a distribution's own default policy instead. No VGS package enables the unit either. Each channel's reason is its row.

| Channel | First start |
|---|---|
| Arch | `vshell setup`. Arch enables no service on installation. |
| Debian, Ubuntu | `vshell setup`. `debian/rules` passes `dh_installsystemduser --no-enable`; the default sequence carries that helper from compat 12 and would otherwise enable VGS for every account on the machine. |
| Fedora | `vshell setup`. Preset policy lives in `fedora-release`, and enabling a service by default needs FESCo approval, which requires that the unit not change the behaviour of other services. VGS claims `org.freedesktop.Notifications`. |
| openSUSE | `vshell setup`. Its spec is an openSUSE variant kept in the OBS project rather than in this repository, so this row is kept in step by hand; [DEVELOPMENT.md](DEVELOPMENT.md) covers publication. |
| Gentoo | `vshell setup`. `pkg_postinst` reports the step and enables nothing. |
| Void | `exec-once = vshell run` for Hyprland, `spawn-at-startup "vshell" "run"` for Niri. Void runs runit and has no user service to enable. |
| Source installer | `install.sh` enables and starts the unit unless given `--no-start`. It calls systemd directly, because `--version` installs an older bundle whose CLI need not carry the `setup` verb. |
| Nix | Home Manager controls activation through its module. |

## Themes

Every channel installs one theme set: every theme's definitions and full-size preview, the default `bauhaus` theme's wallpapers, the download catalog, a thumbnail per catalogued theme, and the vendored icon themes. Every other theme's wallpapers download on demand from its own release archive.

## Channels

Use both listed repositories for openSUSE, both PPAs for Ubuntu, and GURU with the VGS overlay for Gentoo. These supply the Quickshell dependency as well as VGS.

### Arch

```bash
yay -S vgs-shell
```

### Fedora

```bash
sudo dnf copr enable vanillagreen/vgs-shell
sudo dnf install vgs-shell
```

### openSUSE Tumbleweed

```bash
sudo zypper ar -f https://download.opensuse.org/repositories/home:/AvengeMedia:/danklinux/openSUSE_Tumbleweed/ danklinux
sudo zypper ar -f https://download.opensuse.org/repositories/home:/vanillagreen/openSUSE_Tumbleweed/ vanillagreen-vgs
sudo zypper --gpg-auto-import-keys refresh
sudo zypper install vgs-shell
```

### openSUSE Slowroll

```bash
sudo zypper ar -f https://download.opensuse.org/repositories/home:/AvengeMedia:/danklinux/openSUSE_Slowroll/ danklinux
sudo zypper ar -f https://download.opensuse.org/repositories/home:/vanillagreen/openSUSE_Slowroll/ vanillagreen-vgs
sudo zypper --gpg-auto-import-keys refresh
sudo zypper install vgs-shell
```

### Debian 13

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.opensuse.org/repositories/home:/vanillagreen/Debian_13/Release.key | sudo tee /etc/apt/keyrings/vanillagreen-vgs.asc >/dev/null
echo 'deb [signed-by=/etc/apt/keyrings/vanillagreen-vgs.asc] https://download.opensuse.org/repositories/home:/vanillagreen/Debian_13/ /' | sudo tee /etc/apt/sources.list.d/vanillagreen-vgs.list
sudo apt update
sudo apt install vgs-shell
```

### Ubuntu 26.04

```bash
sudo add-apt-repository ppa:avengemedia/danklinux
sudo add-apt-repository ppa:vanillagreen/vgs-shell
sudo apt update
sudo apt install vgs-shell
```

### Gentoo

```bash
sudo eselect repository enable guru
sudo eselect repository add vanillagreen git https://github.com/vanillagreencom/gentoo-overlay.git
sudo emaint sync -a
sudo emerge --ask gui-apps/vgs-shell
```

Arch development builds use `vgs-shell-git`. That recipe builds the current `main`, and it computes its version from the source clone: the VGS version, the number of commits, and the head. A package helper reads that number only after it clones. Until then it shows the version written in the published recipe, which is the head of the last publication, so the version you see before installing lags the one you get. Publication writes its own head into the recipe.

### Nix

Use the package or Home Manager module from [the VGS flake](../flake.nix). Setup is described in [the main README](../README.md).

### Void

The [recipe](void/template) and [installation message](void/INSTALL.msg) are provided for local packaging. A compatible Quickshell package is required.

## Maintenance

Package generation and publication are documented in [DEVELOPMENT.md](DEVELOPMENT.md).
