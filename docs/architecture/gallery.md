# Gallery

Covers: shell/plugins/vgs.gallery/**, scripts/smoke/rows/gallery.sh

The first-party window that previews every component of `qs.Ui`, whose guarantees are in [components.md](components.md) and [components-media.md](components-media.md).

`shell/plugins/vgs.gallery` is a first-party application window ([surfaces.md](surfaces.md)) that draws every component in every variant and state, and every role of `Theme.text` in its typography section, read from the group itself, so a theme author previews a whole theme at once. It is built only while summoned; `scripts/smoke/rows/gallery.sh` summons it, reads its section and component counts back, holds every example inside the window's right edge, reads the custom-emoji `ImageText` pool image and its magenta pixels with an alt-only control, shows a toast through its capability and hides it, then reads it as a Hyprland window. A new component is added to the gallery in the same change.
