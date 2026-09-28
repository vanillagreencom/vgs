# Theme backgrounds

Covers: bin/lib/theme-backgrounds.js, scripts/test-vgsh-backgrounds.sh, shell/plugins/vgs.background/**

How a theme package's `backgrounds/` images reach the screen: which image `vgsh theme apply` makes current, how `vgsh theme background next` moves on, and how the `vgs.background` plugin draws it. The package format is [themes.md § Package shape](themes.md#package-shape); the apply steps are [theme-apply.md § Apply](theme-apply.md#apply).

## State

`bin/lib/theme-backgrounds.js` owns every read and write below; `bin/vgsh-theme-judge` calls it. The state directory is `${XDG_STATE_HOME:-~/.local/state}/vgs/`.

- **Images.** A package's images are the entries of its `backgrounds/` whose name ends in `.png`, `.jpg` or `.jpeg` in any case and does not start with `.`, each a file or a symlink to one, in name order. Every other entry is skipped. An absent `backgrounds/` holds none. One that cannot be read refuses the command with `reason=unreadable`.
- **`backgrounds.json`.** `{ "schemaVersion": 1, "current": <path|null>, "themes": { "<theme>": "<file>" } }`. `current` is the absolute path of the image shown now, and `themes` the image `next` last chose for each package. An absent file is no current image and nothing remembered, and that state removes the file. A file that cannot be read, parsed or judged refuses the command with `reason=unreadable`, `unparseable` or `malformed` before anything moves. The file is replaced by rename when its content changes.
- **`background`.** A symlink to the `current` image, for a lock screen or any other application that draws the theme's background. It is replaced by rename, and removed while no image is current.

## Commands

- **Apply.** Before anything moves, apply reads the state and the package's images and chooses the image `themes` remembers for the package while the package still holds it, else its first image, else none. After the swap, once `theme.name` holds the package name, it writes the `background` symlink and then `backgrounds.json`. A write that fails refuses the apply with `reason=unwritable`. The apply result does not report the background.
- **`vgsh theme background next`.** Under the theme lock, `next` reads the package `theme.name` names and shows the image after the one apply would choose, wrapping to the first, remembers it in `themes` and writes the symlink and the file as apply does. It prints `ok background=<file> theme=<name> path=<image>`. Refusals print `vgsh: refused: background=next reason=<key>`: `not-applied` without a `theme.name`, `malformed` for one no package could have, `unknown` for a package no longer present, the package's own refusal reason, `no-backgrounds`, `busy` with exit 75, `lock-failed`, and the state reasons above. It takes no `--json`.

## Plugin

`shell/plugins/vgs.background` declares the kind `background` and no capability. It is a first-party plugin, so it is enabled unless `disabledPlugins` lists it: [plugins.md § Kinds](plugins.md#kinds).

- **Source.** A `FileView` watches `backgrounds.json` under `Paths.stateDir` and reloads it on every change. The plugin draws its `current` image. A watch on the `background` symlink would follow the symlink's target and miss a retargeted link: [runtime.md § QML](runtime.md#qml).
- **Drawing.** One `Image` fills the host surface with `PreserveAspectCrop`, decoded at the size that covers the screen rather than at the file's size. With no current image, an image that cannot be read or a state file the runner did not write, the host's `Theme.color.background` shows. The last two are logged as `background: <path> unreadable` and `background: <path> malformed`.
- **Sandbox.** The smoke harness seeds the plugin in `disabledPlugins`, so the host rows see only their fixture's background surface, and its block in `scripts/smoke/rows/themes.sh` enables it.

## Invariants

1. Apply shows a package's remembered image while the package holds it, else its first image in name order, and removes the link for a package with none; only image names count; `next` moves to the following image and wraps, remembers it, and is refused busy under the theme lock; a state file or `backgrounds/` that cannot be used refuses the apply before the theme file changes. Enforced by `scripts/test-vgsh-backgrounds.sh`, with copies that forget the remembered image, take any file, keep the link, stop at the last image, accept a malformed state file and ignore the lock as its controls.
2. The plugin draws the applied package's image on every screen, decoded to cover the screen and smaller than a larger file, follows `next` and a later apply, and draws no image for a package without backgrounds or a malformed state file. Enforced by `scripts/smoke/rows/themes.sh`, which reads the drawn `Image` through the probe's `images`, with a copy that never reloads the state file as its control.
