# Package channels

Native packages install VGS under `/usr/lib/vshell` with the `vshell` command and a user service. User settings remain in `~/.config/vshell`.

## Activation

After a native package installation, enable VGS for your account:

```bash
systemctl --user enable --now vshell.service
```

The source installer starts the service unless given `--no-start`. Home Manager controls activation through its module.

## Theme bundles

The base package includes the default theme and the theme download catalog. The optional assets package supplies the bundled themes, wallpapers and icons. Gentoo selects extra themes through its USE flag; the Nix package uses the combined theme bundle.

## Channels

Use both listed repositories for openSUSE, both PPAs for Ubuntu, and GURU with the VGS overlay for Gentoo. These supply the Quickshell dependency as well as VGS.

### Arch

```bash
yay -S vgs-shell
```

### Arch optional themes and icons

```bash
yay -S vgs-shell-assets
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

For Arch development builds, pair `vgs-shell-git` with `vgs-shell-assets-git`. Debian and Fedora also provide an optional `vgs-shell-assets` package.

### Nix

Use the package or Home Manager module from [the VGS flake](../flake.nix). Setup is described in [the main README](../README.md).

### Void

The [recipe](void/template) and [installation message](void/INSTALL.msg) are provided for local packaging. A compatible Quickshell package is required.

## Maintenance

Package generation and publication are documented in [DEVELOPMENT.md](DEVELOPMENT.md).
