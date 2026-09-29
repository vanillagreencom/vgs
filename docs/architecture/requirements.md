# Requirements

Covers: config/requirements.json, bin/vgsh-plugin-judge, scripts/test-vgsh-plugin-list.sh, scripts/test-vgsh-requirements.sh

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
- The shell's scan also probes the core's own list, `bin/vgsh-scan --core config/requirements.json`, whose element comes first; `Registry.coreRequirements` and `Registry.coreMissing` hold it, and the requirement notice and the `doctor` capability read it ([requirement-notice.md](requirement-notice.md)).
- The shell's PATH decides: the scan runs as the shell's child.
- A rescan is the only new probe. A command installed while the shell runs is reported present after the next rescan.

## Reports

- `Registry.missingCommands` holds each listed plugin's missing commands and is replaced only when a scan finds a different set, so an installed or removed command rebuilds nothing.
- `PluginLogic.requirementRows` gives each requirement its `state`: `missing` when the last scan did not find its command, else `present`. The manager rows ([manager.md](manager.md)) and each `listPlugins` plugin row carry these rows as `requirements`.
- `vgsh plugin list` prints one line per missing requirement: `missing <id> <command> (<package>)`, with ` optional` after an optional one. The package is the one `PackageManagers.packageFor` picks from `vgsh pkg detect`: the primary's, then an overlay's, then a source's. With no present manager mapped the line names the command alone. Detection runs once per list, and only when a missing requirement names a package; a detection that fails refuses the list with `detect=failed exit=<status>`.
- `config/requirements.json` holds the core's own commands: `node`, `python3`, `git` and `flock`, and, optional, the floating TUIs' `xdg-terminal-exec`, `gum` and `fzf`. Each package name was checked against its distribution's package index.

## Command line

`bin/vgsh-plugin-judge` makes every report below from a scan of the user plugin directory and then the bundled one, the order the shell's registry reads them in. The plugin under an id is the one the registry would hold: the first directory whose manifest the judge accepts. A directory the scan cannot read is refused as `unreadable=<dir>`, since it may hold the id. None needs a running shell, and each runs no plugin code.

- **Rows.** A report row is `PluginLogic.requirementRows`' row, `{ command, packages, optional, purpose, state }`, with `package`: the `{ manager, name }` `PackageManagers.packageFor` picks from `vgsh pkg detect`, or null. Detection runs once per command, and only when a reported requirement names a package. The text form of a row is `<state> <command>[ (<package>)][ optional]: <purpose>`.
- **`vgsh plugin requirements [--json] <id>`** reports every requirement of one plugin, enabled or not. `--json` prints the rows as one JSON list. An id no accepted manifest names is refused as `unknown=<id>`.
- **`vgsh doctor [--json]`** reports the core's requirements, `config/requirements.json`, and those of every plugin the configuration enables, by the rule the registry uses, `PluginLogic.isEnabled` over the shipped and user files. Each text line is a row led by `core` or the plugin's id. `--json` prints one line, `{ core: [rows], plugins: { <id>: [rows] } }`, with every enabled plugin keyed in id order and one without requirements holding an empty list. The core's commands are looked up on PATH as `vgsh pkg present` looks them up; a plugin's come from the scan. A configuration file the config judge refuses is refused as `plugin add` refuses it. The Dev Tools VGS section reads the JSON form.
- **`vgsh plugin add`** ends with the new plugin's missing requirements, after its landing and rescan lines. A running shell hears the landing as `pluginInstalled <id>`, which starts the rescan and then raises the requirement notice ([§ Notice](#notice)). The report is one `requires <command>[ (<package>)][ optional]` line each, then one `install: vgsh pkg run install [--manager <id>] <package>...` line per manager the packages come from, primary first, then overlays, then sources, as detection orders them. `PackageManagers.installGroups` makes the groups and `PackageManagers.installArgs` the words after `install`, for this report and the notice alike. The primary needs no `--manager`, since `vgsh pkg run` takes it by default. Each package appears once however many commands it provides. A manager the package table gives no install steps, nix, gets `by-hand <manager> <package>...` instead of a command: a NixOS system changes through its own configuration, so the user adds the packages there. A requirement with no package for a present manager gets its `requires` line only. The commands are quoted as the shell reads them back, so a copied line runs `vgsh` and nothing else, whatever a manifest's package name holds.
- **The question.** With a terminal on stdin, add then asks `Install now? [y/N]` on stderr. `y` or `yes` runs each command in turn through `vgsh pkg run`, which asks for root in that terminal; the first that fails ends add with its exit status. Any other answer, or no terminal, installs nothing and leaves the commands printed. The plugin stays installed and disabled either way ([D007](../decisions/D007-install-runs-no-plugin-code.md)).
- **Rescan after a package change.** `vgsh pkg run`, and the `install` and `remove` pickers that end in it, run `vgsh plugin rescan` once their steps end, however they end: a running shell scans again and reports each command the change brought or took away. The floating TUIs that install packages run through it too, so a TUI install and a command-line install rescan alike. A run refused before its steps asks for no rescan. The run's exit status stays the steps'. `vgsh plugin rescan` alone prints `shell=rescan-started`, `shell=rescan-queued` or `shell=not-running`.

Omarchy (basecamp/omarchy `e332dc97`) checks commands with `omarchy-cmd-missing` and `omarchy-cmd-present`, `command -v` over a list, and installs with `omarchy-pkg-add`: `pacman -S --noconfirm --needed`, then `pacman -Q` on each package to catch a failure pacman did not report. VGS probes the same way, through `shutil.which` and PATH. It differs in three ways. It lets the package manager ask its own questions, so there is no `--noconfirm`. It installs only after the user answers the question. It confirms the result by the rescan, which probes the command itself, since a requirement is a command and not a package.

## Notice

When a plugin is installed or enabled without a command it needs, or offers its own through the `requirements` capability, the core shows a centred dialog that lists the missing commands and installs their packages with one press: [requirement-notice.md](requirement-notice.md).

## Boundary

Nothing here installs a package or asks for a privilege without the user. A requirement is data the manager reads. Installing one is a `vgsh pkg run` the user starts: from a core TUI, from the notice's Install, or by answering add's question on a terminal. The package manager then asks for root in the user's terminal ([D034](../decisions/D034-one-package-manager-table.md), [D007](../decisions/D007-install-runs-no-plugin-code.md)).

## Invariants

1. A requirement never names a plugin. Enforced by `scripts/test-plugin-logic.js`, which fails on a judge copy that accepts a plugin id and on one that drops the `requires` refusal.
2. Every declared command is probed on the shell's PATH, once per scan. Enforced by `scripts/test-vgsh-scan.py` with a stub PATH, whose control is a scanner that finds every command, and in the nested sandbox by `scripts/smoke/rows/plugins.sh` and `scripts/smoke/rows/manager.sh`, which read a fixture's present and missing commands back from `listPlugins` and the manager rows.
3. `vgsh plugin list` names each missing command with this system's package. Enforced by `scripts/test-vgsh-plugin-list.sh`, which binds a fixture os-release under `unshare -rm`, and by `scripts/test-vgsh-pkg-table.js` for the pick.
4. The core's own list passes the manifest's judge. Enforced by `scripts/test-plugin-logic.js`.
5. `plugin add` prints each missing requirement and the commands that install their packages, asks only on a terminal, installs nothing unless the answer is yes, installs each package once per manager as argv, names `--manager` for an overlay, ends with a failed install's status and tells a running shell the id it installed. Enforced by `scripts/test-vgsh-requirements.sh` from local bare repositories, with stub `pacman`, `paru` and `sudo` that record their argv under a fixture Arch os-release bound under `unshare -rm`. Its controls are a copy of `bin/vgsh` that skips the report, one that asks without a terminal, one that installs on no and one that sends `rescanPlugins` instead of `pluginInstalled`, and a judge copy that offers a command for nix, which installs nothing. The grouping is `scripts/test-vgsh-pkg-table.js`'s, with table copies that drop `--manager`, name it for the primary, install a package twice or offer nix an install.
6. `plugin requirements` and `doctor` report each row's state and this system's package, and `doctor` reports the enabled plugins only and probes the core's commands on PATH. Enforced by the same suite, with judge copies that pick no package, list every plugin and find every core command as controls.
7. A `vgsh pkg run` whose steps ran asks a running shell to rescan, a failed one included, and one refused before its steps asks for none. Enforced by the same suite with a stub `qs` and a lock file naming the suite's pid, with a copy of `bin/vgsh-pkg` that skips the rescan as control.
