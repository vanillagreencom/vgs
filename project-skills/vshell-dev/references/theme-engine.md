# Theme engine reference

## Ownership
VGS owns theme generation. External theme engines do not participate at runtime.

## Main files
| File | Role |
|------|------|
| `bin/vshell` | CLI wrapper and command dispatch |
| `bin/vshell-helper` | Theme engine, palette parsing, template render, OS helpers |
| `Services/VGSThemeService.qml` | QML service for theme list/current/apply flows |
| `Common/MethodTheme.qml` | Theme tokens for QML |
| `themes/<name>/` | Built-in theme packages (`theme.json`, `colors.toml`, `backgrounds/`, optional curated `apps/`) |
| `themes/targets/*/config.json` | Generated target metadata |

## Theme package shape
Built-in themes are directory packages: `themes/<name>/theme.json` (metadata,
mode, source), `colors.toml` (palette), `backgrounds/` (wallpapers), and an
optional curated `apps/` directory. User themes overlay from
`~/.config/vshell/themes/<name>/` (file-level, user wins). Legacy v1 flat-JSON
blueprints only exist user-side (`~/.config/vshell/blueprints/`) and convert
via `vshell theme migrate`.

## Target shape
Each target directory contains `config.json` plus one or more templates.
`config.json` defines generated output path and source templates.

Use template tokens:
```text
{background}
{background.strip}
{background.rgb}
```

Add token support in helper before using new token forms.

## Apply flow
```bash
vshell theme apply tokyo-night
```

Flow:
1. Resolve built-in or user blueprint.
2. Normalize roles.
3. Write `~/.config/vshell/theme.json`.
4. Render targets.
5. Run reload hooks where configured.

## Wallpaper flow
```bash
vshell theme set-wallpaper <path>
vshell theme set-wallpaper <path> --extract --mode auto|light|dark
vshell theme apply-colors --set background=#111111 --set accent=#88ccff
vshell theme save-current --name <new-name>
vshell theme clear-wallpaper
```

Rules:
- No `--extract`: preserve current theme name/colors.
- With `--extract`: generate/apply transient image colors; do not create user blueprints unless `--save` is explicit.
- Save named reusable themes with `save-current`.
- Clear: remove wallpaper from current theme state.

## Validation
```bash
python3 -m py_compile bin/vshell-helper
bash -n bin/vshell
vshell theme list --json
vshell theme current --json
vshell theme apply tokyo-night --json
git diff --check
```

Check generated files when changing targets:
```bash
~/.config/vshell/theme.json
~/.config/hypr/vgs/colors.lua
~/.config/ghostty/themes/vgs
~/.config/alacritty/vgs.toml
~/.local/share/vshell/theme.nvim.lua
~/.pi/agent/themes/vgs-theme.json
```
