# D033: Floating TUIs are a core concept

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: [docs/plans/v2-platform-roadmap.md](../plans/v2-platform-roadmap.md) § 1

**Context**: VGS had no terminal window of its own. `vgsh plugin update` and `vgsh theme update` refuse `no-terminal` from the GUI, because the diff review is a question someone must answer. Updates, package installs, a passwordless sudo grant and plugin requirements all need a place where the user sees a password prompt or a `[y/N]` and answers it, and the shell process must never be that place. Omarchy solves this with one launcher script, `omarchy-launch-floating-terminal-with-presentation`, an app-id its window rule floats, and two helpers, `omarchy-show-logo` and `omarchy-show-done` (basecamp/omarchy `e332dc97`).

**Decision**: A floating TUI is a core concept. `bin/vgsh-tui` is the only file that knows terminals: `launch` opens the user's default terminal through `xdg-terminal-exec` with an app-id from one family, `org.vgs.tui`, `org.vgs.tui.wide` or `org.vgs.tui.tall`, and `present` runs one command inside it as an argv list under the VGS presentation: the logo in the theme accent, the command, then `● Done!` or `● Failed (exit code N)!` on `/dev/tty` and one key, skipped on 130. `bin/lib/tui.sh` is the one presentation library TUI scripts source. Colours come from a `gum.env` file that `present` parses at every run and never sources. A plugin's script runs from a private copy of its snapshot's `tui/` directory. `vgsh tui present` is the core's own entry. The window rule for the app-id family is one constant core section of the Hyprland layer, written from `HyprlandLayer.TUI_WINDOWS`, the same table `launch` reads each class's app-id from; the `tui` manifest key and capability open only a plugin's declared scripts, from its published snapshot, with an argv list. The capability's contract: `shell.tui.run(name, args)` opens one of the caller's own scripts while it is enabled, with at most 16 printable arguments; `shell.tui.entries` lists every TUI with an `entry`, the core's `core/<name>` and every enabled plugin's `<plugin id>/<name>`; `shell.tui.open(key)` opens a listed key with no arguments, as the IPC function `openTui` and `vgsh tui open` do. Each answers `ok` once the launcher starts or `refused: tui=<name> reason=undeclared|args|disabled`, and `PluginLogic.js` makes each decision. `launch` forks the terminal off with `setsid -f` and returns, so the shell learns the launcher's exit, 69 being `launcher-missing`, which it logs, and a shell restart never kills a terminal. [tui.md](../architecture/tui.md) holds the contract.

**Rationale**:

- The core needs it before any plugin does: plugin and theme update, the package layer and the requirement install run core commands that ask questions.
- It touches three core systems: the Hyprland layer ([D028](D028-one-generated-hyprland-layer.md): no plugin writes Hyprland text), the theme targets and the capability set. A plugin cannot own any of them.
- An argv list never becomes shell code, so a title, an argument or a plugin's manifest text cannot run as a command.
- A declared script from the published snapshot keeps [D014](D014-source-revisions-are-published-snapshots.md)'s "the reviewed revision runs" and [D007](D007-install-runs-no-plugin-code.md)'s review step.
- One size class per app-id lets a caller pick a window size without writing geometry, so no plugin text reaches a window rule.

## Where VGS differs from Omarchy

| Omarchy | VGS | Why |
|---|---|---|
| The launcher hands the command to `bash -c "$*"`. | `present` runs argv as a list. | Text from a plugin or a caller never becomes shell code. |
| `omarchy-launch-or-focus` runs `eval exec setsid $LAUNCH_COMMAND`, and the menu runs `bash -lc <string>`. | No `eval`, no shell string at any step. | The same reason. |
| Menu entries are JSONC `action` strings with bash `when` conditions, and `omarchy-launch-tui` execs `setsid`. | A plugin's TUIs are judged manifest data, opened by name or key, and `launch` forks with `setsid -f`. | A launcher lists any plugin's TUIs without code, and the shell tracks the launcher it starts, so the terminal must not be that process. |
| The launcher runs under `uwsm-app`. | `setsid` alone. | VGS has no uwsm dependency. |
| `omarchy-default-terminal` rewrites the user's `xdg-terminals.list`. | VGS reads the user's default and never writes it. | VGS does not own the terminal choice. |
| Gum colours reach the session through login-time `hl.env` lines, and the launcher re-exports them from the generated file each time. | `present` parses `gum.env` from the theme state directory at every run. | A file read at each run follows every apply, with no environment that goes stale after a theme switch. |
| The colour file is parsed with awk and each pair exported. | Every line must match one rule, or none is used. | A file that runs code is refused whole, not in part. |
| The logo is ANSI green. | The logo is the theme accent. | The accent is the VGS colour, and it follows the theme. |
| One app-id, `org.omarchy.terminal`, tagged `floating-window` at 875×600. | Three app-ids, one per size class, each matched exactly. | A long update log or a package picker needs more room than a confirm; the class names the size. |
| Step lines are inline escapes in each script. | Library functions. | One place for each line's look. |
| The sudo keepalive is a separate executable. | A library function tied to the script's pid and ended on exit, hang-up and termination. | The credential leaves with the script that asked for it. |
| Scripts run from the Omarchy checkout. | A plugin's script runs from a private copy of its snapshot's `tui/`. | A restart removes old snapshots while the script may still source a file beside it. |

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Omarchy's string launcher: `vgsh-launch-floating "<cmd>"` into `bash -c` | Plugin text becomes shell code, every plugin invents its own script location, colours and ending, and nothing ties a launch to the plugin's manifest. |
| A TUI drawn in QML: a panel with a log view and native dialogs | It re-implements a pty, gum's widgets, fzf and sudo's password prompt. Package managers, AUR helpers and `passwd` expect a real terminal. |
| Plugin-authored window rules as manifest data | It reopens D028's plugin data scope for a need three size classes already meet, and puts more judged text into Lua. |
| A `vgs.system` plugin holding update, install and sudo flows | The core itself uses those flows: the requirement install needs the package layer, and plugin update needs the terminal. A plugin would be a second owner of package flows and a core feature behind a plugin toggle. |

**Revisit When**: xdg-terminal-exec drops `--app-id`, or the owner's default terminal stops honouring it; gum changes its environment variable names or how it reads the terminal; a TUI needs a geometry no size class covers.

**Verification**: `scripts/test-tui-logic.js` pins each refusal of the `tui` key and of a request by its text, with a control per rule; `bin/lib/check-manifests.js` refuses a script that is a link, not a regular file or not executable, pinned by `scripts/test-check-manifests.js`; `scripts/smoke/rows/tui.sh` reads the argv a stand-in xdg-terminal-exec records in the nested sandbox, each refusal, the `launcher-missing` line and a disabled plugin's list. `scripts/test-vgsh-tui.sh` runs `present` on a pseudo-terminal against stub commands exiting 0, 1 and 130, and `launch` and `vgsh tui present` against a stub `xdg-terminal-exec`, with controls that source `gum.env`, prompt on stdout, run argv through `bash -c`, point `VGS_PLUGIN_DIR` at the snapshot, drop a size and exec `setsid` without `-f`, and pins `vgsh tui list` and `vgsh tui open` against a stub `qs`. `scripts/test-tui.sh` covers the library with stand-ins for gum, sudo, uname and pgrep.

**References**: [tui.md](../architecture/tui.md), [D007](D007-install-runs-no-plugin-code.md), [D014](D014-source-revisions-are-published-snapshots.md), [D028](D028-one-generated-hyprland-layer.md), [runtime.md § Process](../architecture/runtime.md#process)
