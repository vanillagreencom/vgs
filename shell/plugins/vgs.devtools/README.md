# vgs.devtools

`vgs.devtools` holds a catalog of developer tools, its judge and the engine that installs, updates and removes each row. VGS-557 adds the panel and the service.

## Files

- `catalog.json`: The data source for agents, apps, tools, environments, editors, terminals and databases.
- `Appearance.js`: The plugin-owned brand colour table. `scripts/check-devtools-catalog.js` accepts it through `ThemeLogic.acceptAppearance` in dark and light mode.
- `CatalogLogic.js`: The pure catalog judge and the catalog's rules: a mise spec's parts and key, the spec a row installs, the specs a row declares and the machines a row builds on. It imports nothing. Callers inject the package-manager ids, Lucide icon names, brand table and package-name rule through `judgeCatalog`.
- `bin/devtools`: The engine, in node. Its header states each verb, its output and its refusals.
- `tui/devtools.sh`: The floating TUI script. It hands its arguments to the engine.
- `scripts/check-devtools-catalog.js`: The command-line check. It prints `<rule> <path> <detail>` for each refusal.
- `scripts/test-devtools.sh`: The engine's suite, with a stub mise, pacman, sudo and uname.

## Sections

- `agents`: Coding-agent command-line tools. A row can carry `package`, `command`, `bin`, `exec`, `launch`, `arch`, `channels`, `buildEnv`, `requires`, `present`, `postInstall` and `postRemove`.
- `apps`: Developer applications. A row can carry the agent fields plus `kind`.
- `tools`: Developer CLI tools. A row can carry `package`, `command`, `buildEnv`, `requires`, `present`, `postInstall` and `postRemove`.
- `envs`: Language and framework environments. A row can carry `tools`, `packages`, `settings`, `present`, `installer`, `managedBy`, `buildEnv`, `requires`, `postInstall` and `postRemove`.
- `editors`: Editors that Omarchy offers or themes. A row can carry `kind`, `command`, `packages`, `present`, `launch`, `postInstall`, `postRemove`, `requires` and `arch`.
- `terminals`: Terminals that Omarchy offers. A row can carry `command`, `packages`, `present`, `launch`, `postInstall`, `postRemove`, `requires` and `arch`.
- `databases`: Docker or Podman database containers. A row carries `container` data and no `present` field.

Every row has an `id` and `name`. A row that appears in the UI has `icon` and `brand`.

## Fields

- `id`: A lowercase slug. It is unique across the whole catalog.
- `name`: Printable display text.
- `icon`: A Lucide icon name from `shell/Ui/icons/Lucide.js`.
- `brand`: A key in `Appearance.js` `TOKENS.brand`. Every brand key must be used.
- `package`: A mise tool spec.
- `tools` and `requires`: Lists of mise tool specs.
- `packages`: A map from `shell/Core/PackageManagers.js` manager id to package names. Package names use that table's own package-name rule.
- `command` and `managedBy`: Commands found on `PATH`.
- `bin` and `exec`: Paths below a tool install. They are relative and cannot contain `..`.
- `present`: One probe object. `{ "mise": "node" }` means the engine checks for that path below mise's installs directory, `$MISE_DATA_DIR/installs`, where mise names each tool's directory after its key with `:` and `/` as `-`, such as `github-nunomaduro-static-php-builds`. `{ "home": ".rustup" }` means it checks below the user's home directory. `{ "home": ".mix/archives", "prefix": "phx_new-" }` means the engine checks for one entry below the home path with that prefix. `{ "command": "symfony" }` means it checks `PATH`, then asks `mise which`, since a tool a row installs into a mise tool, such as the rails gem, is only there. `{ "command": ["helix", "hx"] }` means any listed command satisfies the probe.
- `postInstall` and `postRemove`: Step lists. Each step is `{ "mise": argv }` or `{ "exec": argv, "via": "<id>" }`. `via` names a row that mise installs, and the engine runs the step through `mise x` on that row's specs. `postRemove` takes back what `postInstall` put into a tool that another row can keep, such as the rails gem in ruby. One judge checks both lists.
- `launch`, `postInstall.exec`, `postInstall.mise`, `postRemove.exec` and `postRemove.mise`: Argument arrays. They are never shell strings. An argument can be `{ "home": ".local/bin" }` where a command needs an absolute path below the user's home directory.
- `buildEnv`: Environment variables for install-time commands.
- `settings`: Mise settings the engine applies before install. The engine adds each item of a list value with `mise settings add`, so it keeps the items other rows added, and sets any other value with `mise settings set`.
- `channels`: Release streams. The engine merges a selected option into the row's mise spec.
- `arch`: Machine architectures that the row supports. Valid values are `x86_64` and `aarch64`.
- `installer`: A named installer route. Valid values are `rustup` and `opam`.
- `kind`: `cli`, `gui` or `tui`.
- `container`: Database runtime data. It has `runtimes`, `image`, `name`, `ports`, `env` and `volumes`.

## Install routes

Each row must declare the install route its section uses.

- Agents, apps and tools install through one mise `package`.
- Environments install through `tools`, `installer` or `packages`.
- Editors and terminals install through `packages`.
- Databases install through `container`.

The package map can name only package-manager ids from `shell/Core/PackageManagers.js`. A package name is present only where it was verified in the package index or came from Omarchy's own install argv. Unverified managers are omitted.

A row with a `flatpak` package must use a Flatpak presence and launch model. The current catalog has no such model, so a row that probes `PATH` with `present.command` or launches a host command cannot also list `packages.flatpak`.

## Mise specs

The spec grammar is `[backend:]name[[opt=value,...]][@version]`.

The judge accepts bare registry names and current mise backend prefixes, including `aqua`, `asdf`, `cargo`, `conda`, `dotnet`, `forgejo`, `gem`, `github`, `gitlab`, `go`, `http`, `npm`, `packslip`, `pipx`, `pkgx`, `s3`, `spm`, `ubi` and `vfox`.

The judge refuses `@latest`. A bare tool name already means the current version. A non-latest tag, such as `@nightly`, is valid.

Backend options can carry regular expressions and URLs. The judge parses package specs with the mise grammar instead of the argument-vector shell-syntax rule.

## Security rules

The catalog stores data, not shell programs.

The judge refuses shell syntax in argument arrays. It refuses command substitution, backticks, command separators, pipes, redirection and newlines.

The judge refuses interpreter evaluation forms such as `sh -c`, `eval`, `env sh -c`, `python -c` and `node -e`.

The judge also refuses versioned or wrapped forms such as `bash -lc`, `python3.12 -c`, `env -S`, `env VAR=1 bash -c`, `mise x node -- node -e` and `mise exec -- sh -c`.

Database ports must bind to `127.0.0.1`. A row cannot publish a database on all interfaces. Database presence comes from the container name, checked by VGS-556 per runtime in `container.runtimes` order.

## Engine

`bin/devtools --tree <dir> <verb>` runs against the VGS tree at `<dir>`. It loads `shell/Core/PackageManagers.js`, `shell/Ui/icons/Lucide.js` and `bin/lib/judge-files.js` from that tree, and runs `bin/vgsh pkg`. It refuses the whole catalog when `CatalogLogic.judgeCatalog` refuses one row.

- `list --json`: The state of every row this machine builds on, and the tools of the global mise config that no row declares. A row reports `installed`, `version`, `origin` and the `actions` the other verbs accept now. `origin` is `mise`, `package` (a package manager owns the command), `managedBy` (a package owns the row's `managedBy` command), `installer`, `container` or `foreign`. The list runs one `mise ls --json` and one `mise ls --global --json`.
- `install <id>`: The row's distribution packages through `vgsh pkg run install`, then its mise settings, then `mise use -g` of each spec it requires and of its tools or package, or its named installer, then its `postInstall` steps. The engine then checks the row's `present` probe. `--channel <c>` picks a release channel.
- `update <id>`: `mise up` over the row's mise keys. A row whose `present` probe fails after the update is installed again with `mise use -g --force` and its `buildEnv`. Then the row's `postInstall` steps run again. Each step installs the current release of what it adds, so rails and phoenix follow the new ruby and elixir.
- `remove <id>`: Install in reverse. It runs the row's `postRemove` steps, then removes each tool or package that no other installed row declares, runs the installer's own uninstall, deletes what the row's `home` probe names, and removes the packages that no other installed row lists. A database row removes its container.
- `update --mise <key>` and `remove --mise <key>`: The same for a tool that only the owner's global mise config declares. The engine never installs one, so the owner's stowed config stays the source of truth.
- `launchers refresh|remove`: Write or delete the launchers in `~/.local/bin`.

Install, update and remove run only in a terminal and never in a process the shell started, through `refuseOutsideTerminal` in `bin/lib/judge-files.js`. `vgsh pkg run` has the same rule. Each mise, container and installer step runs through `bin/lib/pkg-run.sh` from `$HOME`, with `MISE_MINIMUM_RELEASE_AGE=0` and the row's `buildEnv`. Before `mise use` or `mise up`, the engine sets mise's `upgrade.auto_prune` to false when it is not false already. Without this, an upgrade deletes the release that a running session still executes.

The named installers download the upstream script to a temporary file and run it with `sh`. No shell string passes through the engine. `rustup` removes itself with `rustup self uninstall -y`. The `opam` binary that its installer puts in `/usr/local/bin` stays after a removal, because only root can delete it.

A row whose `present` probe still holds after a removal reports `present=remains`: something VGS did not install provides it.

## Launchers

A launcher is a script at `~/.local/bin/<command>` for an agent, app or tool. On its first run, it installs the row through mise. Then it runs the row. Its second line is `# vgs.devtools launcher`.

- The plugin's `writeLaunchers` setting is off by default. The panel passes `--launchers`, or runs `launchers refresh` or `launchers remove`, from that setting.
- A file without the mark, a link included, belongs to the owner. The engine never replaces or deletes it. The owner's `agent-cli` links stay the owner's.
- The engine writes no launcher where the command already answers on `PATH` outside `~/.local/bin` and mise's data directory, because the launcher would hide that copy.
- A row with `exec` installs with an empty `bin_path=`, so its package exports nothing on `PATH` (v1 D016). Its launcher runs the `exec` file below the directory that `mise where` names. The engine writes this launcher after each install and update, whatever the setting, and `launchers remove` keeps it while the row is installed.
- A launcher runs the row's default channel.

## Omarchy comparison

Omarchy uses `omarchy-install-dev-env` case arms and `omarchy-menu.jsonc` rows with bash `disabled` checks.

VGS uses `catalog.json` rows plus `present` probes. The engine can list, install and remove tools from one data file without parsing menu shell snippets.

VGS keeps Omarchy's environment set, editor set, terminal set and Docker database defaults. VGS changes the install representation to package-manager ids, mise specs, named installer routes and container data.

Omarchy sets the PHP mise alias to `github:nunomaduro/static-php-builds` before installing PHP. VGS uses that spec directly, because bare `php` can build PHP from source and needs many system development packages.

Omarchy's `omarchy-mise-install` writes a wrapper for each agent at setup. VGS writes launchers only when the owner asks for them, because mise's shims and the owner's own `agent-cli` link already run each tool. Omarchy's `install/user/mise.sh` sets `upgrade.auto_prune` false once at setup; the engine sets it before its first `mise use` or `mise up`. Omarchy runs `sudo docker run` for its databases; the engine runs the first container runtime of the row on `PATH` without `sudo`, so a user without access to that runtime sees its error in the TUI.
