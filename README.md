# VGS — VanillaGreen Shell

VGS is a desktop shell for the Hyprland and Niri compositors, built on Quickshell 0.3.0. It provides the bar, launcher, control centre, dock, notifications, lock screen and greeter, and a theme engine that recolours the shell and the applications you already run. Hyprland is the reference compositor; Niri is supported with native equivalents for its scrolling layout.

<video src="https://raw.githubusercontent.com/vanillagreencom/vgs/main/docs/media/vgs-demo.mp4" poster="https://raw.githubusercontent.com/vanillagreencom/vgs/main/docs/media/vgs-demo-poster.jpg" controls muted playsinline width="100%"></video>

[Watch the demo](docs/media/vgs-demo.mp4): tiling and the scrolling layout, the theme browser and wallpapers, per-application theming, the control centre and network panel, notifications, power modes, AI usage, and the VGS menu.

## Requirements

- Hyprland or Niri.
- Quickshell 0.3.0.
- systemd user services.
- Optional tools unlock optional features. A missing tool greys out its widget and leaves the rest of the shell running.

## Install

Native packages are the recommended method. They install VGS system-wide and provide normal upgrades and removal.

| Distribution | Channel | Install |
| --- | --- | --- |
| Arch | AUR | `yay -S vgs-shell`, or `vgs-shell-git` for the development version |
| Fedora 43, 44 | COPR | `sudo dnf copr enable vanillagreen/vgs-shell && sudo dnf install vgs-shell` |
| openSUSE Tumbleweed, Slowroll | OBS | [`packaging/README.md` § Channels](packaging/README.md#channels) |
| Debian 13 | OBS | [`packaging/README.md` § Channels](packaging/README.md#channels) |
| Ubuntu 26.04 | Launchpad PPA | [`packaging/README.md` § Channels](packaging/README.md#channels) |
| Gentoo | VanillaGreen overlay | [`packaging/README.md` § Channels](packaging/README.md#channels) |
| Void | maintainer recipe, no packaged Quickshell 0.3.0 | [`packaging/`](packaging/) |
| NixOS, Home Manager | flake | [`flake.nix`](flake.nix) |
| Other systemd distributions | release bundle | `curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vgs/v0.4.0/install.sh \| bash` |

On Arch, `vgs-shell` ships the `coppernight` theme only. Add `vgs-shell-assets` for the other bundled themes, their wallpapers, and the vendored icon themes.

For Home Manager, add the flake input and import the module:

```nix
inputs.vgs.url = "github:vanillagreencom/vgs";
```

```nix
{
  imports = [ inputs.vgs.homeManagerModules.default ];
  programs.vgs-shell.enable = true;
}
```

### After installing

A native package cannot enable a user service for you. Enable it once per account, then VGS starts:

```bash
systemctl --user enable --now vshell.service
```

Then see which optional features your system can run:

```bash
vshell deps status
```

Each feature group that reports `missing` names the commands it needs. The native packages list those tools as optional dependencies, so your package manager can show them too.

The release bundle supports x86-64 and ARM64, starts the user service itself unless you pass `install.sh --no-start`, and includes the full wallpaper and icon set. It checks `~/.local/bin/vshell`, `~/.config/quickshell/vshell` and `~/.config/systemd/user/vshell.service` before it writes. If another tool manages one of them, such as GNU Stow, chezmoi or yadm, it stops without changing anything; `install.sh --force` replaces externally managed symlinks. It never replaces a plain file or directory at those paths.

Checksum-verified bundles and source archives are published on [GitHub Releases](https://github.com/vanillagreencom/vgs/releases).

## Features

- A bar you build from widgets placed left, centre and right, each usable more than once: workspaces, focused window, running applications, clock, weather, media, clipboard, CPU, memory, disk and temperature monitors, network speed, system tray, privacy indicator, control centre, notifications, battery, VPN, Tailscale, AI usage, system updates, capture, idle inhibitor, keyboard layout, caps lock, colour picker, notepad, sudo toggle and power menu.
- A clock and a system monitor that sit on the desktop itself.
- The VGS menu: one searchable command menu with categories, fuzzy search, optional file search, and entries and web applications you add yourself. It is also the application launcher.
- A theme engine that writes matching themes for terminals, editors, browsers, GTK, Qt, KDE colours and icon themes. `vshell theme apps` lists the targets and their state, and each one can be switched off.
- Palette extraction from any wallpaper, per-role colour editing, whole-theme restyling by brightness, vibrancy, contrast, hue and temperature, and a light theme paired with a dark one so they swap together.
- Claude Code follows the light or dark mode of the theme you apply, without a restart.
- Screenshots and screen recording by region, window or display, with a delay timer, an editor handoff, and text extraction from the screen.
- Idle handling: lock after idle, fade to black while locked without powering monitors off, separate monitor-off and suspend timers on AC and battery, a video screensaver on the lock screen, an ASCII screensaver on the desktop, and an inhibitor that suppresses the chain.
- Display management: arrangement, resolution, refresh rate, scale, rotation, saved profiles and gamma. Brightness works per display for laptop panels, external monitors over DDC/CI, and the Apple Pro Display XDR and Studio Display over USB.
- Per-monitor wallpapers, scheduled rotation, and a local AI upscaler that turns smaller images into 6K wallpapers.
- Plan limits for Claude and Codex in the bar, for every account you are signed into, with per-model quotas and reset countdowns.
- Repository, AUR and development-tool update counts in the bar, with the update run handed to a terminal.
- Tailscale and Bluetooth status and controls, and a themed greeter with optional auto-login.
- An optional glass material for popouts and menus: translucent tinted surfaces over a blurred backdrop.

`themes/catalog.json` lists the bundled themes, including Catppuccin, Gruvbox, Nord, Dracula, Rosé Pine, Tokyo Night, Kanagawa, Everforest, Ayu, Monokai and Matte Black, plus VGS originals. Every bundled theme ships a committed preview.

### Compositor support

| Tier | Features |
| --- | --- |
| Both compositors | Bar and widgets, launcher, dash, control centre, dock, notifications, lock screen, greeter, themes, wallpapers, capture, brightness, idle and lock handling, and the backend services |
| Niri equivalents | Dynamic per-output workspaces, the Niri overview, and KDL display, layout, keybind and window-rule configuration |
| Hyprland only | Compositor blur. Niri has no blur API, so VGS disables that setting and explains why. |

## How it works

- `vshell.service`, a systemd user service, runs the Quickshell configuration that draws every surface.
- The QML shell asks the `vshell` CLI for anything privileged or generated. `bin/vshell-helper` does the heavy theme generation and template rendering.
- Applying a theme writes a colour file for each enabled target application and reloads the ones that support it.
- `vshell ipc call <target> <function>` drives the shell from a keybind or a script. `vshell ipc call vshell-menu open` opens the menu.
- On Niri, VGS generates its own KDL fragments under `~/.config/niri/vgs/`. On Hyprland, VGS reads your configuration and does not write it.

## Settings

- `~/.config/vshell` holds your settings, your own themes, and plugin overrides. Keep it a real directory.
- `~/.config/vshell/keybind-labels.json` names keys the compositor reports only as a raw keycode, which is what a remapper such as `input-remapper` or a QMK layer produces. Key it by the code or the resolved key: `{ "F13": "Right Alt" }`.
- The settings window covers everything else, and `vshell --help` lists the equivalent commands.

```bash
vshell theme list
vshell theme apply tokyo-night
vshell theme extract-wallpaper ~/Pictures/wall.jpg --mode auto --apply
```

---

MIT licensed. Built on [Quickshell](https://quickshell.org), [Hyprland](https://hypr.land) and [Niri](https://github.com/YaLTeR/niri), and forked from [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell). Lineage is recorded in [`docs/ATTRIBUTION.md`](docs/ATTRIBUTION.md).
