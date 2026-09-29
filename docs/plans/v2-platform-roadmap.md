# V2 platform roadmap: floating TUIs, packages, requirements, Updates, Dev Tools, Agent Warden, the theme catalog and browsers, and the public 0.1 release

Planning artifact, 2026-09-28. Written by the planner for the overseer. It changes no code. The issue list at the end has a machine form: `tmp/audit-oversee-platform.json` (VGS, team `vgs`) and `tmp/audit-vsys-platform.json` (vsys, team `vsys`).

## Framing

**Goal.** Land the owner's 2026-09-28 request as one ordered set of lanes: the core systems first (a floating TUI, a package-manager layer, external requirements with a core install notice, a passwordless-sudo TUI, published plugin status), then the Updates, Dev Tools and Agent Warden plugins, the theme catalog with its full-screen browsers, and the distribution that ends in a public VGS 0.1.

**Perspective.** Architecture first: every piece lands as a system with a judge, a contract doc, a decision record where a real alternative was weighed, and a validation row. The core stays small and names no plugin; a plugin never depends on another; Omarchy guides behaviour and look, and nothing is taken wholesale.

**Constraints read.** `AGENTS.md`; `docs/architecture/{overview,plugins,capabilities,manager,runtime,configuration,design-system,themes,theme-capability,theme-backgrounds,hyprland}.md`; `docs/decisions/INDEX.md` (D001-D032, with D005, D007, D009, D026 and D028 in full); the vgs-plugin skill and `references/api.md`; the five research reports under `tmp/research/` (`omarchy-tui.md`, `updates-devtools.md`, `packaging.md`, `theme-browser.md`, `agent-warden.md`); the kendex label taxonomy and the audit-issues input schema. Omarchy read-only clone `tmp/omarchy-ref` (`e332dc97`); v1 at `/home/method/dev/.worktrees/vgs/v1` (`b904c236`); vsys at `~/dev/vsys` (0.9.0).

**Assumptions.**

- `main` at `9a10afba` is the base. The next free decision id is D033.
- Hyprland v0.56.2 accepts `hl.window_rule` with `match.class`, `float`, `center` and `size`, as Omarchy's Lua uses them. Unverified on VGS; the first window-rule issue proves it in the sandbox before anything relies on it.
- The owner's session keeps `xdg-terminal-exec` with Ghostty as the default terminal (both observed in the research).
- vsys work is filed in Linear team `vsys` (prefix VSY) and executed in `~/dev/vsys`; VGS issues that need it name it by title.

## Decisions

### The overseer's decisions, recorded with their reasons

| # | Decision | Reason | Record |
|---|---|---|---|
| 1 | The dependency notice and one-click install are **core**: a manifest key declares external requirements (commands and packages) only, judged by `PluginLogic.js`; the core raises the notice and runs the install through the floating TUI and `vgsh pkg`. Plugin-to-plugin dependencies stay refused. | Plugin install must work with any plugin set, the Settings plugin disabled included, and the manager is core ([D003](../decisions/D003-everything-is-a-plugin.md)). A plugin-hosted notice would make install depend on a plugin. A requirement is data about the system, never a plugin id, so D005's reason (no dependency graph, no plugin naming another) holds. | D035; revisit outcomes on D005 and D007 |
| 2 | The floating TUI is **core**: `vgsh tui`, a presentation library, a `tui` capability that runs only scripts the plugin's manifest declares, from its published snapshot, argv not shell strings; one fixed core window rule in the Hyprland layer; gum colours through a theme target; a VGS ASCII logo. | It touches three core systems at once: the Hyprland layer (D028: no plugin writes Hyprland text), the theme targets and the capability set. The core itself needs it (plugin and theme update refuse `no-terminal`, the requirement install, `vgsh pkg`). Declared scripts from the snapshot keep D014's "the reviewed revision runs" and D007's review step. | D033; revisit outcome on D028 |
| 3 | No `vgs.system` plugin. Each TUI lives with its owner: package install/remove and the sudo grant in core (`vgsh pkg`, `vgsh sudo`), the update pipeline in Updates, tool installs in Dev Tools, plugin/theme update and add in core. | Every flow `vgs.system` would hold is either used by the core itself (the requirement install needs `vgsh pkg`; the pipeline and the notice need the sudo session) or belongs to one plugin. A grab-bag plugin would be a second owner of package flows and a core feature hidden behind a plugin toggle. | D033 alternatives |
| 4 | The Agent Warden enforcer stays a systemd user service, moved into the vsys repo as its supported install path, with a cheap `vsys --once --summary` JSON and a warden `status.json`. `vgs.agent-warden` (bar widget, flyout panel, service) reads those, notifies once per episode with rewritten copy, and opens vsys through the core `tui` capability. | QML cannot hold pidfds or libsystemd; correction must survive a shell restart or crash; the VGS manager may not install units or ask privilege (D007, invariant 5). vsys already observes the same slices and ships AUR packages. | D041 (VGS side); a vsys decision record (vsys side) |
| 5 | 0.1 ships AUR `vgs` and `vgs-git`, a Nix flake and a user-local, sudo-free, checksummed curl installer. Fedora COPR in 0.1.x. Debian, Ubuntu, openSUSE, Gentoo and Void wait until their repositories carry Quickshell ≥ 0.3.1 and Hyprland with Lua configuration, and the README says so plainly. MIT. `VERSION` 0.1.0 and `vgsh --version`. Node is resolved as a runtime dependency. Stale v1 channels removed per `packaging.md` § F. Publishing runs from local scripts. | The runtime floor, not packaging effort, decides where 0.1 can run (`packaging.md` § 6). MIT is v1's licence and the owner's earlier choice. AGENTS.md forbids CI workflows. | D040; revisit outcome on D009 |
| 6 | A first-party catalog of v2 theme definitions converted from v1, checked in the vgs repo and installed on demand into `~/.config/vgs/themes`; wallpapers downloaded on demand from `vanillagreencom/vgs-themes` release archives (the repo stays) after a prompt inside the overlay, on a download queue of their own; per-monitor wallpaper through a per-screen map and `vgsh theme background set <path> [--screen]`; both browsers share `vgs.themes`' one overlay with a payload; SUPER+T and SUPER+W declared in the manifest. | Install needs no network and every definition is judged offline like `themes/*`; the 1.05 GB `themes-v1` archives are reused unchanged; a 40 MB download on the theme runner's one queue would block every list and apply. One plugin has one overlay entry point, so a `view` payload is the only way two browsers share it. | D038, D039 |
| 7 | Updates checks every 6 hours, on demand and after each run, hides nothing silently, and runs one floating-TUI pipeline modelled on `omarchy-update`. | Omarchy's cadence and one-click pipeline are what made its updates feel good; v1's 30-minute poll and four-button popout did not (`updates-devtools.md` § Tradeoffs 1). | Plugin README and this plan |

### Decisions this plan takes

| ID | Decision | Reason | Lands with |
|---|---|---|---|
| D033 | Floating TUIs are a core concept: `bin/vgsh-tui` presents, `bin/lib/tui.sh` styles, the `tui` capability opens manifest-declared scripts from the published snapshot by name with an argv list, and one app-id family `org.vgs.tui[.wide\|.tall]` floats through one core window rule. | See decision 2. | #1 (concept), #4 (capability) |
| D034 | The core owns one package-manager layer: a per-family data table (`shell/Core/PackageManagers.js`) and `bin/vgsh-pkg`. Checks run unprivileged; installs, removals and upgrades run only inside a floating TUI, and the shell process never runs `sudo`, `doas` or `run0`. | One owner per concern: v1's two collectors disagreed. The data table lets `PluginLogic.js` judge requirement package names and `vgsh pkg` run them from one source (D009's one-judge rule). Elevation seen and answered by the user in a terminal is the only privilege path. | #6 |
| D035 | A manifest `requirements` key declares external commands and per-manager package names; the core probes them once per scan, reports them, raises a core notice on install or enable, and installs on the user's click through `vgsh pkg` in the TUI. `requires` stays refused; a requirement naming a plugin id is refused. | Decision 1. D007's revisit condition ("a plugin needs a system package the manager cannot declare") is met; its rule survives: the manager runs no plugin code and asks no privilege, the package manager asks inside the user's terminal. | #10 |
| D036 | A time-boxed passwordless sudo grant is an opt-in core TUI (`vgsh sudo grant`), with a narrow root half installed once by an owner command, a `NOTAFTER` sudoers rule, a systemd-run expiry and a tmpfiles boot cleanup. | The owner asked for Omarchy's flow; Omarchy's grant is time-boxed and self-expiring; [D029](../decisions/D029-chromium-policy-writer.md)'s browser-policy writer is the precedent for a once-installed root half. No plugin may own a system-wide privilege grant. | #9 |
| D037 | Plugin status is a core convention: a manifest `status` key declares typed runtime values as data, a `status` capability lets the plugin publish them, the core holds them per plugin id while the plugin is enabled (dropped on disable or source-revision change), every instance of the plugin reads them, and the Settings page draws each displayable entry as a read-only row with an optional hint and copyable command. Refines D032. | A service owns live values that its widgets, its flyout and its Settings page must all show, and v2 has no way to share them: VGS-508 (D032) gave Settings editable schema fields only, and `updates-devtools.md` flags service-to-widget sharing as missing. A state file per plugin means disk writes and a watcher per instance ("one owner per watcher"); writing runtime values as schema settings through `configure` would put them in `shell.json`. Declaring the entries in the manifest keeps D032's rule that the manifest is the settings page. Updates, Agent Warden, Dev Tools and the notifications' Slack token row all need it. | #15 |
| D038 | First-party themes are a judged catalog in `themes/catalog/`, installed on demand as ordinary installed packages with a catalog marker; the catalog carries no curated code file, so D031's drop never applies to it and no trust tier is loosened; wallpapers download from pinned `vgs-themes` archives on a download lane separate from the theme runner's queue. | Decision 6. Refusing code-carrying curated files in the catalog answers the research's open trust question without touching D019 or D031. | #29 |
| D039 | Wallpaper is per screen: `backgrounds.json` gains a `screens` map that overrides `current` for a named output; `vgsh theme background set <path> [--screen <output>]` writes it; a theme apply clears the map. | An additive map needs no mode flag (v1 D010 needed seeding). Clearing on apply keeps "apply a theme" meaning "this theme everywhere"; a leftover image from another theme on one monitor contradicts it, and re-setting a screen is one keystroke in the browser. | #34 |
| D040 | Distribution: exactly `vgs` and `vgs-git`; one install tree `/usr/share/vgs` (`bin shell config themes VERSION`) with `/usr/bin/vgsh` linked into it, shared by every recipe, the flake and the curl installer; `vgsh self` detects the install method (checkout, package, curl, nix); releases and AUR pushes run from local scripts, with no CI workflow. | Decision 5. A script-only payload is `arch=any`/`noarch`. `packaging.md` § Tradeoffs compares `/usr/lib/vgs` and `/etc/xdg/quickshell`. | #21 (layout), #25 (publishing), #18 (install methods) |
| D041 | Agent Warden: the enforcer stays outside the shell as a systemd user timer shipped by vsys; the VGS plugin observes its `status.json`, owns user-facing notifications through a heartbeat hand-off, and links to vsys. | Decision 4 and `agent-warden.md` § Tradeoffs (options A-F). | #48 |
| Updates icon | The widget is always visible: a calm icon with no badge when everything is current, a count badge in the accent tone when updates wait, a warning tone when a check failed or is older than twice the interval, a spinner while checking. `hideWhenCurrent` (default false) gives Omarchy's quiet bar. | "Hides nothing silently": a hidden icon makes "up to date" indistinguishable from "never checked" or "check failed", and the widget is also the entry to Check now and the last-checked time. The count stays quiet by being uncoloured when nothing is actionable, not by vanishing. | #43 (README) |

### Revisit outcomes appended to existing records

- **D005** (outcome): holds. A plugin still names no plugin. `requirements` names commands and packages only (D035).
- **D007** (outcome): its revisit condition is met by D035. Install still runs no plugin code, lands the plugin disabled and asks no privilege; the manager reads `requirements` as data and offers a core TUI that the user starts.
- **D009** (outcome): holds as one judge. Node and python3 are runtime dependencies of `vgsh` (theme and plugin verbs, `vgsh pkg`, `vgsh-scan`), hard in every package, checked by the preflight; not rewritten into bash, because the judge must be the file the shell loads.
- **D028** (outcome): the layer gains one constant core section, the floating-TUI window rules, after the border colours and before the plugin sections. Plugins still declare only binds and layer rules; no plugin text reaches a window rule.
- **D032** (refined by D037, status stays Active): the manifest is still the whole settings page; a page now shows read-only status rows declared in the manifest beside its editable schema fields. Its revisit condition ("a setting needs a type the schema cannot hold") is not triggered, because status is not a setting and is never written to `shell.json`.

## Architecture

The order is the dependency order: each core system lands with its capability, fixture and row before a plugin uses it (overview § The one idea, D008).

### 1. Floating TUI (core; issues 1-5 and 14, D033)

**Parts.**

1. `bin/vgsh-tui` (bash), the only file that knows terminals.
   - `launch --title T --size default|wide|tall [--presentation full|plain] [--plugin ID --dir SNAPSHOT] [--record KEY] -- argv…`: parses `${XDG_STATE_HOME}/vgs/theme/gum.env` strictly (one `KEY=#rrggbb` line, key pattern `^(GUM_[A-Z_]+|FOREGROUND|BACKGROUND|BORDER_FOREGROUND|VGS_TUI_[A-Z]+)$`, never `source`d), exports those plus `VGS_TUI_LIB`, `VGS_TUI_LOGO`, `VGS_PLUGIN_ID`, `VGS_PLUGIN_DIR`, then `exec setsid xdg-terminal-exec --app-id=org.vgs.tui[.size] --title="VGS · T" -- vgsh-tui present …`.
   - `present`: clear, logo (truecolor accent from `VGS_TUI_ACCENT`, ANSI fallback), run argv, keep the exit code, and unless it is 130 print `● Done!` or `● Failed (exit code N)!` on `/dev/tty` after draining queued terminal replies, read one key, write the exit record, exit with the code. `plain` skips the logo and the prompt (for vsys, btop-style tools).
   - Copies a plugin's `tui/` directory into a private temporary directory per launch, so `vgsh restart` (which removes old snapshot roots) cannot pull a sourced file from under a running script.
2. `bin/lib/tui.sh`, sourced: `vgs_tui_header`, `vgs_tui_step`, `vgs_tui_warn`, `vgs_tui_error`, `vgs_tui_confirm` (yes under `VGS_TUI_UNATTENDED=1`, refuses without a tty), `vgs_tui_choose`, `vgs_tui_input`, `vgs_tui_filter`, `vgs_tui_sudo_session start|end` (`sudo -k`, one `sudo /usr/bin/true`, a 60 s `sudo -n true` keepalive tied to the script's pid, `sudo -k` on EXIT/HUP/INT/TERM), `vgs_tui_lock NAME` (flock under `$XDG_RUNTIME_DIR`), `vgs_tui_log FILE` (re-exec under `script -qefc`), `vgs_tui_reboot_check` (running kernel's modules gone or Hyprland's `/proc/<pid>/exe` reads `(deleted)`).
3. `bin/lib/logo.txt`: the VGS wordmark (Delta Corps Priest 1 rendering from `omarchy-tui.md` § Local observations, hand-adjusted; only the rendered text is committed, the font is not vendored).
4. Theme target `themes/targets/gum/` writes `gum.env` from tokens: `color.accent`, `color.textFaint`, `color.textHeading`, `color.onAccent`, `color.text`, `color.background`, `color.borderStrong`, plus `VGS_TUI_{ACCENT,SUCCESS,WARNING,DANGER}`. `runsCode: false` holds because the presenter parses and never sources it.
5. The Hyprland layer's constant section (D028 outcome): `hl.window_rule` for `^org\.vgs\.tui$` (float, center, 875×600, Omarchy's size), `.wide` (1200×720) and `.tall` (875×900). Users disable one by name after the layer line.
6. The manifest key `tui` and the capability `tui`:
   - `"tui": { "<name>": { "script": "tui/x.sh", "title": "…", "size": "default", "presentation": "full", "entry": { "label", "icon", "group" } } }`, judged in `PluginLogic.js` (name grammar, relative regular non-symlink file inside the plugin, printable title ≤ 60, size and presentation from `TUI_SIZES`/`TUI_PRESENTATIONS`, needs capability `tui`).
   - `shell.tui.run(name, args, done)`: the caller's own declared script only, `args` a list of ≤ 16 non-empty strings ≤ 256 characters without control characters. Answers `ok`, `refused: tui=<name> reason=undeclared|args|disabled|launcher-missing`, or focuses the live window of the same key (`compositor.focusWindow`) and answers `refused: tui=busy`.
   - `shell.tui.entries`: every enabled plugin's `entry` rows plus the core's own entries (`core/pkg-install`, `core/pkg-remove`, `core/sudo-grant`, `core/plugin-add`, `core/theme-add`, `core/doctor`), published like `manager.plugins`; `shell.tui.open(key)` opens any listed entry without arguments. A launcher lists other plugins' TUIs without depending on them.
   - Exit records: the presenter writes `$XDG_RUNTIME_DIR/vgs/tui/<key>.json` `{ key, code, startedAt, endedAt, log }`; the core watches the directory once and calls each `done({ code })` once, dropped with the instance (the theme runner's lifetime rule). `shell.tui.state` publishes, for the plugin's own keys, `{ running, code, endedAt }` to every instance of that plugin, so a service re-checks after a run a panel started even when that panel was hidden before it ended.
   - CLI and IPC: `vgsh tui list`, `vgsh tui open <key>` (IPC `listTuis`, `openTui`), and `vgsh tui present [--title] [--size] -- argv…` for core commands, which needs no shell running.
7. First core consumers: the Settings window's Update and Add plugin buttons and the theme add flow run `vgsh plugin update|add` and `vgsh theme add|update` in the TUI, so the `[y/N]` diff review stays a question (D007) and `no-terminal` is gone from the GUI path.

**Alternatives rejected.** Omarchy's `bash -c "$*"` launcher (plugin text becomes shell code); QML-drawn TUIs (re-implements a pty, gum, fzf and sudo prompts); plugin-authored window rules (reopens D028 for no need a size class does not meet); a `vgs.system` plugin (decision 3).

**Omarchy comparison.** Copied: the app-id plus window-rule mechanism and 875×600, `xdg-terminal-exec --app-id --title`, logo → command → Done/Failed unless 130, the `/dev/tty` drain and one-key read, parsing the gum colour file rather than sourcing it, sudo once with a keepalive. Adapted: colours from a theme-target file read at each launch rather than login `hl.env`; argv rather than strings; manifest `entry` data rather than JSONC `action` strings with bash `when` conditions; step lines from a library rather than inline escapes; the logo in the theme accent. Not copied: `uwsm-app`, `eval exec setsid`, rewriting the user's `xdg-terminals.list`, `bash -p` on user halves, 470 scripts.

### 2. Package-manager layer (core; issues 6-8, D034)

- `shell/Core/PackageManagers.js` (`.pragma library`, pure): one row per manager: `pacman`, `aur` (overlay: `paru`, else `yay`), `apt`, `dnf` (`dnf5` preferred), `xbps`, `emerge`, `nix`, `flatpak` (overlay), `mise` (source). Each row: detection (binary plus os-release `ID`/`ID_LIKE`), the unprivileged check argv and its exit-code meaning (`checkupdates` 2 = none, dnf 100 = updates), the parser name, install/remove/upgrade argv templates, the owner query. `PluginLogic.js` imports it for manager ids; `bin/vgsh-pkg` loads it through the node library loader.
- `bin/vgsh-pkg` (node): `detect --json` (primary plus overlays), `present <commands…>`, `plan install|remove|upgrade <manager> [names…]` (prints argv, runs nothing), `check --json [--source S]` (per source `{ source, count, packages:[{name,old,new}], checkedAt, error }`, single-flight lock), `run install|remove|upgrade …` (refuses `no-terminal` without a tty; elevation through `sudo`, then `doas`, then `run0`, overridable by a judged `packages.elevate` key in `shell.json`), `install` and `remove` with no names (Omarchy's fzf pickers with a `-Sii`-style preview).
- Parsers are pure functions pinned against canned outputs in `scripts/test-vgsh-pkg.js`; no network in any test.
- Never `pacman -Sy` alone; the full upgrade is `-Syu`. Nix reports "managed by Nix" and takes a configured command.

**Omarchy comparison.** Omarchy is pacman plus yay only, with an ALPM guard because it is a distribution. VGS takes its argv (`--needed`, `-Rns`, `checkupdates`), its fzf pickers and its "AUR after revoking sudo" order, and adds v1's family table so the same flows work wherever the floor is met (DankMaterialShell's "one primary plus overlays" is the prior art). No PackageKit: absent on Arch by default, no AUR, Flatpak or mise.

### 3. External requirements and the core install notice (core; issues 10-14, D035)

- Manifest key: `"requirements": [ { "command": "gum", "packages": { "pacman": "gum", "apt": "gum", "dnf": "gum", "nix": "gum" }, "optional": false, "purpose": "Draws the update dialogs" } ]`. Judged: a command name grammar, manager ids from `PackageManagers.js`, package name grammar, `purpose` printable ≤ 120, no plugin id. The core's own requirements (`gum`, `xdg-terminal-exec`, `fzf`, `git`, `node`, `python3`…) live in `config/requirements.json`, judged by the same function.
- `bin/vgsh-scan` probes every declared command once per scan in the same process (`shutil.which`) and reports `missing`; a rescan follows every TUI install. Manager rows gain `requirements` with state; `vgsh plugin list` prints `missing <id> <command> (<package>)`.
- CLI: `vgsh plugin add` ends by listing unmet requirements and, on a terminal, asks `Install now? [y/N]` and runs `vgsh pkg run install`; `vgsh doctor [--json]` lists the core's and every enabled plugin's requirements; `vgsh plugin requirements <id>`.
- `Dialog` in `qs.Ui` (title, body, actions, Enter/Escape, focus trap, tokens `dialog.*`), then a core `NoticeHost` (centred layer surface on the focused monitor, keyboard on demand) fed by `shell/Core/Notices.qml`. Triggers: `vgsh plugin add` calls IPC `pluginInstalled <id>` on a running shell; `setPluginEnabled` on a plugin with unmet non-optional requirements. The notice lists each package with its purpose; **Install** opens the core TUI `vgsh pkg run install <names>` for the detected manager; **Not now** closes. Missing manager mapping shows the command only.
- The Settings window shows a Requirements section on each plugin page with the same Install action, and gains Update and Add from URL buttons through new `manager` members (`update(id)`, `add()`, `installRequirements(id)`), each a core TUI.

### 4. Passwordless sudo grant (core; issue 9, D036)

`vgsh sudo status|grant [minutes]|revoke|install|uninstall`. `install` (once, explicit, like `vgsh theme browser-policy install`) places the root half `bin/vgsh-sudo-grant` as a root-owned copy and a tmpfiles `r! /etc/sudoers.d/99-vgs-nopasswd-*` rule. `grant` warns, asks one `gum confirm --default=false`, and through `sudo -N` writes `<user> ALL=(ALL) NOTAFTER=<UTC> NOPASSWD: ALL` (default 15, max 1440 minutes), checked with `visudo -cf`, published by rename, expired by a `systemd-run --on-calendar` timer; a second run revokes. Tests run with stand-in `sudo`, `visudo` and `systemd-run`, as `scripts/test-vgsh-browser-policy.sh` does. Omarchy's ALPM revoke hook is not copied (VGS is not the distribution); noted as a revisit when a package can ship a hook.

### 5. Plugin status (core; issue 15, D037)

One convention for a plugin's runtime values, read by its own instances and by the Settings page.

- **Declared.** Manifest `status`: `{ "<key>": { "type", "label", "group"?, "hint"?, "command"?, "hidden"? } }`. Types (`PluginLogic.STATUS_TYPES`): `presence` (present, absent, unsafe), `state` (ok, info, warning, danger, with a text), `text`, `count`, `time`, and `data` (structured JSON for the plugin's own instances, never drawn by Settings). `command` is text the page shows with a Copy button, never run. Judged in `PluginLogic.js`; needs capability `status`.
- **Published.** `shell.status.set(key, value)` for a declared key only, the value judged by its type → `ok` or `refused: status=<key> reason=undeclared|type|size`. `shell.status.values` (deep-frozen, bindable) and `shell.status.revision` reach every instance of the plugin. One record per plugin id in `shell/Core/PluginStatus.qml`, 64 KiB per plugin, dropped on disable and on a source-revision change so a rebuilt service republishes. The service writes; widgets, flyouts and Settings read; one writer per key; a credential's value never enters status, only its presence.
- **Shown.** Manager rows gain `status` (each displayable declaration with its value or `unreported`). `vgs.settings` draws a Status section above the settings form: one read-only row per entry by group, the value with a `Badge` tone for `presence` and `state`, the hint, and the command in a code line with Copy; "Not reported" while the plugin is disabled or silent.
- **First user.** `vgs.notifications` declares `slackToken` (`presence`, "Slack token", group "Slack", hint "Needed for sender photos in Slack notifications", command the `secret-tool store ... service vgs-notifications account slack` line VGS-510 already documents). The token stays in libsecret where VGS-510 (82e1f8c9) put it; the probe reports present, absent, locked or unavailable, never prints the value and never triggers a keyring unlock prompt. The photos are VGS-510's and out of scope.
- **Consumers.** Updates (`pending`, `lastCheck`, `checkState` rows; `sources` data), Agent Warden (`warden`, `agents`, `lastCheck`, `vsys` rows; `detail` data), Dev Tools (`mise`, `installed`, `outdated`, `missingRequirements` rows; `catalog` data).
- **Validation.** `scripts/smoke/rows/status.sh` with fixture `acme.status` (two screens' widgets and a panel read one revision, refusals by text, release on disable); `settings.sh` reads the Status rows back and proves none is editable; `notifications.sh` flips the token file absent, present and unsafe. Controls: a provider with one record per instance, a Settings copy that draws `data`, a token probe that reads the file.

### 6. Manager verbs for updates (core; issues 16 and 18)

- `vgsh plugin outdated [--json]` and `vgsh theme outdated [--json]`: fetch each installed git checkout with hooks off and a timeout, answer `{ id, behind, head, upstream, error }`, run no plugin code, change nothing.
- `vgsh self status [--json]` answers `{ version, method: checkout|package|curl|nix, package: vgs|vgs-git|null, current, latest, behind, error }`; `vgsh self update` acts by method (checkout: `git pull --ff-only`; curl: re-run the pinned installer logic for the latest release; package: refuses and names the package manager step; nix: names the flake command), then `vgsh restart` when the shell runs.

## Plugins

### vgs.updates (issues 42-44)

- **Manifest.** Kinds `service`, `bar-widget`, `panel`. Capabilities `status`, `tui`, `surfaces`, `toasts`, `ipc`, `configure`. `requirements`: `checkupdates` (pacman-contrib, optional), `gum` via core. `tui`: `update` (full pipeline, `tall`), `update-source` (one source). Settings: `intervalHours` (6, min 1, max 48), `hideWhenCurrent` (false), `aurCommand` (empty = `paru -Sua`/`yay -Sua`), `snapshot` (`auto`/`off`), `trustPluginUpdates` (false), `placement`.
- **Service** (the single owner of every probe). One `Process` runs the plugin's `bin/check`, which composes `vgsh pkg check --json` (system, AUR, Flatpak, mise), `vgsh self status --json`, `vgsh plugin outdated --json` and `vgsh theme outdated --json` under one flock and writes `${XDG_STATE_HOME}/vgs/updates/status.json` atomically. On start it publishes the cached snapshot at once and checks only when the snapshot is older than the interval; then every `intervalHours`, on Refresh, on IPC `check`, and when `shell.tui.state` reports that one of its update TUIs ended. A snapshot older than twice the interval is marked stale.
- **Widget and flyout.** The icon rule under Decisions. Left click toggles the flyout anchored to the widget; middle click runs the full pipeline. Flyout: one row per detected source (System, AUR, Flatpak, VGS, Plugins and themes, Dev tools/mise) with its count and an expandable `name old → new` list capped with "+N more", a per-source Update, a primary **Update everything**, and a footer with Refresh, "Checked 14:02" and Open last log. No command text fields.
- **Pipeline** (`tui/update.sh`, modelled on `omarchy-update`): lock and `script` log → free-space warning → plan box and confirm (unless `-y`) → sudo session → snapshot when snapper or timeshift is configured (127 skips quietly) → VGS itself (`vgsh self update` for checkout/curl; package installs ride the system or AUR step, `vgs-git` rebuilt when `self status` says it is behind) → system `vgsh pkg run upgrade` → Flatpak → `MISE_MINIMUM_RELEASE_AGE=0 mise up` → plugins and themes (`vgsh plugin|theme update <id>`, each keeping its diff and `[y/N]`; `--yes` only with `trustPluginUpdates`) → end the sudo session → AUR last with `aurCommand` → orphans prompt (default no) → restart the shell if VGS changed, reboot prompt if the kernel or Hyprland binary was replaced.
- **Omarchy comparison.** Taken: 6 h cadence plus startup plus post-run refresh, one click to the pipeline, its order and its safety steps. Differs: Omarchy's icon tracks only Omarchy itself; Updates counts every source because VGS is not the distribution. Omarchy's migrations, keyring, channel switch and ALPM guard are distribution work and are not copied. Better than v1: one collector, no editable shell commands, a safety net, a transcript, reboot awareness, VGS and plugins covered.

### vgs.devtools (issues 45-47)

- **Catalog** `shell/plugins/vgs.devtools/catalog.json`: v1's `config/vshell/dev-tools.json` entry for entry (16 agents, 5 apps, 9 tools, 13 environments, channels, `buildEnv`, `requires`, `present`, `exec`/`bin_path=`), plus Omarchy's php/laravel/symfony, rails, phoenix, ocaml, the editors (VSCode/VSCodium, Cursor, Zed, Sublime, Helix, Neovim, Emacs), the terminals, and the Docker/Podman databases. Icons are Lucide names; brand colours go to the plugin's appearance table (D023). Distro packages per manager id from `PackageManagers.js`. `postInstall` is a declarative list; curl installers (rustup, opam) are named routes in code. Judged by `scripts/check-devtools-catalog.js`, which refuses any shell string in data.
- **Engine** `bin/devtools` (node): `list --json` (installed state, version, origin: mise, a package manager, `foreign`, or `managedBy`; arch-filtered), `install|remove|update <id>` (distro packages through `vgsh pkg run install`, then `mise use -g`, then `postInstall`), `launchers refresh` (only with `writeLaunchers`, default off; v1's foreign-file rule and D016's exec handling kept). First use sets `mise settings set upgrade.auto_prune false` (Omarchy's reason: a live session keeps the old install). An "Other mise tools" section lists what `mise ls --global --json` holds that no row declares, with update and remove only: the owner's stowed config stays the source of truth.
- **Panel** (kinds `panel`, `service`; capability `status`): the service owns the one `devtools list --json` run and publishes it as plugin status (`mise`, `installed`, `outdated`, `missingRequirements` as Settings rows; `catalog` as data), and answers IPC `open`. Sections VGS, Agents, Apps, CLI tools, Languages, Editors, Databases, Terminals, Other mise tools. The **VGS** section is how VGS manages its own systems: the install method and version from `vgsh self status` (update through Updates) and every missing core or plugin requirement from `vgsh doctor --json` with Install. Mutations run in the TUI; the service re-lists when one ends.
- **Omarchy comparison.** Taken: `mise use --global <lang>@latest`, the environment list, the `MISE_MINIMUM_RELEASE_AGE=0` on explicit updates, the database containers bound to 127.0.0.1, the install-disabled-when-present rule. Differs: one catalog file instead of case arms and a menu; wrappers are opt-in because mise shims already cover them and the owner's `agent-cli` shim is foreign.

### vgs.agent-warden (issues 48-50; vsys items 1-7)

- **vsys side** (separate file): import the warden into vsys with the portability fixes (no `/home/method` paths, parametrised `TMPDIR`, shared mise path rule), one agent-tool list both read, a versioned `status.json` each tick, the notification hand-off (consumer heartbeat, episode dedupe in its own fallback, read-only `--status`), a user-level installer `vsys warden install|uninstall|status` sizing `agents.slice` in percentages of MemTotal, shipping it in `vsys`/`vsys-git` and `install.sh`, and `vsys --once --summary` (verdict ids, levels and meters as numbers, scratch scan skipped).
- **Plugin.** Kinds `service`, `bar-widget`, `panel`. Capabilities `status`, `tui`, `surfaces`, `toasts`, `ipc`, `configure`. `requirements`: `vsys` (AUR `vsys`), `notify-send` (libnotify). `tui`: `vsys` (`plain`, `wide`, runs `vsys`), `setup` (`full`, runs `vsys warden install`).
- **Service**: the one reader of `$XDG_RUNTIME_DIR/agent-warden/status.json` through `WatchedFile`; staleness after 90 s; touches the heartbeat every 60 s; publishes the derived state as plugin status (`warden`, `agents`, `lastCheck`, `vsys` as Settings rows; `detail` as data); runs `vsys --once --summary` once per flyout open, never on a timer; owns notification dedupe (key = kind + scope, capped at 64) and sends through `notify-send -a "Agent Warden" -A open="Open vsys"`, opening the `vsys` TUI on the action. It does not name `notifications`. A `state.json` without `status.json` is the "Update the warden" state, not a degraded parser.
- **Widget and flyout**: the six states (Calm, Working, Needs a look, Problem, Not checking, Not set up) with `shield-*` icons and theme tones; flyout heading, one status sentence, at most three items, one memory meter hidden when unknown, footer "Checked 12 s ago · Open vsys". Setup states: Set up (opens the `setup` TUI), Start it (`systemctl --user start agent-warden.timer` through `run`), Get vsys (core requirement notice). Copy is `agent-warden.md` § UX, verbatim as the starting text.

### vgs.themes: catalog, per-screen wallpaper, browsers (issues 29-41)

- **Catalog** `themes/catalog/<name>/{theme.json,terminal.json}` plus `themes/catalog/index.json` `{ name, mode, thumbnail, palette, imagery: { repo, release, archive, size, sha256 } | null }` and ~480 px thumbnails of each theme's first wallpaper. `ThemeLogic` gains the index judge; `scripts/validate` judges every entry with `acceptPackage` and refuses a curated file on a `runsCode` target (D038). Converted from v1's `colors.toml` and `theme.json` by a one-time converter kept under `tools/`, with a contrast check on `color.textFaint` and the status colours.
- **CLI.** `vgsh theme catalog --json` (index plus `installed`, `imageryInstalled`, `imageryUpdate`); `vgsh theme install <name>` (the add path's staging, judge and lock; marker `.vgs-catalog.json` with the entry digest; `update` and `remove` accept the marker); `vgsh theme wallpapers <name> [--update]` (HTTPS only, streamed to `~/.cache/vgs/theme-assets/<sha256>.tar.gz` outside the lock, size and sha256 checked before unpacking, `backgrounds/*` regular members only, 128 MiB per file, staged then renamed under the theme lock, a `file://` base only in tests); `vgsh theme background list --json [--all]` and `set <path> [--screen <output>]` (D039).
- **Capability.** `theme` gains `catalog`, `install`, `wallpapers`, `images`, `set`; downloads run in a second process slot so a list or apply never waits behind one; `last.downloading` `{ name, bytes, total }` survives a closed overlay.
- **Design system.** `AngledCard` (parallelogram mask through `MultiEffect`, outline, dim wash; tokens `angledCard.*`), `Scrim` (`color.scrim`, click-away), `CardCarousel` (rail geometry scaled by v1's unit clamp, band retention, selection, optional motion on `motion.duration.normal`; tokens `carousel.*` from Omarchy's 768×475, 108×432, −30, 28). Each with a gallery example and a `tst_*.qml` with mutation controls.
- **Browsers.** One `overlay` entry (`Browser.qml`) with payload `{ "view": "themes"|"wallpapers" }`; a new `service` registers `themes` (SUPER+T) and `wallpapers` (SUPER+W) and toggles the view. Theme view: shipped, installed and catalog packages, typed filter, `All / Installed`, card image from the first background, else the thumbnail, else a palette card; Enter installs if needed then applies; the overlay stays open with a spinner and, when the applied theme has undownloaded imagery, shows a `Dialog` card "Download wallpapers for X (N MB)?" (Download / Not now), downloads on the lane and re-applies. Wallpaper view: `Theme / All` (S), `All monitors / This monitor` (Tab or W, shown only with two or more screens, reset per open), Enter sets. Keys copy v1's set. The panel lists catalog themes with Install and gains Add from URL (core TUI `vgsh theme add`).
- **Omarchy comparison.** Copied: the card geometry, the mask technique, the wash and outline alphas, settle-before-reveal, type-to-filter, Esc clears then closes. Differs: Omarchy lists installed themes only and has one background for every monitor; its selection is a file round trip polled with `sleep 0.01`; VGS uses one core job and reads results from `last`. From v1: the scale unit, band retention, thumbnail-for-slice decoding, the two toggles and the offer rule; v1's Starred and Add/Remove-from-theme are dropped (no backing state; D025).

### Launcher and Settings (issues 51 and 14)

The launcher's `install`, `remove` and `update` rows stop being `unavailable`: they open `core/pkg-install`, `core/pkg-remove` and whatever entry an enabled plugin declares in the `update` group (Updates' pipeline), read from `shell.tui.entries`. Settings changes are in § 3.

## Distribution and release (issues 17-28 and 52, D040)

- **Before tagging.** MIT `LICENSE` (package licence `MIT AND OFL-1.1 AND ISC`); `VERSION` 0.1.0; `vgsh --version` (`vgs 0.1.0`, describe form in a checkout); runtime files moved from `scripts/` to `bin/lib/` so the install set is `bin shell config themes VERSION`; a preflight in `vgsh run` refusing `qs` < 0.3.1, Hyprland < 0.56, or missing node/python3/git with a keyed line; autostart documented as `hl.on("hyprland.start", function () hl.exec_cmd("vgsh run") end)`, no systemd unit in 0.1.
- **Install tree.** `packaging/install-system.sh` (DESTDIR/PREFIX, drops AGENTS.md/CLAUDE.md/README.md under `shell/`), a file-list check, and a smoke run from a root-owned read-only prefix proving nothing writes into the tree.
- **Channels.** AUR `vgs` (`arch=any`, release tarball, pinned sha256, `conflicts=(vgs-shell vgs-shell-git)`) and `vgs-git` (`pkgver` from `git describe`, `provides=(vgs=$pkgver)`, `conflicts=(vgs vgs-shell vgs-shell-git)`, no `replaces`); curl `install.sh` (whole body in `main`, refuses root and a system package, checks the floor and prints the distro command, `--proto =https`, SHA256SUMS and optional gpg, `~/.local/share/vgs/<ver>` with an atomic `current` link, `~/.local/bin/vgsh`, `--git`, `--version`, `--uninstall`; never sudo, never edits `hyprland.lua`); `flake.nix` (`stdenvNoCC`, `wrapProgram` with quickshell, nodejs, python3, git, util-linux, gum, xdg-terminal-exec); COPR `vanillagreen/vgs` in 0.1.x.
- **Publishing.** `scripts/release <version>` (tag equals `v$(cat VERSION)`, `git archive --prefix=vgs-X.Y.Z/`, gzip `-n`, SHA256SUMS, detached `.asc`, `gh release create --verify-tag`), `scripts/publish-aur.sh vgs vgs-git` (printsrcinfo check, pinned known_hosts, defer `vgs` until the asset's sha256 matches; vsys's `packaging/publish-aur.sh` is the model). Dropped from v1: the Go matrix, the 6-dialect dependency generator, `check-aur-sync.py`. Parked in the `v1` branch: PPA and Gentoo publishers.
- **Retire.** COPR `vanillagreen/vgs-shell`, PPA `vgs-shell`, OBS `home:vanillagreen/vgs-shell`, the Gentoo overlay's `gui-apps/vgs-shell`, the unused PPA/Launchpad secrets and `CI_RUNNER_2V`, the merged `vgs-4xx/5xx` branches, and after publication AUR merge requests `vgs-shell → vgs` and `vgs-shell-git → vgs-git`. Keep `vgs-themes` and the `v1` branch (README marked unsupported).
- **README.** The install section of `packaging.md` § H, updated for the final commands, the Updates/Dev Tools/Agent Warden/theme catalog rows in Shipped plugins, and the plain deferral statement for Fedora (0.1.x), Debian, Ubuntu, openSUSE, Gentoo and Void.

## Doc updates forced

- New: `docs/architecture/tui.md`, `docs/architecture/packages.md`, `docs/architecture/requirements.md`, `docs/architecture/status.md`, `docs/architecture/theme-catalog.md`, `docs/architecture/distribution.md`; decision files D033-D041; plugin READMEs for `vgs.updates`, `vgs.devtools`, `vgs.agent-warden`.
- Changed: `overview.md` (vocabulary: floating TUI, requirement, status; boundaries: the shell never elevates; decisions list), `plugins.md` (manifest table: `tui`, `requirements`, `status`), `capabilities.md` and `api.md` (`tui`, `status`, `theme` members, `manager` members), `manager.md` (requirements, notice, Update/Add buttons, outdated verbs, the Status section), `vgs.notifications` README (the Slack token row), `configuration.md` (`packages` key), `hyprland.md` (window-rule section), `theme-targets.md` (gum), `themes.md`, `theme-capability.md`, `theme-backgrounds.md` (catalog verbs, download lane, per-screen), `design-system.md` (Dialog, AngledCard, Scrim, CardCarousel), `runtime.md` (preflight, runtime deps, autostart, TUI stand-in in the sandbox), `README.md`, `AGENTS.md` Read next list, the vgs-plugin skill (templates, api reference, checklist for `tui`/`requirements`/`status`), `docs/decisions/INDEX.md`.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| `hl.window_rule` fields unverified on Hyprland v0.56.2 | Issue 3 opens a tiny sandbox client with app-id `org.vgs.tui` and reads `hyprctl clients -j` floating, size and position back, plus an empty `configerrors`; nothing else ships the rule before that row passes. |
| A terminal ignores `--app-id` (wezterm lacked the key as of 2025-08; Ghostty single-instance behaviour unknown) | `vgsh-tui launch` warns when the default entry lacks `X-TerminalArgAppId`; the exit record comes from the presenter inside the terminal, so completion works even when the window tiles; owner-session check listed in issue 3. |
| A restart removes the snapshot under a running TUI | The presenter copies the plugin's `tui/` into a private temporary directory per launch. |
| Download blocks theme applies | Separate process slot, pinned by a smoke row that applies during a slow stand-in download. |
| Key conflicts: the owner's `keybinds.lua` binds SUPER+W (focus up) and SUPER+T (v1 picker), and Hyprland fires every matching bind | README and the themes README name the lines to remove; the owner removes them from dotfiles before issue 39 is used; a later core check of user binds is a revisit, not in scope. |
| Theme conversion fidelity (v1 contrast shortfalls) | Issue 31 runs a contrast check per converted theme and fixes `color.textFaint`/status overrides per theme; a failing theme blocks its own entry, not the catalog. |
| Passwordless grant is a root-equivalent window | Opt-in, time-boxed, `visudo`-checked, boot-cleared, owner-installed root half; security label; tests with stand-ins only. |
| Node minimum version unknown on target distros | Issue 20 records the node floor measured by running the judges under the lowest candidate node in a container; the preflight enforces it. |
| Fedora path rests on two third-party COPRs | 0.1.x only, after a clean `fedora:44` install test. |
| The `status.json` contract drifts between vsys and VGS | The vsys issue ships a schema doc and a fixture file; the VGS smoke row copies that fixture; a schema version refuses an unknown major. |
| Heartbeat hand-off: a hung shell silences both notifiers for 120 s | Accepted; documented in D041. |
| Scope: 52 VGS lanes and 7 vsys lanes | Independent lanes run in parallel (the dependency graph below); plugins wait only on the core pieces they use. |

**Rollback.** Every lane is one PR that lands with its row, so a revert removes one system. A capability revert needs its consumers reverted first (the graph gives the order). Distribution is reversible until issue 52; after it, a bad release is fixed forward with 0.1.1 and the AUR recipe, never by deleting the tag. The stale-channel removal (issue 28) is irreversible and runs only after the owner confirms the list.

## Ordered issue list

`#` is the index in `tmp/audit-oversee-platform.json`. "After" lists real data-flow blockers only; everything else runs in parallel.

| # | Title | After | Est | P |
|---|---|---|---|---|
| 1 | Floating TUI presenter: vgsh tui present, library and logo | — | 3 | 2 |
| 2 | Theme target gum: themed colours for floating TUIs | 1 | 2 | 2 |
| 3 | Core window rule floats floating TUIs in the Hyprland layer | — | 3 | 2 |
| 4 | tui capability and manifest key: plugins open declared scripts | 1 | 4 | 2 |
| 5 | TUI exit records, completion callbacks and focus of a live TUI | 4 | 3 | 2 |
| 6 | Package-manager table and vgsh pkg detect, present and plan | — | 3 | 2 |
| 7 | vgsh pkg check: unprivileged update parsers per manager | 6 | 3 | 2 |
| 8 | vgsh pkg install, remove and upgrade in the floating TUI | 1, 6 | 4 | 2 |
| 9 | Time-boxed passwordless sudo grant as a core TUI | 1 | 4 | 3 |
| 10 | Manifest requirements key: plugins declare external packages | 6 | 4 | 2 |
| 11 | vgsh doctor and requirement install on vgsh plugin add | 8, 10 | 2 | 2 |
| 12 | Dialog component in qs.Ui | — | 3 | 2 |
| 13 | Core requirement notice with one-click install | 4, 8, 10, 12 | 5 | 2 |
| 14 | Settings: Update, Add from URL and requirement installs via core TUIs | 4, 8, 10 | 4 | 2 |
| 15 | Plugin status: published runtime values and read-only Settings rows | — | 5 | 2 |
| 16 | vgsh plugin outdated and vgsh theme outdated | — | 3 | 2 |
| 17 | LICENSE, VERSION and vgsh --version | — | 2 | 2 |
| 18 | vgsh self status and update by install method | 17 | 3 | 2 |
| 19 | Move runtime files out of scripts/ into bin/lib | — | 2 | 2 |
| 20 | Runtime preflight and runtime dependency floor | — | 3 | 2 |
| 21 | Shared installer and a read-only install tree smoke | 17, 19 | 3 | 2 |
| 22 | AUR recipes for vgs and vgs-git | 21 | 3 | 2 |
| 23 | Curl installer: user-local, sudo-free, checksummed | 18, 21 | 4 | 2 |
| 24 | Nix flake for vgs | 21 | 3 | 2 |
| 25 | Local release and AUR publish scripts | 22, 23 | 4 | 2 |
| 26 | Fedora COPR recipes for vgs and vgs-git (0.1.x) | 21 | 3 | 3 |
| 27 | README install section and distribution support statement | 20, 22, 23, 24 | 2 | 2 |
| 28 | Retire stale v1 distribution channels and secrets | — | 2 | 2 |
| 29 | Theme catalog format, index judge and validation | — | 3 | 2 |
| 30 | v1-to-v2 theme converter and catalog thumbnails | 29 | 3 | 2 |
| 31 | Convert and contrast-check v1's themes into the catalog | 30 | 4 | 2 |
| 32 | vgsh theme catalog and vgsh theme install | 29 | 4 | 2 |
| 33 | vgsh theme wallpapers: verified on-demand download | 32 | 4 | 2 |
| 34 | Per-screen wallpaper state and vgsh theme background list and set | — | 3 | 2 |
| 35 | vgs.themes draws each screen's own wallpaper | 34 | 2 | 2 |
| 36 | theme capability: catalog, install, wallpapers, images, set and a download lane | 32, 33, 34 | 4 | 2 |
| 37 | AngledCard and Scrim components with their tokens | — | 3 | 2 |
| 38 | CardCarousel component with carousel tokens | 37 | 4 | 2 |
| 39 | vgs.themes: full-screen theme browser on SUPER+T | 12, 36, 38 | 5 | 2 |
| 40 | vgs.themes: wallpaper browser on SUPER+W with source and monitor toggles | 35, 39 | 4 | 2 |
| 41 | vgs.themes panel lists catalog themes and adds from a URL | 4, 36 | 2 | 2 |
| 42 | vgs.updates: service, checks and shared state | 5, 7, 15, 16, 18 | 5 | 2 |
| 43 | vgs.updates: bar widget and flyout | 42 | 4 | 2 |
| 44 | vgs.updates: the update pipeline in the floating TUI | 4, 8, 16, 18, 42 | 5 | 2 |
| 45 | vgs.devtools: catalog from v1 and Omarchy, with its judge | 6 | 4 | 3 |
| 46 | vgs.devtools: install, remove and update engine | 8, 45 | 5 | 3 |
| 47 | vgs.devtools: catalog panel and VGS section | 5, 11, 15, 46 | 5 | 3 |
| 48 | vgs.agent-warden: service reads warden status and publishes state | 15 | 4 | 2 |
| 49 | vgs.agent-warden: notifications with plain copy, once per episode | 4, 48 | 3 | 2 |
| 50 | vgs.agent-warden: bar widget, flyout and Open vsys | 4, 48 | 4 | 2 |
| 51 | Launcher: Install, Remove and Update rows open TUIs | 4, 8 | 2 | 3 |
| 52 | Release VGS 0.1.0 publicly | 17-25, 27, 28, 31, 32, 33, 41 | 3 | 2 |

vsys (team `vsys`, `tmp/audit-vsys-platform.json`, executed in `~/dev/vsys`):

| # | Title | After | Est |
|---|---|---|---|
| 1 | Import agent-warden into vsys as a supported component | — | 3 |
| 2 | One agent-tool classification list for vsys and the warden | 1 | 2 |
| 3 | Warden writes a versioned status.json every tick | 1 | 3 |
| 4 | Warden notification hand-off, episode dedupe and read-only --status | 1 | 2 |
| 5 | User-level warden installer: vsys warden install | 1 | 3 |
| 6 | Ship the warden in vsys packages and install.sh | 5 | 2 |
| 7 | vsys --once --summary: a cheap verdict JSON | — | 3 |

Cross-tracker blockers (filed as relations after both batches exist): VGS 48 after vsys 3; VGS 49 after vsys 4; VGS 50 after vsys 5 and 7.

## Consequences

**TPM handoff: needed.** The plan implies filing 52 issues in team `vgs` (project `V2 Shell`) and 7 in team `vsys`, with blocking relations inside each batch and four across teams, plus a label preflight against live inventory. That is tracker work this agent does not do.

Prompt for the calling agent to pass to `tpm`:

> Run audit-issues on `/home/method/dev/vgs/tmp/audit-oversee-platform.json` (team `vgs`, project `V2 Shell`) and `/home/method/dev/vgs/tmp/audit-vsys-platform.json` (team `vsys`, worktree `/home/method/dev/vsys`). Both are `source: oversee`, `origin: planned`, from `docs/plans/v2-platform-roadmap.md`. Preflight every label against live inventory and stop on a missing one. Dedupe against both trackers (Linear cache and `gh issue list` for vanillagreencom/vgs and vanillagreencom/vsys). Keep the batch's `blocked_by_items` as blocking relations; after both batches exist, add the cross-team relations: VGS item 48 blocked by vsys item 3, VGS 49 by vsys 4, VGS 50 by vsys 5 and vsys 7. Do not merge items: each is sized for one lane. Place nothing in a new project.

## Handoff prompt for implementers

> Implement one issue from the V2 platform roadmap (`docs/plans/v2-platform-roadmap.md`). Read `AGENTS.md`, the architecture docs the issue names, and the roadmap's § Decisions for the decision record your issue lands (D033-D041 or a revisit outcome), and load the code-quality skill (and vgs-plugin for plugin work) before editing. Land the system with its judge in `PluginLogic.js`/`ThemeLogic.js` where it decides anything, its validation row (unit test with a control per rule, and a `scripts/smoke/rows/` row read back from the nested sandbox for anything the shell runs), its contract doc and its decision record in the same change. Plugins compose `qs.Ui` and tokens only; no literal style value. No plugin text reaches Lua or a shell string; scripts receive argv. The shell never elevates; every `sudo` happens inside a floating TUI. Never start a shell against the live session; stand-ins replace `xdg-terminal-exec`, package managers and network in every test. Include the Omarchy comparison the issue asks for in its decision record or doc. Run `scripts/validate` once on the final diff and push to `main`.
