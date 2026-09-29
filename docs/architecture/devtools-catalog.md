# The Dev Tools catalog

Covers: shell/plugins/vgs.devtools/catalog.json, shell/plugins/vgs.devtools/CatalogLogic.js, shell/plugins/vgs.devtools/Appearance.js, scripts/check-devtools-catalog.js, scripts/test-check-devtools-catalog.js

The format of the `vgs.devtools` catalog and the rules its judge holds it to. The plugin's [README](../../shell/plugins/vgs.devtools/README.md) holds the engine, the panel, the service and the launchers.

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

Database ports must bind to `127.0.0.1`. A row cannot publish a database on all interfaces. Database presence comes from the container name, checked by the engine per runtime in `container.runtimes` order.
