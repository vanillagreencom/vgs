# Update pipeline

The plugin declares two floating TUIs that update.

- `update` runs `tui/update.sh`: every source in one run. Its launcher entry is in the `Update` group, so the launcher's Update row opens it.
- `update-source` runs `tui/update-source.sh <source>`: one source. `<source>` is a status row's `source`: the primary package manager's id, `aur`, `flatpak`, `mise`, `vgs`, `plugins` or `themes`. It is not listed, because it needs its argument: `shell.tui.run("update-source", [source])` opens it.

Both take `-y`, which skips the start question only. They share `tui/pipeline.sh`, whose header is the full contract. A run takes these steps in this order:

1. The log and the lock. `script` writes the run to `${XDG_STATE_HOME}/vgs/updates/update.log`. The lock is `${XDG_RUNTIME_DIR}/vgs-tui-updates.lock`. A second run exits 75 and leaves the first run's log as it is.
2. A warning when `/` has less than 10 GiB free.
3. The plan box: the snapshot tool, each source with the commands it runs, and the log path. Then `Start the update?`, unless `-y`.
4. One sudo session, when a snapshot or the system step needs root and the elevation command is `sudo`. `vgsh pkg run` joins it, so the password is asked once. The elevation command is the one `vgsh pkg plan upgrade <primary>` names: `packages.elevate` in `shell.json`, else the first of `sudo`, `doas` and `run0` on `PATH`. `doas` and `run0` ask as their own rules say.
5. A snapshot through snapper, else timeshift, behind the elevation command. It comes before any step that replaces a package: the system upgrade, the AUR upgrade or the `vgs-git` rebuild. No snapshot is taken when the `snapshot` setting is `off`, when neither tool is on `PATH` or when no elevation command resolves. The plan box says which. A tool that fails or has no configuration prints a warning, and the update continues without a snapshot.
6. VGS itself: `vgsh self update` for a checkout or a curl install. It restarts a running shell. The `vgs` package updates with its package manager, and a Nix tree with its flake.
7. The system: `vgsh pkg run upgrade --manager <primary>`.
8. Flatpak and mise: `vgsh pkg run upgrade --manager flatpak`, then `--manager mise`.
9. Each plugin, then each theme, that is behind its upstream: `vgsh plugin update <id>` and `vgsh theme update <name>`. Each shows its diff and asks `[y/N]`. The pipeline passes `--yes` only when `trustPluginUpdates` is on. A declined or failed update prints a warning and the run continues.
10. The end of the sudo session. The credential is dropped.
11. The AUR, last: the `aurCommand` setting's words, else `vgsh pkg run upgrade --manager aur` (`paru -Sua` or `yay -Sua`). No AUR build runs under the update's credential. When VGS is the `vgs-git` package and behind, `<helper> -S vgs-git` follows, because an AUR helper rebuilds a `-git` package only when its recipe's version changes. The helper asks `sudo` itself. The credential it caches is dropped when this step ends, fails or is interrupted.
12. On pacman, after a system or AUR upgrade, the orphaned packages from `pacman -Qtdq`, with `Remove N orphaned package(s)?`, default no. A yes runs `vgsh pkg run remove --manager pacman`.
13. A shell restart, when a package step or the `vgs-git` rebuild replaced the VGS package.
14. A reboot question, when the kernel or the running Hyprland binary was replaced (`vgs_tui_reboot_check`).

Every package step is the package table's own plan, from `vgsh pkg plan upgrade <id>`. The steps take no `-y`, so each manager asks its own questions in the terminal. A package source without an upgrade plan, such as `nix`, is left out of the run with the reason in the plan box.

With `-y`, the orphan list and the reboot reason are printed instead of asked.

A failing step stops the run. The terminal then shows `updates: failed exit=<n> log=<file>` and how to recover. The sudo session, or the guard around the AUR, drops the credential on the way out.

The TUIs read the plugin's settings with `vgsh plugin settings vgs.updates`, since `shell.tui.open` hands a script no arguments. `bin/facts` reads each `vgsh` JSON answer for the shell script. It decides whether VGS, a plugin or a theme is behind through `UpdatesLogic.js`, as the service does.

When a run ends, the service checks again ([README.md § Cadence](README.md#cadence)).

## Omarchy comparison

`bin/omarchy-update` (basecamp/omarchy `e332dc97`) is the model. VGS takes its order and its safety steps: the `script` log, the lock, the free-space check, the confirm box, one sudo authorization with a keepalive, the snapshot with a missing tool as a quiet skip, mise with `MISE_MINIMUM_RELEASE_AGE=0`, the credential dropped before the AUR, the orphan question with default no, and the reboot question for a new kernel or a replaced Hyprland. `OMARCHY_UPDATE_SUDO_SESSION` is the model for the nested session that `vgsh pkg run` joins.

VGS differs in these ways:

- Low free space is a warning, not a refusal, so a user with a small disk can still update. Omarchy refuses below 10 GiB.
- The package steps are the package table's plans, with no `--noconfirm`, so each manager asks its own questions.
- Each plugin and theme update shows its diff and asks.
- The AUR runs after the credential is dropped, and it is dropped again after. The `sudo-no-update` wrapper is not copied.
- Not copied: migrations, the keyring step, channels and the ALPM guard. These are distribution work, and VGS is not the distribution. The stay-awake step is not copied yet. A later `systemd-inhibit` step can add it.
