# Lock

`vgs.lock` locks the session with hyprlock, drawn in the applied theme's colours and fonts over the theme's background image. The lock is its own process, so it stays locked and unlockable when the shell stops or crashes.

## Install

The plugin ships with VGS and is enabled by default. It needs `hyprlock` (the `hyprlock` package on Arch, Debian testing and Nix).

## Features

- `SUPER+L` locks the session.
- The launcher's Lock row locks the session the same way.
- The lock screen follows every theme you apply: a clock, the password field and the theme's background image under a scrim.
- Without a VGS theme lock screen, hyprlock uses your own `~/.config/hypr/hyprlock.conf`.

## How it works

1. `SUPER+L` or `vgsh ipc call vgs.lock invoke lock ''` runs `vgsh lock` as a separate process.
2. `vgsh lock` starts hyprlock on the lock screen `vgsh theme apply` renders into `~/.local/state/vgs/theme/hyprlock.conf`, with the theme's current background image.
3. hyprlock asks for your password through PAM and unlocks.

`vgsh lock` needs no running shell. Use it wherever a lock command goes: hypridle's `lock_cmd = vgsh lock`, or a Hyprland lid-switch bind.

## Settings

- The key: the Settings window's Keys section for Lock, or `plugins[].keys.lock` in `~/.config/vgs/shell.json`.
- The look: the theme. The file under `~/.local/state/vgs/theme/` is written again on every apply, so edit the theme rather than the file.
