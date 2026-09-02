# Developer tools: mise, coding agents, language environments

Coding-agent harnesses and language toolchains are user-level mise installs
under `~/.local/share/mise`. The distribution package manager never sees them.

## Catalog

`config/vshell/dev-tools.json` is the only list. It feeds:

| Consumer | Reads |
|----------|-------|
| `vshell mise refresh` | `agents` + `tools` → stubs in `~/.local/bin` |
| `vshell agent` | `agents` (id, launch argv) |
| `vshell dev-env` | `envs` (mise tools, distro packages, installer; `managedBy` marks one the package manager owns, e.g. a pacman rustup) |
| Settings → Applications → Developer | all three, through the JSON commands below |
| VGS menu (Dev tools, `d:`) | reads the file directly: one entry per agent and per env, named after the tool |

## Stubs

`vshell mise install <package> [command [bin]]` writes `~/.local/bin/<command>`:

```bash
#!/bin/bash
# vshell mise stub
export MISE_MINIMUM_RELEASE_AGE=0
mise use -g --quiet '<package>' || exit 1
exec mise x '<package>' -- '<bin>' "$@"
```

Nothing downloads until first run. Rules:

- A file without the marker line is foreign and is never replaced; `list`
  reports it as `foreign` and the agent launches through it as-is.
- A command that already resolves on `PATH` outside `~/.local/bin` gets no
  stub either (`shadowed`): `~/.local/bin` sorts first and the stub would hide
  the distro binary.
- `vshell mise remove-stubs` deletes our stubs and writes
  `~/.local/state/vshell/mise-stubs-removed`; `refresh` is a no-op until
  `vshell mise opt-in`.
- `refresh` runs after every `vshell update run tools`, so a template change
  reaches existing machines without a migration.
- `MISE_MINIMUM_RELEASE_AGE=0` on every mise call VGS makes: mise otherwise
  withholds releases younger than its cooldown.

## Commands

```
vshell mise    install|refresh|remove-stubs|opt-in|list --json|outdated --json|up
vshell agent   list [--json] | launch <id> [--inline] | pick
vshell dev-env list [--json] | install <id> | remove <id>
vshell update  count | run <system|aur|flatpak|tools|all>
```

There is no default agent. `launch <id>` opens a terminal (app id
`vshell-agent`) that runs `launch <id> --inline` from `~/Work` when it
exists. An agent with no mise install and no command of the owner's on
`PATH` is offered for installation there first (`mise use -g`); a refusal
exits 1. `pick` opens the launcher on its Dev tools section, which
lists one entry per agent and one per language environment straight from
the catalog (`vshell-menu openCategory dev` over IPC).

## Updates, end to end

```
bar widget / menu / Developer tab
   │  default command            custom command (plugin setting)
   ▼                              ▼
sysupdate.upgrade {mode}      Quickshell.execDetached + 30s re-check
   │
   ▼
vshell terminal exec --tui --wait -- vshell update run <mode>
   │        (backend waits, then refresh(force) re-counts)
   ▼
system: sudo pacman -Syu → aur: paru -Sua → flatpak update → tools: mise up + mise refresh
```

`vshell update run` is the only place that knows the per-source commands and
their order. The Go `sysupdate` service counts (`checkupdates`, `paru -Qua`,
`flatpak remote-ls`, `mise outdated --json`) and supervises; it never
assembles a package-manager command itself. When the backend capability is
absent the widget falls back to `vshell update count --json`, which carries
the same `tools` rows.

## Not owned here

Shell wiring lives in the user's dotfiles: interactive `mise activate`, the
session `PATH` (`~/.local/bin`, `~/.local/share/mise/shims`), and the PAM line
for SSH commands. VGS assumes `~/.local/bin` is on `PATH`; `agent launch`
and the stubs resolve their commands through it.
