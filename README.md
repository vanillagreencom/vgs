# VGS v2

A desktop shell for Hyprland on Quickshell. Everything is a plugin: the bar, the widgets you add to it, every panel, every background service. A small fixed core starts the shell, hosts the surfaces and loads plugins, and each plugin ships with the check that proves it is built and handed what it asked for.

## Install

VGS needs Hyprland 0.56 or later, configured in Lua (`~/.config/hypr/hyprland.lua`), Quickshell 0.3.1 or later, node 18 or later, python3 and git. `vgsh run` checks them before it starts and names the first one that is missing or too old.

### Arch Linux

Install one of the two packages. The latest release:

```bash
yay -S vgs
```

The development version, built from `main`:

```bash
yay -S vgs-git
```

The two packages conflict with each other and with v1's `vgs-shell`, so pacman offers to remove the one installed before.

### Any distribution: install script

`install.sh` installs VGS into your home directory: the tree in `~/.local/share/vgs`, and `vgsh` in `~/.local/bin`. It never uses sudo, checks every download against the release's `SHA256SUMS`, and names the package to install when a required tool is missing. Read it first: [install.sh](install.sh).

```bash
curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vgs/main/install.sh | bash
# a pinned release, the development version, or removal
curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vgs/main/install.sh | bash -s -- --version v0.1.0
curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vgs/main/install.sh | bash -s -- --git
curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vgs/main/install.sh | bash -s -- --uninstall
```

`vgsh self update` updates a release install and the `--git` clone. `--uninstall` keeps your settings in `~/.config/vgs`.

### Nix

```bash
nix run github:vanillagreencom/vgs/v0.1.0 -- run
```

Every `vgsh` command works after `--`. To install VGS, add the flake's `packages.<system>.default` to your configuration, for `x86_64-linux` or `aarch64-linux`. The package puts Quickshell and the tools the core needs, the rows of `config/requirements.json`, on the `PATH` of `vgsh`. A plugin feature can need more tools, which its README names and `vgsh plugin list` reports as `missing`. Hyprland comes from your session, not from the package.

### From a checkout

```bash
git clone https://github.com/vanillagreencom/vgs
vgs/bin/vgsh run
```

`vgsh self update` fast-forwards the checkout.

### Start VGS with Hyprland

Add this line to `~/.config/hypr/hyprland.lua`:

```lua
hl.on("hyprland.start", function () hl.exec_cmd("vgsh run") end)
```

The line needs `vgsh` on the `PATH` Hyprland starts programs with. When that `PATH` lacks `~/.local/bin`, use the absolute path the install script prints. From a checkout, use the absolute path of `bin/vgsh`.

After it writes its Hyprland layer, VGS asks before it adds one line to the top of `hyprland.lua`. That line loads the keys, border colours and blur rules VGS generates. `vgsh hypr unwire` removes it.

### Other distributions

Fedora follows in 0.1.x through the COPR `vanillagreen/vgs`. Debian, Ubuntu, openSUSE, Gentoo and Void wait until their repositories carry Quickshell 0.3.1 and Hyprland with Lua configuration. Until then, the install script or a checkout works on them when you install those tools yourself.

## Features

- Everything is a plugin. A plugin is one directory with a manifest; the shell shows it on every surface it declares.
- One manifest format, judged once, with every field in [docs/architecture/plugins.md](docs/architecture/plugins.md).
- A Settings window, `SUPER+M` or the gear in the bar: every plugin with a page of its details, its settings and its keys, and a switch to turn it on or off.
- A plugin manager on the command line: `bin/vgsh plugin list`, `enable`, `disable`, `validate`, `requirements`, and `add <git url>`, `update` and `remove`. Install runs no code from the plugin and leaves it disabled until you enable it. It names the commands the plugin needs that are missing and, on a terminal, offers to install their packages. `bin/vgsh doctor` lists what VGS itself and every enabled plugin need, and what is missing.
- Plugins never depend on each other. When the surface a plugin draws on is absent, that part is hidden and the rest keeps working.
- A validation sandbox that runs the whole shell inside a nested compositor and never touches your session.
- Hyprland keys and blur from plugins, and window borders in the theme's colours. Hyprland is configured in Lua only: the shell writes one Lua file, and one line in your `hyprland.lua` loads it. A classic `hyprland.conf` is not supported.

## Shipped plugins

| Plugin | What it does |
|---|---|
| [Bar](shell/plugins/vgs.bar/README.md) | The bar across the top of every screen, with its built-in workspaces and clock, and three sections for plugin widgets. |
| [Settings](shell/plugins/vgs.settings/README.md) | A window that lists every plugin and opens a page for each, with its details, settings and keys. `SUPER+M` or the gear in the bar opens it. |
| [Themes](shell/plugins/vgs.themes/README.md) | A bar button and a panel that list every theme package and apply one with a click, and the applied theme's wallpaper on every screen, with Previous and Next in the panel. `bin/vgsh plugin enable vgs.themes` adds the button to the bar. |
| [Launcher](shell/plugins/vgs.launcher/README.md) | A search field over the screen that finds applications, menu entries and files. `SUPER+SPACE` opens it. |
| [Notifications](shell/plugins/vgs.notifications/README.md) | The desktop notification daemon: notifications at the top of every screen, an Inbox and History panel, and Silence. `SUPER+N` opens the panel. |
| [Updates](shell/plugins/vgs.updates/README.md) | A service that counts waiting updates for the system packages, AUR, Flatpak, mise tools, VGS itself, plugins and themes, every six hours, on demand and after each update run, without root. Its Settings page shows the count, the last check and any source that failed. |
| [Agent Warden](shell/plugins/vgs.agent-warden/README.md) | A shield in the bar that shows whether the agent warden vsys ships keeps your AI agents within their memory and task limits. A click opens a small panel with what needs a look, the agents' memory and Open vsys, or the one step that sets the warden up. One notification, with Open vsys, tells you when something starts to need a look. It reads the warden's status and never changes an agent. `bin/vgsh plugin enable vgs.agent-warden` adds the shield to the bar. |
| [Dev Tools](shell/plugins/vgs.devtools/README.md) | A window over a catalog of coding agents, developer apps, CLI tools, languages, editors, databases and terminals, with each tool's state and version, and Install, Update and Remove in a floating TUI. Its VGS section shows how VGS is installed and every command VGS or an enabled plugin needs that is missing, with Install. `bin/vgsh ipc call vgs.devtools invoke open` opens it. |
| [Gallery](shell/plugins/vgs.gallery/README.md) | A window with every component of the design system in every variant and state, to preview a theme. `bin/vgsh ipc call shell summon window vgs.gallery '{}'` opens it. |
| [Automations](shell/plugins/vgs.automations/README.md) | Runs your shell commands on a schedule through systemd user timers, such as every weekday at 09:00 or the second Tuesday of each month, keeps each run's transcript for up to 30 days, and sends a notification for every failure whose click opens the transcript. |
| [Lock](shell/plugins/vgs.lock/README.md) | The lock screen: `SUPER+L`, `vgsh lock`, five minutes without input and every suspend lock the session, and your password unlocks it. The session stays locked if the shell stops. |
| [Polkit](shell/plugins/vgs.polkit/README.md) | The session's polkit agent: a themed dialog asks for your password when an application needs administrator rights. |
| [Jarvis](shell/plugins/vgs.jarvis/README.md) | A service-owned child daemon with health in Settings and bounded restart. This skeleton captures no audio and connects to no provider. |

## How it works

- `bin/vgsh run` takes the instance lock and starts one shell for the session. It starts the shell again after a crash, and after six quick crashes in a row it stops and shows a notice, unless the session is locked.
- `bin/vgsh restart` refuses while locked, then stops the running `vgsh run` and its shell and relaunches through Hyprland. It returns after the new shell answers as the guarded instance.
- The shell reads `config/shell.json`, then your `~/.config/vgs/shell.json`, and enables the plugins those name.
- Each plugin is shown on the surfaces it declares. A widget appears in the bar, a service runs with no surface.
- `bin/vgsh plugin disable <id>` writes your file; the shell watches it and updates the screen. Disable keeps the plugin's placement and settings, so enable restores it as it was.
- The shell writes `~/.local/state/vgs/hypr/vgs.lua` with the theme's border colours and each enabled plugin's keys and blur rules, and reloads Hyprland when it changes. It asks before it adds `pcall(dofile, "…/vgs.lua")` as the first line of `~/.config/hypr/hyprland.lua`; `bin/vgsh hypr state`, `wire` and `unwire` report, add and remove the line. Settings after that line win. See [docs/architecture/hyprland.md](docs/architecture/hyprland.md).

## Settings

- `~/.config/vgs/shell.json`: which bar is active, which widgets sit in which section, which plugins are on.
- `~/.config/vgs/theme.json`: the theme, a document that overrides any design token every plugin reads: colours, fonts, spacing, radius and motion.
- A widget's settings sit inline on its layout entry, for example `{ "id": "acme.weather", "units": "metric" }`; every other plugin's sit on its row in `plugins`, for example `{ "id": "vgs.bar", "clockFormat": "HH:mm" }`. A change reaches the running plugin without a restart.
- A plugin's Hyprland keys sit in `keys` on its row in `plugins`, for example `{ "id": "vgs.launcher", "keys": { "toggle": "SUPER+ALT+SPACE" } }`; `null` unbinds a key. The Settings window writes both.

## Writing a plugin

Read [docs/architecture/plugins.md](docs/architecture/plugins.md). An agent loads the `vgs-plugin` skill, which scaffolds a plugin from templates and checks it.

## Licence

VGS is under the MIT licence: [LICENSE](LICENSE). The bundled fonts, JetBrains Mono and Inter, are under the SIL Open Font License 1.1 (`shell/assets/fonts/*-OFL.txt`), and the Lucide icons under ISC ([shell/Ui/icons/LICENSE](shell/Ui/icons/LICENSE)). The package licence is `MIT AND OFL-1.1 AND ISC`.
