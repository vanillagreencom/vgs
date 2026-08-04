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
A user package replaces a shipped package for a **bundled id** only if its manifest says that is
what it means:

```json
{ "id": "vgsMenu", "overrides": "vgsMenu" }
```

`overrides` accepts the id, a list of ids, or `true` ("whatever id I declare"). Declaring it is
the whole trust decision — the loader never infers an override from a name match.

| The package | What VGS does |
|-------------|---------------|
| Declares the override | Replaces the shipped package, and inherits **always-available**: auto-enabled without the user turning it on, and `disablePlugin` refuses it |
| Reuses a bundled id without `overrides` | Stays inert. The shipped package keeps the id, and a one-time toast names the collision |

Always-available exists because an override that owns the id and never starts is a product surface
that goes dark — `vgsMenu` is the app launcher and the shell ships no fallback. It is *not* extended
to a bare collision, because auto-loading a package the user never enabled purely because its id
matches something VGS happens to ship is a decision nobody made. Scan order does not matter: the
bundled directory can be read after the user one, and a colliding package that got the id first is
reclaimed when the shipped manifest is parsed.

Because always-available packages cannot be disabled, Settings → Plugins does not offer them a
disable toggle at all — it shows an "Always on" badge instead of a control that can only refuse
(`Modules/Settings/PluginListItem.qml`). `vshell ipc call plugins disable <id>` answers
`PLUGIN_ALWAYS_AVAILABLE: <id>`, distinct from `PLUGIN_DISABLE_FAILED`.

Enabled is not the same as loaded, and an override still has to provide the surface the shipped
package did. **The swap is gated:** `_onManifestParsed` runs the override's `startupCheck` and loads
it *before* the shipped package is unloaded. If the gate fails, `requires_shell` is incompatible, or
the components fail to load, the override is demoted — the shipped package keeps (or takes back) the
id and stays loaded, and a toast names the override and the reason. An override that loads but drops
its daemon surface or its `toggle()` is still a way to disable the launcher: the dock and bar buttons
then report "App launcher unavailable" via `PluginService.toggleAppLauncher()` instead of doing
nothing.

`_bundledPluginIds` tracks ids seen from the bundled directory and is cleared when the last bundled
manifest for an id disappears, so a shipped package that is removed stops making a same-id user
package auto-enabled and undisableable.

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
same-purpose alternatives, and `compositorCommands` for complete
Hyprland/Niri-specific command lists. `vshell deps` selects only the active
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
| `sudo-toggle` | Passwordless sudo toggle widget (`vshell sudo-toggle`) |
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
reason in the `undeclared` map at the top of `dependencies.json`; the remaining
user-facing gaps (`nautilus`, `yazi`, `xdg-terminal-exec`) are tracked in
VGS-32, and VGS-33 tracks the automated check that would keep the probe sites
and the manifest from drifting apart again.
