# Requirements

Covers: config/requirements.json, bin/vgsh-plugin-judge, scripts/test-vgsh-plugin-list.sh

A requirement is an external command a plugin, or the core, runs: a program on PATH that VGS does not ship. A manifest declares its plugin's requirements as data, the core probes them on every scan, and the manager reports each one's state. [D035](../decisions/D035-manifest-requirements.md) records the choice.

## Declaration

A manifest's `requirements` key, and the core's own `config/requirements.json`, hold one list. `PluginLogic.requirementsError` judges both, and `scripts/test-plugin-logic.js` pins each refusal by its text.

| Field | Required | Meaning |
|---|---|---|
| `command` | yes | A bare command name looked up on PATH, `PackageManagers.validCommand`'s grammar, declared once per list. |
| `packages` | no | The package that provides the command, keyed by manager id of `shell/Core/PackageManagers.js`, each a name `PackageManagers.validName` accepts: `{ "pacman": "pacman-contrib", "aur": "vsys" }`. `{}` when absent. |
| `optional` | no | `true` when the plugin works without the command. `false` when absent. |
| `purpose` | yes | One printable line of 1 to 120 characters saying what the command is for. |

- A requirement names a command, never a plugin. A manifest `requires` key is refused by name, and a command spelt as a plugin id, lower case and dotted like `acme.clock`, is refused. A command such as `mkfs.ext4` has that spelling too; a plugin declares an undotted command from the same package instead.
- The manager ids and the package-name grammar are the package-manager table's, [packages.md](packages.md), so every declared package is one `vgsh pkg` can plan.
- A validated manifest carries every entry with all four fields.

## Probe

- `bin/vgsh-scan` reads each manifest's `requirements` and probes every `command` it finds with `shutil.which`, once per command per scan, in the scan's own process. Each plugin element carries `missing`, the commands not found, in declaration order. The scan judges nothing; a refused manifest's list is never read.
- The shell's PATH decides: the scan runs as the shell's child.
- A rescan is the only new probe. A command installed while the shell runs is reported present after the next rescan.

## Reports

- `Registry.missingCommands` holds each listed plugin's missing commands and is replaced only when a scan finds a different set, so an installed or removed command rebuilds nothing.
- `PluginLogic.requirementRows` gives each requirement its `state`: `missing` when the last scan did not find its command, else `present`. The manager rows ([manager.md](manager.md)) and each `listPlugins` plugin row carry these rows as `requirements`.
- `vgsh plugin list` prints one line per missing requirement: `missing <id> <command> (<package>)`, with ` optional` after an optional one. The package is the one `PackageManagers.packageFor` picks from `vgsh pkg detect`: the primary's, then an overlay's, then a source's. With no present manager mapped the line names the command alone. Detection runs once per list, and only when a missing requirement names a package; a detection that fails refuses the list with `detect=failed exit=<status>`.
- `config/requirements.json` holds the core's own commands: `node`, `python3`, `git` and `flock`, and, optional, the floating TUIs' `xdg-terminal-exec`, `gum` and `fzf`. Each package name was checked against its distribution's package index.

## Boundary

Nothing here installs a package or asks for a privilege. A requirement is data the manager reads; installing one is a core TUI the user starts, where the package manager asks for root in the user's terminal ([D034](../decisions/D034-one-package-manager-table.md), [D007](../decisions/D007-install-runs-no-plugin-code.md)).

## Invariants

1. A requirement never names a plugin. Enforced by `scripts/test-plugin-logic.js`, which fails on a judge copy that accepts a plugin id and on one that drops the `requires` refusal.
2. Every declared command is probed on the shell's PATH, once per scan. Enforced by `scripts/test-vgsh-scan.py` with a stub PATH, whose control is a scanner that finds every command, and in the nested sandbox by `scripts/smoke/rows/plugins.sh` and `scripts/smoke/rows/manager.sh`, which read a fixture's present and missing commands back from `listPlugins` and the manager rows.
3. `vgsh plugin list` names each missing command with this system's package. Enforced by `scripts/test-vgsh-plugin-list.sh`, which binds a fixture os-release under `unshare -rm`, and by `scripts/test-vgsh-pkg.js` for the pick.
4. The core's own list passes the manifest's judge. Enforced by `scripts/test-plugin-logic.js`.
