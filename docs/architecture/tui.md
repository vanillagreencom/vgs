# Floating TUIs

Covers: bin/vgsh-tui, bin/lib/tui.sh, bin/lib/logo.txt, scripts/test-vgsh-tui.sh, scripts/test-tui.sh

A floating TUI is a themed terminal window that floats over the session and runs one command under the VGS presentation: the logo, the command, then Done or Failed and a keypress. A flow that asks for a password or a `[y/N]` answer runs in one, so the user answers in a terminal they see, never in the shell process. It is a core concept: [D033](../decisions/D033-floating-tuis-are-core.md).

## The parts

- `bin/vgsh-tui` is the only file that knows terminals. `launch` opens the window and `present` runs inside it. Their options, exit codes and refusal keys are in the file's header.
- `bin/lib/tui.sh` is the library a TUI script sources through `$VGS_TUI_LIB`: step and warning lines, a header box, gum questions, one sudo authorization per script, a lock, a log and a reboot check. Its header lists each function and its return codes.
- `bin/lib/logo.txt` is the wordmark `present` prints in the theme accent.
- `vgsh tui present [--title T] [--size S] -- argv...` is the core's own entry: it hands argv to `vgsh-tui launch` with the full presentation and needs no shell running.

## The window

- `launch` execs `setsid xdg-terminal-exec --app-id=<app-id> --title="VGS · <title>" -- vgsh-tui present ...`. xdg-terminal-exec picks the user's default terminal and maps `--app-id` onto that terminal's own flag through the `X-TerminalArgAppId` key of its desktop entry. VGS does not choose or configure the terminal.
- The app-id names a size class. `launch` reads it from `HyprlandLayer.TUI_WINDOWS` in `shell/Core/HyprlandLayer.js`, the table the Hyprland layer writes one window rule per class from; [hyprland.md § The file](hyprland.md#the-file) lists each class's app-id, rule and size. A caller picks a class, never a geometry.
- A terminal whose desktop entry has no `X-TerminalArgAppId` key opens the window without the app-id, so no rule for the class can match it.
- A floating TUI needs `xdg-terminal-exec` on the path, `gum` for the library's dialogs, and `setsid` and `script` from util-linux. Without `xdg-terminal-exec`, `launch` exits 69 with `terminal=missing`.
- On the owner's machine, read with `xdg-terminal-exec --print-id` on 2026-09-28, the default terminal is Ghostty 1.3.1 through `com.mitchellh.ghostty.desktop`. Its entry maps `--app-id` to `--class=`, and its `Exec` line forces `--gtk-single-instance=true`.
- Everything `present` needs reaches it in its argv. A single-instance terminal can open the window from a process that was already running, so the launcher's environment is not guaranteed to reach the command.

## The presentation

- `present` clears the screen, prints the logo, runs argv and keeps its exit code. Unless the code is 130, a Ctrl-C, it prints `● Done! Press any key to close...` or `● Failed (exit code N)! Press any key to close...` and waits for one key. `present` exits with the command's code.
- The prompt goes to `/dev/tty`, not stdout, so a caller that redirects the output still sees it. Before it, `present` drops the bytes queued on the terminal: replies to queries the command sent the terminal would otherwise answer the keypress.
- `plain` skips the logo and the prompt, for a full-screen program that owns the window.
- A refusal of the plugin copy or script is reported under the same Failed prompt, so the window does not close before the user reads it.

## Colours

- `present` reads `${XDG_STATE_HOME:-~/.local/state}/vgs/theme/gum.env` at every run, so a TUI follows the theme applied last with no login-time environment.
- The file is parsed, never sourced. Every line must be `KEY=#rrggbb` with a key that `bin/vgsh-tui`'s `gum_key` accepts: gum's own `GUM_*`, `FOREGROUND`, `BACKGROUND` and `BORDER_FOREGROUND` variables, and the library's `VGS_TUI_*` colours. One bad line rejects the whole file: `present` prints `vgsh-tui: gum-env=rejected line=<n> path=<file>`, exports none of it and runs the command with gum's defaults. An absent file exports nothing and prints nothing.
- The logo takes `VGS_TUI_ACCENT`, the prompt `VGS_TUI_SUCCESS` or `VGS_TUI_DANGER`, and the library's lines `VGS_TUI_ACCENT`, `VGS_TUI_WARNING` and `VGS_TUI_DANGER`, each as a truecolor escape with an ANSI fallback when the value is absent.

## A plugin's script

- With `--plugin <id> --dir <snapshot>`, argv[0] is a path relative to the plugin's published snapshot, inside its `tui/` directory.
- `present` copies the snapshot's `tui/` directory into a new directory under `$XDG_RUNTIME_DIR`, runs argv[0] from the copy, and removes the copy when it exits. The runner removes old snapshot roots when a shell starts ([runtime.md § Process](runtime.md#process)), so a `vgsh restart` during the run cannot remove a file the script sources.
- `present` exports `VGS_PLUGIN_ID` and `VGS_PLUGIN_DIR`, the copy, to the script. A core command gets neither, whatever the caller's environment held.
- argv[0] must resolve, after every link and `..`, to an executable file inside the copied `tui/` directory. Anything else is refused before it runs.

## Invariants

1. A command reaches the terminal as an argv list and never passes through a shell. Enforced by `scripts/test-vgsh-tui.sh`, which hands `present` an argument holding `$(...)` and `;`, with a control that runs argv through `bash -c`.
2. `gum.env` is parsed, never sourced, and a file with one bad line exports nothing. Enforced by `scripts/test-vgsh-tui.sh`, with a control that sources a file holding a planted `$(...)` line.
3. The Done and Failed prompt is on the terminal whatever stdout is. Enforced by `scripts/test-vgsh-tui.sh`, with a control that prompts on stdout.
4. A plugin's script runs from a private copy that outlives the snapshot and leaves with `present`. Enforced by `scripts/test-vgsh-tui.sh`, whose script removes its snapshot before it sources a file beside it, with a control that points `VGS_PLUGIN_DIR` at the snapshot.
5. A sudo session drops the credential when it ends, when the script exits and when it is hung up or terminated, and leaves no keepalive. Enforced by `scripts/test-tui.sh` with a stand-in `sudo`, with a control that skips the final `sudo -k`.

## Omarchy

Omarchy's `omarchy-launch-floating-terminal-with-presentation`, `omarchy-show-logo` and `omarchy-show-done` (basecamp/omarchy `e332dc97`) are the model. VGS takes the app-id and window-rule mechanism, the logo, Done and Failed contract with its skip on 130, the drain of queued replies on `/dev/tty`, the parse of the gum colour file, and the sudo keepalive. It differs where [D033](../decisions/D033-floating-tuis-are-core.md) states.
