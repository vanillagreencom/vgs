# Bundled icon themes — attribution

The icon themes in this directory are the **Yaru** icon theme and its accent colour variants, vendored from the Ubuntu Yaru project so VGS themes' icon pointers (`themes/<name>/apps/icons.theme`) resolve without a system `yaru-icon-theme` package installed.

- **Upstream:** https://github.com/ubuntu/yaru
- **Version:** 26.10.1 (yaru-theme-icon)
- **Copyright:** © Canonical Ltd. and the Yaru authors
- **License:** dual-licensed **CC-BY-SA-4.0** and **GPL-3.0-or-later** (see the upstream `LICENSE`). Redistribution here preserves those terms; the icons are unmodified.

Bundled variants: `Yaru`, `Yaru-dark`, `Yaru-blue`, `Yaru-blue-dark`, `Yaru-magenta`, `Yaru-olive`, `Yaru-purple`, `Yaru-red`, `Yaru-sage`, `Yaru-sage-dark`, `Yaru-wartybrown`, `Yaru-prussiangreen`.

`bin/vshell-helper` (`ensure_bundled_icon_themes`) symlinks these into `~/.local/share/icons` on icon-theme apply / settings enumeration, unless a real system or user install of the same name already exists (which always wins).
