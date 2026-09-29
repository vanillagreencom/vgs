# vgs.devtools catalog

`vgs.devtools` starts as a catalog and a judge. VGS-556 adds the install engine. VGS-557 adds the panel and service.

## Files

- `catalog.json`: The data source for agents, apps, tools, environments, editors, terminals and databases.
- `Appearance.js`: The plugin-owned brand colour table. `scripts/check-devtools-catalog.js` accepts it through `ThemeLogic.acceptAppearance` in dark and light mode.
- `CatalogLogic.js`: The pure catalog judge. It imports nothing. Callers inject a context object with package-manager ids, Lucide icon names, brand keys and package-name validation.
- `scripts/check-devtools-catalog.js`: The command-line check. It prints `<rule> <path> <detail>` for each refusal.

## Sections

- `agents`: Coding-agent command-line tools. A row can carry `package`, `command`, `bin`, `exec`, `launch`, `arch`, `channels`, `buildEnv`, `requires`, `present` and `postInstall`.
- `apps`: Developer applications. A row can carry the agent fields plus `kind`.
- `tools`: Developer CLI tools. A row can carry `package`, `command`, `buildEnv`, `requires`, `present` and `postInstall`.
- `envs`: Language and framework environments. A row can carry `tools`, `packages`, `settings`, `present`, `installer`, `managedBy`, `buildEnv`, `requires` and `postInstall`.
- `editors`: Editors that Omarchy offers or themes. A row can carry `kind`, `command`, `packages`, `present`, `launch`, `postInstall`, `requires` and `arch`.
- `terminals`: Terminals that Omarchy offers. A row can carry `command`, `packages`, `present`, `launch`, `postInstall`, `requires` and `arch`.
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
- `present`: One probe object. `{ "mise": "node" }` means the engine checks below the mise install root. `{ "home": ".rustup" }` means it checks below the user's home directory. `{ "home": ".mix/archives", "prefix": "phx_new-" }` means the engine checks for one entry below the home path with that prefix. `{ "command": "symfony" }` means it checks `PATH`. `{ "command": ["helix", "hx"] }` means any listed command satisfies the probe.
- `launch`, `postInstall.exec` and `postInstall.mise`: Argument arrays. They are never shell strings. An argument can be `{ "home": ".local/bin" }` where a command needs an absolute path below the user's home directory.
- `buildEnv`: Environment variables for install-time commands.
- `settings`: Mise settings the engine applies before install.
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

## Omarchy comparison

Omarchy uses `omarchy-install-dev-env` case arms and `omarchy-menu.jsonc` rows with bash `disabled` checks.

VGS uses `catalog.json` rows plus `present` probes. The engine can list, install and remove tools from one data file without parsing menu shell snippets.

VGS keeps Omarchy's environment set, editor set, terminal set and Docker database defaults. VGS changes the install representation to package-manager ids, mise specs, named installer routes and container data.

Omarchy sets the PHP mise alias to `github:nunomaduro/static-php-builds` before installing PHP. VGS uses that spec directly, because bare `php` can build PHP from source and needs many system development packages.
