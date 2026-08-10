# Theme engine reference

Mechanism truth — package format, sources and user overlays, curated-vs-generated
rules, the apply flow, wallpaper commands, and the generated-target table — lives
in `docs/architecture/theme-architecture.md`; the hard rules are AGENTS.md
§ Theme rules. This file keeps only the operational notes for working on the
engine.

## Working rules
- Implement role derivation and rendering in `bin/vshell-helper`; QML
  (`Services/VGSThemeService.qml`, `Common/MethodTheme.qml`) stays
  UI/orchestration only.
- New target: add `themes/targets/<id>/config.json` plus templates. Add token
  support in the helper before using new token forms in a template.
- Keep generated output paths VGS-named.

## Validation
```bash
python3 -m py_compile bin/vshell-helper
bash -n bin/vshell
vshell theme list --json
vshell theme current --json
vshell theme apply tokyo-night --json
git diff --check
```

After changing a target, spot-check its generated output — paths are tabulated
in `docs/architecture/theme-architecture.md` § Generated targets (e.g.
`~/.config/vshell/theme.json`, `~/.config/ghostty/themes/vgs`,
`~/.local/share/vshell/theme.nvim.lua`).
