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
| `greeter` | VGS greetd greeter, Hyprland or Niri launch, GNOME keyring policy, optional fprint/U2F PAM support |
| `capture` | Screenshots |
| `capture-edit` | Screenshot editor |
| `ocr` | Region OCR |
| `recording` | Screen recording |
| `launcher-zoxide` | Optional recent-directory search mode in launcher/menu |
| `network-usage` | Per-interface traffic statistics |
| `gamma` | Night-light color temperature |
| `updates-arch` | Repo updates |
| `updates-aur` | AUR updates |
| `ai-usage` | AI usage widget backend |
| `tailscale` | Tailscale widget |
| `clipboard` | Clipboard history (wl-clipboard) |
| `thumbnails` | File/image thumbnails |
| `brightness` | Display brightness backends |
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
