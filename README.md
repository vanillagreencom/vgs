# VGS — VanillaGreen Shell

A desktop shell for Hyprland — bar, launcher, settings, lock screen and a theme engine that
restyles your whole desktop, not just the shell.

<video src="https://github.com/vanillagreencom/vgs/raw/main/docs/media/vgs-demo.mp4"
       poster="https://github.com/vanillagreencom/vgs/raw/main/docs/media/vgs-demo-poster.jpg"
       controls muted autoplay loop playsinline width="100%"></video>

*Tiling and the scrolling layout, then the theme browser, settings, and the VGS menu.*
([download the clip](docs/media/vgs-demo.mp4) if it doesn't play inline)

## What it is

VGS started as a fork of [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) and
keeps the same shape: a bar, a launcher, a control centre, a dash, a dock, a lock screen. What
follows is what VGS adds on top.

| | |
|---|---|
| **A real theme engine** | The biggest difference. Themes restyle 28 apps alongside the shell, ship with wallpapers, and can be edited colour by colour. |
| **Claude & Codex usage** | Plan limits in the bar, including every account you're signed into, with per-model quotas and reset countdowns. |
| **System updates** | Repo and AUR counts in the bar; run updates in a terminal from the popout. |
| **Display brightness** | Per-monitor control for laptop panels, external monitors over DDC/CI, and Apple Pro Display XDR and Studio Display over USB. |
| **Capture** | One modal for screenshots, recording and text grab, with delay, region, window and display targets. |
| **Tailscale & Bluetooth** | Mesh VPN status and controls in the bar, and Bluetooth handling that stays out of your way. |

## Themes

**79 themes ship with VGS** — Catppuccin, Gruvbox, Nord, Dracula, Rosé Pine, Tokyo Night, Kanagawa,
Everforest, Ayu, Monokai, Matte Black and more, plus a set of originals. Star the ones you use and
they stay at the top of the list.

Switching a theme doesn't just recolour the shell. VGS writes matching themes for the apps you
already use:

Alacritty · btop · Chromium · Emacs · Equibop · Fastfetch · foot · Ghostty · GTK 3 · GTK 4 ·
Helix · Hyprland · Icon theme · KDE colours · Kitty · Neovim · Obsidian · Pi · Firefox (Pywalfox) ·
Qt 5 · Qt 6 · tmux · Vencord · Vesktop · VS Code · WezTerm · Zed · Zen Browser

Each app can be switched on or off individually. Beyond picking a theme you can pull a palette out
of any wallpaper, hand-edit individual colour roles, restyle a whole theme (brightness, vibrancy,
contrast, hue, temperature), and pair a light theme with a dark one so they swap together.

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
one for the desktop, and an idle inhibitor that suppresses the whole chain.

**Displays.** Arrange monitors, set resolution, refresh rate, scale and rotation, save profiles,
and adjust gamma. Brightness works per display, including Apple Pro Display XDR and Studio Display.

**Login.** A themed greeter that matches your desktop, with optional auto-login and an opt-in fix
for the keyring prompt auto-login otherwise causes.

**Wallpapers.** Per-monitor wallpapers, scheduled rotation, and a local AI upscaler for turning
smaller images into 6K wallpapers.

## Requirements

- **Hyprland** and **Quickshell 0.3.0**
- Optional tools unlock optional features — a missing one greys out its widget rather than breaking
  the shell. `vshell deps status` lists what's found.

## Install

```bash
git clone https://github.com/vanillagreencom/vgs.git ~/dev/vgs

# point Quickshell and your PATH at it
ln -s ~/dev/vgs/quickshell/vshell ~/.config/quickshell/vshell
ln -s ~/dev/vgs/bin/vshell        ~/.local/bin/vshell

# start it with your session
systemctl --user enable --now vshell.service
```

`vshell deps status` shows which optional features your system can run. `vshell --help` covers the
rest: themes, capture, brightness, updates and the IPC surface you can bind keys to.

Keep `~/.config/vshell` as a real directory, not a symlink into the repo — that is where your
settings, user themes and plugin overrides live. Bundled plugins load from the clone.

## Repo layout

| Path | Purpose |
|---|---|
| `quickshell/vshell/` | Quickshell runtime: `shell.qml`, services, modules, widgets |
| `bin/vshell`, `bin/vshell-helper` | CLI, IPC wrapper, theme engine, capture/update/AI helpers |
| `backend/` | Go daemon: network, logind, BlueZ, CUPS and other system services |
| `config/vshell/` | Shipped defaults, dependency manifest, bundled plugins |
| `themes/` | Built-in theme packages, wallpapers, and app target templates |
| `systemd/user/vshell.service` | User service template |
| `docs/architecture/` | Architecture references |

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

MIT licensed. Built on [Quickshell](https://quickshell.org) and [Hyprland](https://hypr.land), and
on the work of [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell), which VGS was
forked from. Historical lineage is documented in `docs/ATTRIBUTION.md`.
