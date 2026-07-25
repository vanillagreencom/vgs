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

Feature groups:
| Feature | Purpose |
|---------|---------|
| `base` | Shell runtime |
| `theme` | Theme engine |
| `greeter` | VGS greetd greeter, Hyprland launch, GNOME keyring policy, optional fprint/U2F PAM support |
| `capture` | Screenshots |
| `capture-edit` | Screenshot editor |
| `ocr` | Region OCR |
| `recording` | Screen recording |
| `updates-arch` | Repo updates |
| `updates-aur` | AUR updates |
| `ai-usage` | AI usage widget backend |
| `tailscale` | Tailscale widget |
| `clipboard` | Clipboard history (wl-clipboard) |
| `thumbnails` | File/image thumbnails |
| `brightness` | Display brightness backends |

## Rules
- Missing optional deps must not crash shell.
- Widgets show unavailable/empty state when backend missing.
- VGS ships defaults and bundled plugin code; `~/.config/vshell` holds mutable user state.
- Dotfiles supplies private overlays/wiring, not whole-directory VGS config symlinks.
- No personal command is required for default VGS startup.
