# VGS — VanillaGreen Shell

A desktop shell for Hyprland and Niri — bar, launcher, settings, lock screen and a theme engine that
restyles your whole desktop, not just the shell.

Hyprland remains the reference compositor; Niri is supported as an additive,
native scrolling-workspace target.

<video src="https://github.com/user-attachments/assets/be9ffadf-ba95-4bc9-8401-02d62e30fdb2"
       controls muted width="100%"></video>

*Tiling and the scrolling layout, the theme browser and wallpapers, per-app theming in settings,
the control centre with the network panel, notifications, power modes, AI usage, and the VGS menu.*

## What it is

VGS started as a fork of [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) and
keeps the same shape: a bar, a launcher, a control centre, a dash, a dock, a lock screen. What
follows is what VGS adds on top.

| | |
|---|---|
| **A real theme engine** | The biggest difference. Themes restyle 29 apps alongside the shell, ship with wallpapers, and can be edited colour by colour. |
| **Claude & Codex usage** | Plan limits in the bar, including every account you're signed into, with per-model quotas and reset countdowns. |
| **System updates** | Repo and AUR counts in the bar; run updates in a terminal from the popout. |
| **Display brightness** | Per-monitor control for laptop panels, external monitors over DDC/CI, and Apple Pro Display XDR and Studio Display over USB. |
| **Capture** | One modal for screenshots, recording and text grab, with delay, region, window and display targets. |
| **Tailscale & Bluetooth** | Mesh VPN status and controls in the bar, and Bluetooth handling that stays out of your way. |
| **Glass UI** | An optional iOS-style glass material for every popout and menu — translucent tinted surfaces over a saturated backdrop blur, with a specular rim and sheen. |

## Requirements

- **Hyprland or Niri** and **Quickshell 0.3.0**.
- Optional tools unlock optional features — a missing one greys out its widget rather than breaking
  the shell. `vshell deps status` lists what's found.

### Compositor support

| Tier | Features |
|---|---|
| Full parity | Bar and widgets, launcher, dash, control centre, dock, notifications, lock screen, greeter, themes, wallpapers, capture, brightness, idle/lock/screensaver, and backend system services |
| Niri-native equivalent | Dynamic per-output workspaces, Niri overview, KDL display/layout configuration, KDL keybinds, and KDL window rules |
| Hyprland-only | Compositor blur. Niri has no compositor blur API, so its setting is disabled with an explanation. |

## Install

Native packages are the recommended installation method. They install VGS system-wide, handle
dependencies, and provide normal upgrades and removal.

After installing a native package, enable the user service for your account:

```bash
systemctl --user enable --now vshell.service
```

### Arch Linux

Install the latest release from [AUR `vgs-shell`](https://aur.archlinux.org/packages/vgs-shell):

```bash
yay -S vgs-shell
```

Replace `yay` with your preferred AUR helper. Use
[`vgs-shell-git`](https://aur.archlinux.org/packages/vgs-shell-git) instead for the current
development version.

### Fedora

Fedora 43 and 44 are published through
[COPR `vanillagreen/vgs-shell`](https://copr.fedorainfracloud.org/coprs/vanillagreen/vgs-shell/):

```bash
sudo dnf copr enable vanillagreen/vgs-shell
sudo dnf install vgs-shell
```

### openSUSE

For Tumbleweed:

```bash
sudo zypper ar -f https://download.opensuse.org/repositories/home:/vanillagreen/openSUSE_Tumbleweed/ vanillagreen-vgs
sudo zypper --gpg-auto-import-keys refresh
sudo zypper install vgs-shell
```

The [VGS OBS project](https://build.opensuse.org/package/show/home:vanillagreen/vgs-shell) also
publishes a Slowroll build.

### Debian

For Debian 13, use the
[VGS OBS repository](https://build.opensuse.org/package/show/home:vanillagreen/vgs-shell):

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.opensuse.org/repositories/home:/vanillagreen/Debian_13/Release.key | sudo tee /etc/apt/keyrings/vanillagreen-vgs.asc >/dev/null
echo 'deb [signed-by=/etc/apt/keyrings/vanillagreen-vgs.asc] https://download.opensuse.org/repositories/home:/vanillagreen/Debian_13/ /' | sudo tee /etc/apt/sources.list.d/vanillagreen-vgs.list
sudo apt update
sudo apt install vgs-shell
```

### Ubuntu

Ubuntu 26.04 needs both the Quickshell dependency PPA and the
[VGS PPA](https://launchpad.net/~vanillagreen/+archive/ubuntu/vgs-shell):

```bash
sudo add-apt-repository ppa:avengemedia/danklinux
sudo add-apt-repository ppa:vanillagreen/vgs-shell
sudo apt update
sudo apt install vgs-shell
```

### Gentoo

VGS ships in the [VanillaGreen overlay](https://github.com/vanillagreencom/gentoo-overlay); Quickshell comes from GURU, so enable both:

```bash
sudo eselect repository enable guru
sudo eselect repository add vanillagreen git https://github.com/vanillagreencom/gentoo-overlay.git
sudo emaint sync -a
sudo emerge --ask gui-apps/vgs-shell
```

### Nix / Home Manager

Add the [VGS flake](flake.nix) input in `flake.nix`:

```nix
inputs.vgs.url = "github:vanillagreencom/vgs";
```

Then import it in your Home Manager module:

```nix
{
  imports = [ inputs.vgs.homeManagerModules.default ];
  programs.vgs-shell.enable = true;
}
```

### Universal installer

For other systemd-based Linux distributions, install the pinned release bundle:

```bash
curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vgs/v0.1.0/install.sh | bash
```

The bundle supports x86-64 and ARM64. It requires Quickshell 0.3.0, `jq`, `python3`, systemd user
services, and Hyprland or Niri.

Run `vshell deps status` after installation. Optional features report their missing system packages
instead of blocking the shell. Keep `~/.config/vshell` as a real directory: settings, user themes,
and plugin overrides live there.

The universal bundle includes the full built-in wallpaper and icon asset set and starts the user
service by default unless `install.sh --no-start` is used.

The installer checks `~/.local/bin/vshell`, `~/.config/quickshell/vshell`, and
`~/.config/systemd/user/vshell.service` before it writes anything. If one of them is managed by
something else — GNU Stow, chezmoi, yadm — it refuses without having changed a thing; pass
`install.sh --force` to replace those paths anyway.

Void currently has a maintainer recipe but no packaged Quickshell 0.3.0 dependency. See
[`packaging/`](packaging/) for that recipe, package source files, and channel details.
Checksum-verified bundles and source archives are available from
[GitHub Releases](https://github.com/vanillagreencom/vgs/releases).

## Themes

**79 themes ship with VGS** — Catppuccin, Gruvbox, Nord, Dracula, Rosé Pine, Tokyo Night, Kanagawa,
Everforest, Ayu, Monokai, Matte Black and more, plus a set of originals. Star the ones you use and
they stay at the top of the list.

Switching a theme doesn't just recolour the shell. VGS writes matching themes for the apps you
already use:

Alacritty · btop · Chromium · Emacs · Equibop · Fastfetch · foot · Ghostty · GTK 3 · GTK 4 ·
Helix · Hyprland · Niri · Icon theme · KDE colours · Kitty · Neovim · Obsidian · Pi · Firefox (Pywalfox) ·
Qt 5 · Qt 6 · tmux · Vencord · Vesktop · VS Code · WezTerm · Zed · Zen Browser

Each app can be switched on or off individually. Beyond picking a theme you can pull a palette out
of any wallpaper, hand-edit individual colour roles, restyle a whole theme (brightness, vibrancy,
contrast, hue, temperature), and pair a light theme with a dark one so they swap together.

Some targets go further than dropping a colour file. Chromium gets its theme pushed through a
managed policy, Pi gets a generated theme linked into its agent config, and **Claude Code follows
the light/dark mode of the theme you apply** — switch to a light theme and the CLI switches with
it, no restart.

All built-in themes include committed previews. Generating a preview for a new
user theme is an optional development workflow that currently uses a nested
Hyprland session; Hyprland is not a runtime requirement for a Niri installation.

## Widgets

The bar is built from widgets you arrange across left, centre and right — more than once each, if
you want.

| Widget | What it does |
|---|---|
| App Launcher | Opens the launcher |
| Workspaces | Current workspace, click to switch, optional app icons |
| Focused Window | Title of the active window |
| Running Apps | Open apps with focus indication |
| Apps Dock | Pinned and running apps, drag to reorder |
| Clock | Time and date |
| Weather | Conditions and temperature |
| Media | Controls for whatever is playing |
| Clipboard | Clipboard history |
| System monitors | CPU, memory, disk, CPU and GPU temperature |
| Network Speed | Live download and upload |
| System Tray | Tray icons |
| Privacy Indicator | Shows when mic, camera or screen share is live |
| Control Centre | Network, audio, Bluetooth, brightness, night mode |
| Notifications | Notification centre and do-not-disturb |
| Battery | Level, time remaining, charge limit |
| VPN | Status and quick connect |
| Tailscale | Mesh VPN status and controls |
| AI Usage | Claude and Codex plan limits, per account |
| System Updates | Repo and AUR update counts |
| Capture | Screenshot and recording state |
| VGS Menu | Searchable command menu with categories |
| Idle Inhibitor | Keeps the screen awake |
| Keyboard Layout | Active layout, click to switch |
| Caps Lock | Caps lock indicator |
| Colour Picker | Pick a colour off the screen |
| Notepad | Quick notes |
| Passwordless Sudo | Sudo status toggle |
| Power | Power menu |
| Spacer / Separator | Layout helpers |

Two widgets also live on the desktop itself: a clock (analog, digital or stacked) and a system
monitor.

## The rest of the shell

**Launcher and menus.** A full launcher and a Spotlight-style bar, both with fuzzy search, plus
optional file search. The VGS menu is a separate, category-based command menu you can extend with
your own entries and web apps.

**Capture.** Screenshots by region, window or display, with a delay timer and an editor handoff.
Screen recording with the same targets, and OCR to grab text off the screen.

**Idle, lock and screensaver.** Lock after idle, fade to black while locked without powering
monitors off, and wake straight to the password prompt. Optional monitor power-off and suspend
timers with separate values on AC and battery. A video screensaver for the lock screen, an ASCII
screensaver for the desktop — inspired by [Omarchy](https://omarchy.org)'s, and regenerable from
any picture — and an idle inhibitor that suppresses the whole chain.

**Displays.** Arrange monitors, set resolution, refresh rate, scale and rotation, save profiles,
and adjust gamma. Brightness works per display, including Apple Pro Display XDR and Studio Display.

**Login.** A themed greeter that matches your desktop, with optional auto-login and an opt-in fix
for the keyring prompt auto-login otherwise causes.

**Wallpapers.** Per-monitor wallpapers, scheduled rotation, and a local AI upscaler for turning
smaller images into 6K wallpapers.

## Theme engine from the CLI

```bash
vshell theme list
vshell theme apply tokyo-night
vshell theme extract-wallpaper ~/Pictures/wall.jpg --mode auto --apply
vshell theme import-colors ./colors.toml --name imported --apply
```

Heavy generation lives in `bin/vshell-helper`; QML shells out to `vshell theme …` rather than doing
privileged writes or template rendering itself.

---

MIT licensed. Built on [Quickshell](https://quickshell.org),
[Hyprland](https://hypr.land), [Niri](https://github.com/YaLTeR/niri), and
on the work of [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell), which VGS was
forked from. Historical lineage is documented in `docs/ATTRIBUTION.md`.
