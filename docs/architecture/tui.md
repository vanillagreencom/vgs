# Floating TUIs

Covers: bin/vgsh-tui, bin/lib/tui.sh, bin/lib/logo.txt, scripts/test-vgsh-tui.sh, scripts/test-tui.sh

A floating TUI is a themed terminal window that floats over the session and runs one command under the VGS presentation: the logo, the command, then Done or Failed and a keypress. A flow that asks for a password or a `[y/N]` answer runs in one, so the user answers in a terminal they see, never in the shell process. It is a core concept: [D033](../decisions/D033-floating-tuis-are-core.md).

## The parts

- `bin/vgsh-tui` is the only file that knows terminals. `launch` opens the window, `present` runs inside it, `wait` blocks on one run's lock until the presenter ends, and `reap` ends orphaned running records. Their options, exit codes and refusal keys are in the file's header.
- `bin/lib/tui.sh` is the library a TUI script sources through `$VGS_TUI_LIB`: step and warning lines, a header box, gum questions, one sudo authorization per script, a lock, a log and a reboot check. Its header lists each function and its return codes.
- A sudo session exports its script's pid as `VGS_TUI_SUDO_SESSION`. A session started in a command that script runs, while that pid is alive, joins it: it asks only when the credential lapsed, and it drops nothing when it ends. The Updates pipeline holds one session and runs `vgsh pkg run upgrade` inside it, so the password is asked once and the pipeline's later steps keep the credential. Omarchy's `OMARCHY_UPDATE_SUDO_SESSION` is the model (basecamp/omarchy `e332dc97`).
- `bin/lib/logo.txt` is the wordmark `present` prints in the theme accent.
- `vgsh tui present [--title T] [--size S] -- argv...` is the core's own entry: it hands argv to `vgsh-tui launch` with the full presentation and needs no shell running.
- The manifest key `tui` and the capability `tui` let a plugin open the scripts it declares, and list and open any listed TUI: [tui-capability.md](tui-capability.md).
- An exit record tells the core when a run started and ended and with which code, so a caller learns that its TUI ended and a second click raises the open window. `wait` makes the end independent of directory change delivery: [tui-records.md § Exit records](tui-records.md#exit-records).
- `vgsh sudo` is the core's time-boxed passwordless sudo grant, which the core TUI `core/sudo-grant` runs: [tui-sudo.md](tui-sudo.md).

## The window

- `launch` runs `setsid -f xdg-terminal-exec --app-id=<app-id> --title="VGS · <title>" -- vgsh-tui present ...` and exits 0 once setsid has forked it into a session of its own, or, for a run with a record, once the presenter wrote the record ([tui-records.md § Exit records](tui-records.md#exit-records)). The terminal outlives whatever started `launch`: Quickshell kills the processes it started when the shell stops, and a `vgsh restart` during a package install must not kill the install. xdg-terminal-exec picks the user's default terminal and maps `--app-id` onto that terminal's own flag through the `X-TerminalArgAppId` key of its desktop entry. VGS does not choose or configure the terminal.
- `launch` removes `VGSH_RUNNER_PID`, which `vgsh pkg run` refuses, from the terminal's environment, which a single-instance terminal hands to later windows.
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
- `plain` skips the logo and the prompt, for a full-screen program that owns the window. The prompt is the library's `vgs_tui_close_prompt`, so a `plain` script that fails before its program takes the window calls it itself, and the user reads the failure before the window closes; `vgs.updates`'s `log` TUI does.
- A refusal of the plugin copy or script is reported under the same Failed prompt, so the window does not close before the user reads it.

## Colours

- `present` reads `${XDG_STATE_HOME:-~/.local/state}/vgs/theme/gum.env` at every run, so a TUI follows the theme applied last with no login-time environment. The `gum` theme target writes it: [theme-tool-targets.md § Floating TUI colours](theme-tool-targets.md#floating-tui-colours).
- The file is parsed, never sourced. Every line must be `KEY=#rrggbb` with a key that `bin/vgsh-tui`'s `gum_key` accepts: gum's own `GUM_*`, `FOREGROUND`, `BACKGROUND` and `BORDER_FOREGROUND` variables, and the library's `VGS_TUI_*` colours. One bad line rejects the whole file: `present` prints `vgsh-tui: gum-env=rejected line=<n> path=<file>`, exports none of it and runs the command with gum's defaults. An absent file exports nothing and prints nothing.
- The logo takes `VGS_TUI_ACCENT`, the prompt `VGS_TUI_SUCCESS` or `VGS_TUI_DANGER`, and the library's lines `VGS_TUI_ACCENT`, `VGS_TUI_WARNING` and `VGS_TUI_DANGER`, each as a truecolor escape with an ANSI fallback when the value is absent.

## A plugin's script

- With `--plugin <id> --dir <snapshot>`, argv[0] is a path relative to the plugin's published snapshot, inside its `tui/` directory.
- `present` copies the whole snapshot under `$XDG_RUNTIME_DIR`, runs argv[0] from the copy and removes the copy when it exits. A shell start removes old snapshot roots ([runtime.md § Process](runtime.md#process)), so a `vgsh restart` cannot remove a file the script reads ([D042](../decisions/D042-tui-scripts-run-from-a-copy-of-the-whole-snapshot.md)).
- `present` exports `VGS_PLUGIN_ID` and `VGS_PLUGIN_DIR`, the copy, to the script. A core command gets neither, whatever the caller's environment held.
- argv[0] must resolve, after every link and `..`, to an executable file inside the copied `tui/` directory. Anything else is refused before it runs.

## Invariants

1. A command reaches the terminal as an argv list and never passes through a shell. Enforced by `scripts/test-vgsh-tui.sh`, which hands `present` an argument holding `$(...)` and `;`, with a control that runs argv through `bash -c`.
2. `gum.env` is parsed, never sourced, and a file with one bad line exports nothing. Enforced by `scripts/test-vgsh-tui.sh`, with a control that sources a file holding a planted `$(...)` line.
3. The Done and Failed prompt is on the terminal whatever stdout is. Enforced by `scripts/test-vgsh-tui.sh`, with a control that prompts on stdout.
4. A plugin's script runs from a private copy that outlives the snapshot and leaves with `present`. Enforced by `scripts/test-vgsh-tui.sh`, whose script removes its snapshot before it sources a file in `tui/` and one at the root, with controls that point `VGS_PLUGIN_DIR` at the snapshot and copy only `tui/`.
5. A Ctrl-C stops the command, and `present` exits 130 with no prompt and no plugin copy left. Enforced by `scripts/test-vgsh-tui.sh`, which types the interrupt byte on the pseudo-terminal while a command sleeps, with a control whose `present` ignores SIGINT.
6. A sudo session drops the credential when it ends, when the script exits and when it is hung up or terminated, and leaves no keepalive. A nested session under a live owner drops nothing, and one whose owner is gone starts its own. A guard asks for nothing and drops the credential in the same cases. Enforced by `scripts/test-tui.sh` with a stand-in `sudo`, with a control that skips the final `sudo -k`, one that never joins, one that joins an owner that is gone and one whose guard sets no trap.
7. `launch` forks the terminal into a session of its own and returns, and `check` answers with the terminal test `launch` uses. Enforced by `scripts/test-vgsh-tui.sh` with a stand-in `setsid`, with a control that execs `setsid` without `-f` and one whose `check` skips the test. Its terminal gets no `VGSH_RUNNER_PID`; a control keeps it.
8. `wait` exits after the presenter's run lock is released and writes a dead presenter's ended record with no polling. A later run of the key does not delay it, and a run whose records a later run removed exits 3, `reason=gone`, never 1. Enforced by `scripts/test-vgsh-tui.sh`, which measured 0 ms on cachy x86_64 on 2026-09-29 from the shell's reap of the presenter to its reap of wait, and pins a 1000 ms ceiling. A value of 0 means under 1 ms at the measurement resolution. It repeats back-to-back runs of one key 50 times, with the wait held by SIGSTOP so the order is fixed. Controls skip the lock, wait on the key lock, exit 1 for a gone run and skip the dead-run end.

## Omarchy

Omarchy's `omarchy-launch-floating-terminal-with-presentation`, `omarchy-show-logo` and `omarchy-show-done` (basecamp/omarchy `e332dc97`) are the model. VGS takes the app-id and window-rule mechanism, the logo, Done and Failed contract with its skip on 130, the drain of queued replies on `/dev/tty`, the parse of the gum colour file, and the sudo keepalive. It differs where [D033](../decisions/D033-floating-tuis-are-core.md) states.
