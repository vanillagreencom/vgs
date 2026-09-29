# D035: A manifest declares the external commands a plugin runs, and the core probes and reports them

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: [v2-platform-roadmap.md](../plans/v2-platform-roadmap.md) § 3, VGS-520

**Refines**: [D007](D007-install-runs-no-plugin-code.md)

**Context**: A plugin that runs `gum`, `vsys` or `checkupdates` had no way to say so. An unknown manifest key refuses the manifest, [D005](D005-kinds-are-surfaces-no-dependencies.md) refuses `requires`, and [D007](D007-install-runs-no-plugin-code.md) gave a system package no key at all. A user enabled such a plugin and learned of the missing command only when the plugin failed. The core itself needs `node`, `python3`, `git`, `flock`, and for its floating TUIs `xdg-terminal-exec`, `gum` and `fzf`, and no file listed them.

**Decision**: A manifest's `requirements` key lists the external commands the plugin runs, each as `{ command, packages, optional, purpose }`: a bare command name, the package that provides it per manager id of the package-manager table ([D034](D034-one-package-manager-table.md)), whether the plugin works without it, and one printable line of at most 120 characters. `PluginLogic.requirementsError` judges the list, and the core's own list, `config/requirements.json`, passes the same function. A requirement names a command, never a plugin: `requires` stays refused by name, and a command spelt as a plugin id is refused. `bin/vgsh-scan` probes every declared command once per scan, in its own process, the core's list among them, and reports the ones not on PATH. The registry hands each plugin's requirements with their state to the manager rows and to `listPlugins`, and `vgsh plugin list` prints `missing <id> <command> (<package>)`, the package the detected manager installs. The requirement is data the scan reads; the core installs a package only when the user asks.

The requirement notice ([requirement-notice.md](../architecture/requirement-notice.md)) is how the user asks from the shell. It is core, so it works with any set of plugins. Five triggers raise it: `vgsh plugin add` through the shell's `pluginInstalled` IPC function, enabling the plugin, the Settings window's Install through the `manager` capability's `installRequirements`, the plugin's own `requirements` capability, which may offer only commands its manifest declares and is refused for 10 minutes after the user answers the plugin's notice Not now, and the `doctor` capability. `doctor` is for a view of every owner's requirements, such as the Dev Tools panel's VGS section: on the user's press it raises the notice for the core's own commands or an enabled plugin's, each declared by that owner, and reads the scan's missing commands of the core and of every enabled plugin, as `shell.requirements.missing` reads a plugin's own. The install, enable, Settings and `doctor` triggers are the user's own acts, so no rest refuses them. The notice lists each missing command with this system's package. Install runs one manager's packages per press, primary first, through the core TUI `core/requirements-install`, `vgsh pkg run install`, where the package manager asks for root. The notice leaves the screen while its install runs, so the terminal shows whole, and only the scan after the run, when it finds the required commands, closes it.

**Rationale**:

- A requirement is a fact about the system, not about another plugin. D005's reason, no dependency graph and no plugin naming another, holds.
- One probe per scan, in the process that already reads every manifest, costs no process per plugin and no process per command (`docs/architecture/runtime.md` § Performance).
- One judge per question ([D009](D009-one-manifest-judge-under-node.md)): the manager ids and the package-name grammar come from the table `vgsh pkg` runs, so a declared package is one the table can install.
- Reporting the state beside each plugin tells a user what to install before the plugin fails, from the CLI and from the manager rows alike.
- One install path: a view that lists other owners' requirements raises the same notice through `doctor` rather than running `vgsh pkg run` itself, so no plugin carries a second install route.
- The notice turns the report into one press without a new privilege path: the install is the same `vgsh pkg run` the CLI offers, in a terminal the user watches. Limiting a plugin's offer to its declared commands keeps a plugin from asking for arbitrary packages, and the rest after Not now keeps it from asking again and again. Closing on the rescan, not on the install's exit code, closes the notice only when the command is really on PATH.

## Where VGS differs from Omarchy

Omarchy (`basecamp/omarchy`, `main`) probes a command where it is used, `omarchy-cmd-present` and `omarchy-cmd-missing` over `command -v`, and installs a missing app from a menu row whose script names its package: `omarchy-install-and-launch <name> <packages> <desktop-id>` runs `omarchy-pkg-add` inside its floating terminal.

| Omarchy | VGS | Why |
|---|---|---|
| Each menu script names its package for pacman and the AUR. | Each plugin declares its commands and a package per manager as manifest data, judged at load. | VGS is not the distribution and runs on several package managers; a plugin is third-party code whose declarations the core must judge. |
| A script probes with `command -v` each time it runs. | The scanner probes every declared command once per scan and the registry keeps the answer. | The manager rows and `vgsh plugin list` read one answer; no row starts a process. |
| The install runs in the floating terminal when the user picks the row. | The same: Install on the requirement notice opens a core TUI running `vgsh pkg run install`. | The package manager asks for root in a terminal the user watches; the shell never elevates ([D034](D034-one-package-manager-table.md)). |
| `omarchy-default-terminal` finds its terminal missing and runs itself again with `--install` in its floating terminal (`e332dc97`). | The core notice asks first, for any plugin's declared commands, then installs in its floating TUI. | One core path serves every plugin; a plugin names its commands as data and never runs a package manager itself. |

## Alternatives considered

- **A plugin-to-plugin dependency key.** Refused by D005: a load order, refusals to explain, and a plugin that breaks when another is disabled.
- **A probe per plugin at build time.** A process per plugin per rebuild, and the answer would live in each instance instead of the registry the manager reads.
- **Accepting any dotted command.** `mkfs.ext4` is a real command, but a lower-case dotted name reads as a plugin id such as `acme.clock`, and the judge cannot tell them apart. A plugin declares an undotted command from the same package instead.

**Revisit When**: A plugin needs a requirement that is not a command on PATH, such as a library, a service or a kernel module; or a real command a plugin needs cannot be declared under an undotted name.

**Verification**: `scripts/test-plugin-logic.js` pins each refusal by its text, judges `config/requirements.json`, and fails on a copy of the judge without each rule, the plugin-id rule among them. `scripts/test-vgsh-scan.py` runs the probe with a stub PATH, with a scanner that finds every command as its control, and probes the core's list, with a scanner that reads it as a manifest as its control. `scripts/test-vgsh-pkg-table.js` pins the package choice per detected system. `scripts/test-vgsh-plugin-list.sh` pins the `missing` lines. `scripts/smoke/rows/plugins.sh` and `scripts/smoke/rows/manager.sh` read a fixture's missing command back from `listPlugins` and the manager rows in the nested sandbox. `scripts/test-notice-logic.js` pins each notice decision, the declared-command rule, the rest and the `doctor` owner rule among them, with a judge copy per rule as control. `scripts/smoke/rows/devtools.sh` raises the notice through `doctor` from the Dev Tools panel and reads the capability's answers for the core and for a disabled and an unknown owner. `scripts/smoke/rows/notices.sh` raises the notice through `vgsh plugin add` and through enabling, installs through the core TUI and closes it on a rescan, and `scripts/smoke/rows/notices-control.sh` runs a shell copy without the enable trigger as its control.

**References**: [D005](D005-kinds-are-surfaces-no-dependencies.md), [D007](D007-install-runs-no-plugin-code.md), [D009](D009-one-manifest-judge-under-node.md), [D034](D034-one-package-manager-table.md), [requirements.md](../architecture/requirements.md), [requirement-notice.md](../architecture/requirement-notice.md)
