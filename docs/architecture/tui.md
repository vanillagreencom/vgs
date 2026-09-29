# Floating TUIs

Covers: bin/vgsh-tui, bin/lib/tui.sh, bin/lib/logo.txt, bin/vgsh-sudo-grant, bin/lib/tmpfiles.d/**, shell/Core/TuiRunner.qml, scripts/test-vgsh-tui.sh, scripts/test-tui.sh, scripts/test-tui-logic.js, scripts/test-vgsh-sudo-grant.sh, scripts/smoke/rows/tui.sh, scripts/smoke/fixtures/plugins/acme.tui/**

A floating TUI is a themed terminal window that floats over the session and runs one command under the VGS presentation: the logo, the command, then Done or Failed and a keypress. A flow that asks for a password or a `[y/N]` answer runs in one, so the user answers in a terminal they see, never in the shell process. It is a core concept: [D033](../decisions/D033-floating-tuis-are-core.md).

## The parts

- `bin/vgsh-tui` is the only file that knows terminals. `launch` opens the window and `present` runs inside it. Their options, exit codes and refusal keys are in the file's header.
- `bin/lib/tui.sh` is the library a TUI script sources through `$VGS_TUI_LIB`: step and warning lines, a header box, gum questions, one sudo authorization per script, a lock, a log and a reboot check. Its header lists each function and its return codes.
- `bin/lib/logo.txt` is the wordmark `present` prints in the theme accent.
- `vgsh tui present [--title T] [--size S] -- argv...` is the core's own entry: it hands argv to `vgsh-tui launch` with the full presentation and needs no shell running.
- The manifest key `tui` and the capability `tui` let a plugin open the scripts it declares, and list and open any listed TUI: [§ The capability](#the-capability).

## The window

- `launch` runs `setsid -f xdg-terminal-exec --app-id=<app-id> --title="VGS · <title>" -- vgsh-tui present ...` and exits 0 once setsid has forked it into a session of its own. The terminal outlives whatever started `launch`: Quickshell kills the processes it started when the shell stops, and a `vgsh restart` during a package install must not kill the install. xdg-terminal-exec picks the user's default terminal and maps `--app-id` onto that terminal's own flag through the `X-TerminalArgAppId` key of its desktop entry. VGS does not choose or configure the terminal.
- The app-id names a size class. `launch` reads it from `HyprlandLayer.TUI_WINDOWS` in `shell/Core/HyprlandLayer.js`, the table the Hyprland layer writes one window rule per class from; [hyprland.md § The file](hyprland.md#the-file) lists each class's app-id, rule and size. A caller picks a class, never a geometry.
- A terminal whose desktop entry has no `X-TerminalArgAppId` key opens the window without the app-id, so no rule for the class can match it and the window tiles.
- A floating TUI needs `xdg-terminal-exec` on the path, `gum` for the library's dialogs, and `setsid` and `script` from util-linux. Without `xdg-terminal-exec`, `launch` exits 69 with `terminal=missing`.
- On the owner's machine, read with `xdg-terminal-exec --print-id` on 2026-09-28, the default terminal is Ghostty 1.3.1 through `com.mitchellh.ghostty.desktop`. Its entry maps `--app-id` to `--class=`, and its `Exec` line forces `--gtk-single-instance=true`.
- Everything `present` needs reaches it in its argv. A single-instance terminal can open the window from a process that was already running, so the launcher's environment is not guaranteed to reach the command.

### Terminals

Whether a terminal honours the app-id depends on its desktop entry alone. The installed rows were read on the owner's machine on 2026-09-28 with `grep X-TerminalArg /usr/share/applications/*.desktop` and `xdg-terminal-exec --print-cmd --app-id=org.vgs.tui --title=T -- sleep 1` under a temporary `xdg-terminals.list` naming each entry, with xdg-terminal-exec 0.14.3.

| Terminal | Entry | `X-TerminalArgAppId` | Floats | Source |
|---|---|---|---|---|
| Ghostty 1.3.1 | `com.mitchellh.ghostty.desktop` | `--class=` | yes, read back below | installed entry; resolved command `ghostty --gtk-single-instance=true --class=org.vgs.tui --title=T -e sleep 1` |
| kitty 0.49.1 | `kitty.desktop` | `--class` | not run; the app-id reaches it | installed entry; resolved command `kitty --class org.vgs.tui --title T -- sleep 1` |
| Alacritty 0.17.0 | `Alacritty.desktop` | none | no: no app-id reaches it | installed entry; resolved command `alacritty -e sleep 1`, with no app-id and no title. Omarchy ships its own entry with `--class=` (`default/alacritty/Alacritty.desktop`, basecamp/omarchy `e332dc97`). |
| foot | `foot.desktop` | not read | not measured | not installed here. Omarchy ships its own entry with `--app-id=` (`applications/foot.desktop`, basecamp/omarchy `e332dc97`); the upstream entry was not read. |
| wezterm | not read | none as of 2025-08-04 | no: no app-id reaches it | not installed here; [wezterm issue 7129](https://github.com/wezterm/wezterm/issues/7129), open on that date, asks for the key. |

A user whose terminal lacks the key can add an entry of their own under `~/.local/share/applications/` with the key, as Omarchy does, or choose another default in `~/.config/xdg-terminals.list`.

### Ghostty in the nested sandbox

On 2026-09-28, on the owner's machine, a one-off script sourced `scripts/smoke/harness.sh`, wrote `com.mitchellh.ghostty.desktop` into the sandbox's own `xdg-terminals.list`, ran `bin/vgsh-tui launch --title "probe <size>" --size <size> -- sleep 60` for each size class, and read `hyprctl -j clients` back from the nested Hyprland v0.56.2 with Ghostty 1.3.1:

| Size | Class | Floating | Size | Centred on the work area |
|---|---|---|---|---|
| `default` | `org.vgs.tui` | true | 875 × 600 | yes |
| `wide` | `org.vgs.tui.wide` | true | 1200 × 720 | yes |
| `tall` | `org.vgs.tui.tall` | true | 875 × 900 | yes |

- A `default` launch while a Ghostty started as `ghostty --gtk-single-instance=true --class=org.example.other` was open gave the same reading, in a process of its own; the other window stayed as it was.
- `hyprctl -j configerrors` held no error before and after.
- No smoke row runs Ghostty. The nested smoke reports one verdict for all its rows, so a machine without Ghostty would turn every run into not-measured, and the smoke would depend on a terminal the sandbox does not own. The window rules are proven by `scripts/smoke/rows/hyprland.sh` with its own toplevel client; this run is the evidence for Ghostty.

## The presentation

- `present` clears the screen, prints the logo, runs argv and keeps its exit code. Unless the code is 130, a Ctrl-C, it prints `● Done! Press any key to close...` or `● Failed (exit code N)! Press any key to close...` and waits for one key. `present` exits with the command's code.
- The prompt goes to `/dev/tty`, not stdout, so a caller that redirects the output still sees it. Before it, `present` drops the bytes queued on the terminal: replies to queries the command sent the terminal would otherwise answer the keypress.
- `plain` skips the logo and the prompt, for a full-screen program that owns the window.
- A refusal of the plugin copy or script is reported under the same Failed prompt, so the window does not close before the user reads it.

## Colours

- `present` reads `${XDG_STATE_HOME:-~/.local/state}/vgs/theme/gum.env` at every run, so a TUI follows the theme applied last with no login-time environment. The `gum` theme target writes it: [theme-tool-targets.md § Floating TUI colours](theme-tool-targets.md#floating-tui-colours).
- The file is parsed, never sourced. Every line must be `KEY=#rrggbb` with a key that `bin/vgsh-tui`'s `gum_key` accepts: gum's own `GUM_*`, `FOREGROUND`, `BACKGROUND` and `BORDER_FOREGROUND` variables, and the library's `VGS_TUI_*` colours. One bad line rejects the whole file: `present` prints `vgsh-tui: gum-env=rejected line=<n> path=<file>`, exports none of it and runs the command with gum's defaults. An absent file exports nothing and prints nothing.
- The logo takes `VGS_TUI_ACCENT`, the prompt `VGS_TUI_SUCCESS` or `VGS_TUI_DANGER`, and the library's lines `VGS_TUI_ACCENT`, `VGS_TUI_WARNING` and `VGS_TUI_DANGER`, each as a truecolor escape with an ANSI fallback when the value is absent.

## A plugin's script

- With `--plugin <id> --dir <snapshot>`, argv[0] is a path relative to the plugin's published snapshot, inside its `tui/` directory.
- `present` copies the snapshot's `tui/` directory into a new directory under `$XDG_RUNTIME_DIR`, runs argv[0] from the copy, and removes the copy when it exits. The runner removes old snapshot roots when a shell starts ([runtime.md § Process](runtime.md#process)), so a `vgsh restart` during the run cannot remove a file the script sources.
- `present` exports `VGS_PLUGIN_ID` and `VGS_PLUGIN_DIR`, the copy, to the script. A core command gets neither, whatever the caller's environment held.
- argv[0] must resolve, after every link and `..`, to an executable file inside the copied `tui/` directory. Anything else is refused before it runs.

## The capability

A plugin declares its scripts as data in the manifest's `tui` key and opens them through `shell.tui`. It never hands the shell a command string.

- `tui: { <name>: { script, title, size, presentation, entry } }`. `<name>` is lower case letters, digits and dashes. `script` is a path under the plugin's `tui/` directory, and no segment is `.`, `..` or hidden. `title` is one printable line of at most 60 characters. `size` is a key of `HyprlandLayer.TUI_WINDOWS`, `default` when absent. `presentation` is `full` or `plain`, `full` when absent. `entry`, when present, is `{ label, icon, group }`: a printable label and group, and a Lucide icon of the shipped set. The key needs capability `tui`. `PluginLogic.tuiError` judges it.
- `bin/lib/check-manifests.js` also reads each script on disk: a regular file with its owner's execute bit, reached through no symbolic link. `bin/vgsh-scan` follows links when it publishes a snapshot, so a link would publish whatever it points at.
- `shell.tui.run(name, args)` opens one of the calling plugin's own scripts, from the snapshot of the revision its instance runs ([D014](../decisions/D014-source-revisions-are-published-snapshots.md)), with `args` as argv after the script. `args` is absent or a list of at most 16 strings of 1 to 256 characters, with no control character.
- `shell.tui.entries` lists every TUI with an `entry`: the core's own, keyed `core/<name>` from `PluginLogic.CORE_TUIS`, and every enabled plugin's, keyed `<plugin id>/<name>`, each as `{ key, plugin, name, title, label, icon, group }`. A disabled plugin's rows leave the list. A launcher lists other plugins' TUIs without naming those plugins ([D005](../decisions/D005-kinds-are-surfaces-no-dependencies.md)).
- A row of `PluginLogic.CORE_TUIS` is `{ argv, title, size, presentation, entry }` with every key set, `entry` null for a row that is not listed. `argv` starts with a file name of the core's `bin/` directory, `vgsh` or `vgsh-<word>`, and `open` runs that file from the `bin/` beside the shell directory, since the shell's `PATH` need not hold the core's commands. `PluginLogic.coreTuiTable` judges the table when the file loads and throws on a defect.
- `shell.tui.open(key)` opens any listed TUI with no arguments. The IPC functions `listTuis` and `openTui <key>` and the commands `vgsh tui list` and `vgsh tui open <key>` do the same from outside the shell.
- `run` and `open` answer `ok` once the launcher starts, or `refused: tui=<name> reason=` and, in this order, `undeclared`, `disabled`, `args` or `launcher-missing`. A request starts no launcher when it is refused.
- `shell/Core/TuiRunner.qml` holds the launcher state, `unknown`, `present` or `missing`. It runs `bin/vgsh-tui check`, which uses the same terminal test as `launch`, once when the shell starts. Each probe and each launch that exits 0 sets `present`, and exit 69 sets `missing`. While the state is `missing`, every request that passes the other checks answers `launcher-missing` at once and starts one probe, never two at a time, so a terminal installed later is found by a later request without a restart.
- A launch started while the state was `unknown` or `present` can still find no terminal. It has already answered `ok`, so `PluginLogic.tuiLaunchOutcome` logs `tui: refused: tui=<key> reason=launcher-missing` and the state moves to `missing`.
- `PluginLogic.js` makes every decision: the judge, the argument rule, the argv, the listed rows and the log line ([overview.md](overview.md) invariant 6). `scripts/test-tui-logic.js` pins each refusal by its text, with a control per rule. `scripts/smoke/rows/tui.sh` reads the argv back from a stand-in xdg-terminal-exec in the nested sandbox.

Omarchy's menu runs each entry's JSONC `action` string, and its bar runs `bash -lc` on a command string. VGS reads the same data from a judged manifest and hands the terminal an argv list, so no plugin text becomes shell code. `presentation: plain` is Omarchy's `omarchy-launch-tui`. Omarchy's launchers `exec setsid`; VGS forks with `setsid -f`, because the shell tracks the launcher it starts (basecamp/omarchy `e332dc97`).

## sudo

`vgsh sudo` is the core's time-boxed passwordless sudo grant: [D036](../decisions/D036-time-boxed-passwordless-sudo-grant.md). `bin/vgsh-sudo-grant` holds both halves, and its header states each verb, output line, refusal key and exit code.

- The core TUI `core/sudo-grant` runs `vgsh sudo grant` with no argument: a 15-minute grant, or a revoke while a grant is active.
- No grant is possible until the owner runs `vgsh sudo install`. It places `bin/lib/tmpfiles.d/vgs-sudo-grant.conf` as `/etc/tmpfiles.d/vgs-sudo-grant.conf`, then the root half at `/usr/local/bin/vgs-sudo-grant`. `grant` refuses a root half that differs from the checkout's file, and `vgsh sudo install` replaces it.
- A grant is one file, `/etc/sudoers.d/99-vgs-nopasswd-<uid>`. sudo refuses it after its `NOTAFTER` deadline, the timer `vgs-sudo-grant-expire-<uid>` removes it at the deadline, and the tmpfiles line removes it at boot.
- Both halves resolve commands in the system directories alone: `/usr/local/sbin`, `/usr/local/bin`, `/usr/sbin`, `/usr/bin`, `/sbin` and `/bin`. `grant` needs `sudo` with `-N`, `gum`, `visudo`, `systemd-run`, `systemctl`, `getent` and `flock` there.
- `uninstall` runs the boot cleanup's line through `systemd-tmpfiles --remove --boot` before it removes anything, so no account's grant outlives the file that ends it at boot.
- `status`, `grant` and `revoke` drop the sudo credential first and when they end, and run each root action through `sudo -N`, so each asks for the password unless a grant is active.

## Invariants

1. A command reaches the terminal as an argv list and never passes through a shell. Enforced by `scripts/test-vgsh-tui.sh`, which hands `present` an argument holding `$(...)` and `;`, with a control that runs argv through `bash -c`.
2. `gum.env` is parsed, never sourced, and a file with one bad line exports nothing. Enforced by `scripts/test-vgsh-tui.sh`, with a control that sources a file holding a planted `$(...)` line.
3. The Done and Failed prompt is on the terminal whatever stdout is. Enforced by `scripts/test-vgsh-tui.sh`, with a control that prompts on stdout.
4. A plugin's script runs from a private copy that outlives the snapshot and leaves with `present`. Enforced by `scripts/test-vgsh-tui.sh`, whose script removes its snapshot before it sources a file beside it, with a control that points `VGS_PLUGIN_DIR` at the snapshot.
5. A Ctrl-C stops the command, and `present` exits 130 with no prompt and no plugin copy left. Enforced by `scripts/test-vgsh-tui.sh`, which types the interrupt byte on the pseudo-terminal while a command sleeps, with a control whose `present` ignores SIGINT.
6. A sudo session drops the credential when it ends, when the script exits and when it is hung up or terminated, and leaves no keepalive. Enforced by `scripts/test-tui.sh` with a stand-in `sudo`, with a control that skips the final `sudo -k`.
7. `launch` forks the terminal into a session of its own and returns, and `check` answers with the terminal test `launch` uses. Enforced by `scripts/test-vgsh-tui.sh` with a stand-in `setsid`, with a control that execs `setsid` without `-f` and one whose `check` skips the test.
8. A plugin opens only a script its manifest declares, from its published snapshot, and only while it is enabled. While the launcher is `missing`, every request answers `launcher-missing` and starts no launcher. Enforced by `scripts/test-tui-logic.js`, with a control that drops each rule, and by `scripts/smoke/rows/tui.sh` in the nested sandbox, which swaps in a launcher that finds no terminal and then restores it.
9. A grant is a rule `visudo` accepted, for 1 to 1440 minutes, for the caller's own account, published by rename after its expiry is armed, only while the boot cleanup is in place and only after one question that `VGS_TUI_UNATTENDED` never answers; a grant sudo does not honour is revoked, a second `grant` revokes, and `uninstall` removes every account's grant before the root half and the boot cleanup. Enforced by `scripts/test-vgsh-sudo-grant.sh` under a temporary prefix with stand-in `sudo`, `visudo`, `systemd-run`, `systemctl`, `getent` and `gum`, with copies that skip each check as its controls.
10. The root half runs only under `bash -p`, with an environment of `PATH`, `LC_ALL` and `SUDO_UID` alone, and takes `__status`, `__enable` and `__disable` for `SUDO_UID`'s uid and nothing else. Enforced by `scripts/test-vgsh-sudo-grant.sh`, which runs it under `unshare -r`, with copies that skip the startup, environment and caller checks as its controls.

## Omarchy

Omarchy's `omarchy-launch-floating-terminal-with-presentation`, `omarchy-show-logo` and `omarchy-show-done` (basecamp/omarchy `e332dc97`) are the model. VGS takes the app-id and window-rule mechanism, the logo, Done and Failed contract with its skip on 130, the drain of queued replies on `/dev/tty`, the parse of the gum colour file, and the sudo keepalive. It differs where [D033](../decisions/D033-floating-tuis-are-core.md) states. `vgsh sudo grant` follows `omarchy-sudo-passwordless` and differs where [D036](../decisions/D036-time-boxed-passwordless-sudo-grant.md) states.
