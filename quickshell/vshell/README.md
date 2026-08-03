# VGS / VanillaGreen Shell

VGS is the active Hyprland and Niri Quickshell runtime for this workstation. It is self-contained for shell control, wallpaper/theme generation, clipboard history, capture workflows, and app theme output. Historical lineage is documented in the repo-root `docs/ATTRIBUTION.md`.

Runtime:
- Service: `vshell.service`
- CLI: `vshell`
- Quickshell config name: `vshell` (started by `vshell.service`; do not launch a second instance by hand — use `scripts/qml-smoke.sh` to validate)
- App id: `com.vanillagreen.vshell`

Theme ownership:
- VGS owns wallpapers, palette extraction, blueprint storage, shell colors, and app theme generation.
- Built-in assets live in `themes/` at the repo root.
- User themes live under `~/.config/vshell/`.
- `Common/MethodTheme.qml` watches `~/.config/vshell/theme.json` and exposes tokens to QML widgets.

Key commands:

```bash
vshell theme list
vshell theme apply tokyo-night
vshell theme extract-wallpaper ~/Pictures/wall.jpg --mode auto --apply
vshell theme apply-colors --set background=#101010 --set accent=#88ccff
vshell theme save-current --name wall
vshell theme import-colors ./colors.toml --name imported --apply
```

Operational note: VGS does not keep a disabled rollback shell service in normal workstation wiring. If a rollback is ever needed, reinstall or restore another shell explicitly instead of depending on this runtime.
