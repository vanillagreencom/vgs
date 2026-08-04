# Overlays and dependencies

## Boundary
| Kind | VGS | Local overlay |
|------|-----|---------------|
| Shell UX | Default modules, widgets, helpers, bundled plugins | Extra commands and local labels |
| Defaults | Shipped `*.default.json` seeds | Mutable `~/.config/vshell/*.json` state |
| Dependencies | Feature groups and checks | Installed package set |
| Backends | Generic commands/adapters | Personal scripts, accounts, secrets |
| Machine prefs | Safe defaults | Monitors, geometry, profiles |

## Local overlay paths
| Path | Role |
|------|------|
| `~/.config/vshell/settings.json` | Mutable user shell settings; not tracked |
| `~/.config/vshell/plugin_settings.json` | Mutable user plugin enablement/settings; not tracked |
| `~/.config/vshell/plugins/` | User plugin overrides; takes precedence over bundled plugins |
| `~/.config/vshell-local/menu.json` | Menu categories/items overlay |
| `~/.config/vshell-local/webapps.json` | Generated webapp menu items |

### Overriding a bundled id
A user override that reuses a **bundled id** replaces the shipped package for that id.
`PluginService._onManifestParsed` keys auto-enable on the id rather than on the winning source,
so the override is always *enabled* — it cannot be left owned-but-never-started, and
`disablePlugin` refuses it for the same reason.

Enabled is not the same as loaded, and the override still has to provide the surface the shipped
package did. `vgsMenu` is the app launcher and the shell ships no fallback, so an override that
drops its daemon surface or its `toggle()` disables the launcher; the dock and bar buttons then
report "App launcher unavailable" via `PluginService.toggleAppLauncher()` instead of doing
nothing. An override that fails its `startupCheck` or declares an incompatible `requires_shell`
leaves the id with no loaded package at all — there is no demotion back to the shipped one.
That gap is tracked as VGS-24.

## Menu overlay schema
```json
{
  "categories": [
    { "id": "local", "label": "Local", "icon": "*", "description": "Local actions" }
  ],
  "items": [
    {
      "category": "local",
      "title": "Action",
      "subtitle": "What it does",
      "icon": "*",
      "keywords": ["search"],
      "argv": ["command", "arg"]
    }
  ]
}
```

`{home}` expands to `$HOME` in `argv`.

## Webapp overlay schema
```json
{ "items": [ { "category": "webapps", "title": "App", "argv": ["command"] } ] }
```

## Dependency manifest
Path: `config/vshell/dependencies.json`.

Commands:
```bash
vshell deps status --json
vshell deps check capture --json
```

The `undeclared` map at the top of the file records commands `bin/vshell-helper`
probes but deliberately does not declare, one reason each. Nothing reads it at
runtime; it is what tells a deliberate exclusion from drift. Adding a new probe
means declaring the command under `features` or adding it there.

Manifest entries use `commands` for unconditional tools, `anyCommands` for
same-purpose alternatives, `compositorCommands` for complete
Hyprland/Niri-specific command lists, and `requiresFeatures` to depend on
another feature group rather than restating its commands — a group whose
requirement is unavailable reports `@<feature>` in its own `missing` list. `vshell deps` selects only the active
compositor branch; without an active session, any fully available branch is
accepted.

Feature groups:
| Feature | Purpose |
|---------|---------|
| `base` | Shell runtime |
| `theme` | Theme engine |
| `theme-gtk` | GTK theme, icon theme and color-scheme application (gsettings) |
| `theme-firefox` | Firefox theming (pywalfox) |
| `fonts` | Font cache refresh after a font change (fc-cache) |
| `greeter` | VGS greetd greeter, Hyprland or Niri launch, GNOME keyring policy, optional fprint/U2F PAM support |
| `capture` | Screenshots |
| `capture-edit` | Screenshot editor |
| `ocr` | Region OCR |
| `recording` | Screen recording |
| `launcher-zoxide` | Optional recent-directory search mode in launcher/menu |
| `launcher-search` | Launcher text search (ripgrep). Missing means text search fails outright |
| `launcher-search-fast` | Faster launcher file search (fd). Missing only means the built-in directory walk is used |
| `trash` | Trash instead of deleting, keeping restore (gio) |
| `launcher-folder-open` | Launcher "Preferred app" folder opener, which runs `gio open` |
| `network-usage` | Per-interface traffic statistics |
| `gamma` | Night-light color temperature |
| `updates-arch` | Repo updates |
| `updates-aur` | AUR updates |
| `ai-usage` | AI usage widget backend |
| `tailscale` | Tailscale widget |
| `clipboard` | Clipboard history (wl-clipboard) |
| `thumbnails` | File/image thumbnails |
| `brightness` | Display brightness backends |
| `sudo-toggle` | Passwordless sudo toggle widget: status and **revoke**, which need no terminal |
| `sudo-toggle-grant` | **Granting** passwordless sudo, which needs a terminal to prompt in |
| `terminal` | The terminal VGS opens for TUI actions. Any one alternative is enough |
| `default-apps` | XDG default-application layer (`xdg-mime`) |
| `file-manager` | File manager the launcher opens folders with, when the XDG default resolves to none |
| `launcher-folder-open-yazi` | Launcher Yazi folder opener (needs `yazi` *and* `terminal`) |
| `app-scopes` | Launching apps into their own systemd scope (`uwsm`) |
| `cloud-sync` | Cloud file sync (rclone) |
| `cloud-sync-stream` | Cloud sync streaming FUSE mounts |

## Packaging metadata
The manifest is also what the native packages advertise as optional
dependencies. `packaging/optional-packages.json` maps every manifest command to
a distribution package name (or a `skip` reason when a hard dependency already
covers it), and `scripts/gen-package-metadata.py` joins the two files and
rewrites the generated blocks in the Arch, Debian, Fedora, and Gentoo recipes.

```bash
scripts/gen-package-metadata.py            # verify
scripts/gen-package-metadata.py --write    # regenerate
```

Adding a command to `dependencies.json` without a mapping entry fails the check,
so the packaging cannot silently fall behind the manifest. Details and the
per-channel mechanisms are in `packaging/README.md`.

## Rules
- Missing optional deps must not crash shell.
- Widgets show unavailable/empty state when backend missing.
- VGS ships defaults and bundled plugin code; `~/.config/vshell` holds mutable user state.
- Dotfiles supplies private overlays/wiring, not whole-directory VGS config symlinks.
- No personal command is required for default VGS startup.

## Probing rules

**Rule (enforced).** Shipped code must not probe for a command that exists only
in a private dotfiles repo — one no distribution packages and VGS does not ship.
A private wrapper belongs behind a user setting the shipped code already passes
through (the launcher folder opener uses `launcherFolderOpenCommand`), not behind
a `which()` on its name.

Known exceptions, both of which fall back to `xdg-open` rather than advertising
an action they cannot perform:

| Site | Command |
|------|---------|
| `bin/vshell-capture-screenshot` § `open_folder` | `yazi-scratchpad-open` |
| `bin/vshell-capture-screenrecording` § `open_folder` | `yazi-scratchpad-open` |

**Target (not yet true).** Every distribution-installable command that gates
user-facing behaviour should be declared under `features` in
`dependencies.json`, so `vshell deps status` can report it. The tree does not
satisfy this yet. Commands deliberately left undeclared are listed with their
reason in the `undeclared` map at the top of `dependencies.json`.

## Terminal and file-manager resolution

VGS resolves a terminal in exactly one place: `bin/vshell-helper`, reached from
everywhere else through the `vshell terminal` CLI. QML, plugin JS, bash and the
Go backend all call it; none of them names a terminal binary, and nothing
outside it invokes `xdg-terminal-exec` or `uwsm`.

```bash
vshell terminal resolve [--json] [--prefer TERM]  # what would be used, and why
vshell terminal open [--app-id ID]                # a terminal window
vshell terminal exec [--app-id ID|--tui] [--hold] [--wait] [--prefer TERM] \
                     -- <cmd> [args...]
```

The chain, most preferred first:

| Source | Where it comes from |
|--------|---------------------|
| `--prefer` | a terminal the caller already resolved and must not have discarded (the backend's `upgradeParams.terminal`) |
| `terminalOverride` | Settings -> Launcher terminal picker, stored in `session.json` |
| `$TERMINAL` | the session environment |
| `xdg-terminal-exec` | the full XDG terminal spec, when it happens to be installed |
| `xdg-terminals.list` | the same user choice, parsed directly — Settings -> Default Apps -> Terminal writes this file |
| installed terminals | `TERMINAL_CANDIDATES` in the helper, mirrored by the `terminal` feature group |

`xdg-terminal-exec` is **AUR-only**, so it is an alternative and never a
requirement: a default install with any terminal at all works. It is
deliberately *not* one of the `terminal` feature group's alternatives — it
launches a terminal rather than being one, so counting it would report the
group available on a machine with no terminal installed, which is the VGS-54
defect in a new costume. It sits in the `undeclared` map with that reason. Each terminal's
argv shape (`-e` vs `--`, `--class=` vs `--app-id=` vs `-class`) lives in
`TERMINAL_SPECS`; a terminal with no app-id equivalent has the app-id dropped
rather than passed as an option it would reject. `uwsm app --` is prepended only
when uwsm is present and the session is systemd — it is an enhancement, and
hardcoding it is what made every VGS terminal action fail with
`command not found` on installs without it (VGS-54). Because presence does not
prove the session can use it, usability is settled once per process with a
`uwsm app -- true` probe rather than by watching the payload die — retrying the
payload unscoped would run the user's command twice. `VSHELL_NO_APP_SCOPE=1`
turns it off outright (the capture and screensaver scripts honour the same
variable).

A terminal that exits within the settle window only means the *terminal* failed
when the payload cannot itself exit fast, which is what `--hold`'s wrapper
guarantees. Without `--hold` the status belongs to the user's command, so the
next candidate is **not** tried: retrying would flash a window and re-run that
command once per installed terminal.

Failures reach the user, not just stderr. Every call site launches through
`Quickshell.execDetached`, which discards output and exit status, so
`vshell terminal` reports "no terminal found" through the shell's toast IPC,
falling back to `notify-send`. A button that cannot work has to say so — a
silent no-op is worse than the `command not found` toast VGS-54 was reported
for.

By default `vshell terminal exec` returns as soon as the window is up. A caller
that treats that exit as "the command finished" — the backend's upgrade
supervisor does, and would otherwise permit a second package-manager run on top
of a live one — must pass `--wait`, which blocks for the terminal's whole
lifetime and returns its status.

Granting passwordless sudo needs a terminal to prompt in; reading status and
**revoking** a grant do not. The widget gates on `vshell sudo-toggle status`
rather than on `deps`, so the safety valve works either way — but the two halves
are separate feature groups (`sudo-toggle`, `sudo-toggle-grant`) so that
`vshell deps status` says the same thing the runtime does. Collapsing them would
have the reporting layer tell a terminal-less user they cannot take back a grant
they can always take back (VGS-11).

The file manager follows the same rule: `xdg-mime query default inode/directory`
first — the XDG layer Settings -> Default Apps writes — then the installed
candidates in the `file-manager` group. An entry with `Terminal=true` (yazi,
ranger, lf) is opened through the terminal resolver, so a TUI default is a
legitimate choice rather than a folder that never opens.
