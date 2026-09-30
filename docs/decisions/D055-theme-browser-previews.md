# D055: Theme browser previews prefer package images, then live token previews

[← Decision Index](INDEX.md)

**Date**: 2026-09-29
**Status**: Active
**Research**: VGS-598
**Refines**: [D015](D015-tokens-are-a-judged-table.md), [D038](D038-judged-theme-catalog.md), [D048](D048-theme-owned-hyprland-appearance.md)

**Context**: The theme browser stretched 480 px catalog thumbnails across a large centre card. The result was blurry on the owner's large high-DPI monitor. Omarchy ships a `preview.png` screenshot in each theme and its picker draws that image. VGS also needs user-installed themes to preview accurately without requiring generated screenshots.

**Decision**: A package `preview.png` wins when it exists. Without it, the selected theme card renders a live QML desktop preview from the package's resolved shell tokens, terminal slots and wallpaper. Non-selected cards stay cheap image or palette cards. Catalog cards can request a cached preview image for the selected card only; the browser does not contact the network when it opens.

**Rationale**:

- `preview.png` matches Omarchy's author convention and lets a package author supply a composed screenshot.
- The live preview stays sharp at any size and works for installed themes that did not ship a screenshot.
- The live preview reads the package's own resolved tokens, including `hyprland.border.size`, `hyprland.window.radius` and terminal colours, so it does not show the currently applied theme by mistake.
- The carousel still builds only the current card, its neighbours and a bounded band. It requests full decode size only for the current card and neighbours.
- The source images now decode at the card's drawn size times the screen device pixel ratio, capped at 4096 on the longer side. The old 2560 cap was below the owner's centre-card size at scale 2.
- The main theme runner queue owns `apply` and `install`. The download lane owns `wallpapers`. The separate preview process is canceled before any of those user actions starts, so preview fetches never make them answer busy.

## Measurements

Measured on this worktree on 2026-09-29.

| Option | Package size | First-open latency | Memory | Scroll frame time | Result |
|---|---:|---:|---:|---:|---|
| Keep 480 px JPEG thumbnails | 1419402 bytes for 81 files | no new work on open | unchanged by this change | bounded by existing carousel band | Rejected as the only preview because it is the blur source. |
| Ship 1920 px JPEG from a real archive image | 459641 bytes for the sampled image | no network on open | more decoded pixels when selected | same carousel band | Rejected because the package grows for every catalog entry. |
| Ship 1920 px WebP or AVIF from a real archive image | 328264 bytes WebP, 123653 bytes AVIF for the sampled image | no network on open | no usable Qt decode here | same carousel band | Rejected because this Qt install has no WebP or AVIF image plugin. |
| Live QML plus selected-card cached preview | 0 shipped bytes beyond optional package `preview.png` | no network on open; sampled preview fetch 0.95 s after dwell | one live preview and bounded image decodes; sampled fetch max RSS 108500 KiB | nested smoke stayed within the existing first-bar and memory budgets | Chosen. |

The JPEG, WebP and AVIF rows used `magick` on the first image of the pinned Nord archive, fetched with `vgsh theme preview` into a temporary `XDG_CACHE_HOME` on 2026-09-29. The preview image written to cache was 3181112 bytes, and the archive cache held 0 bytes after extraction. `/usr/lib/qt6/plugins/imageformats` contained gif, ico, jpeg and svg plugins, and no WebP or AVIF plugin. The final nested smoke read `latency_first_bar_ms=234`, `rss_kib=445000` and `hwm_kib=723216`.

**Revisit When**: Catalog previews need author-controlled screenshots for most themes, the preview cache causes measured memory growth, or Qt image decoder support changes for WebP or AVIF.

**Verification**: `scripts/qml-tests/tst_desktoppreview.qml` verifies the live preview uses package palette, terminal and Hyprland tokens. `scripts/qml-tests/tst_carousel.qml` verifies card decode sizes and the current-card signal. `scripts/smoke/rows/theme-browser.sh` verifies source size, live token use and `preview.png` precedence with controls.

**References**: [theme-catalog.md](../architecture/theme-catalog.md), [components-media.md](../architecture/components-media.md), [D038](D038-judged-theme-catalog.md), [D048](D048-theme-owned-hyprland-appearance.md)
