# Theme toolkit targets

Covers: themes/targets/color-scheme/**, themes/targets/gtk3/**, themes/targets/gtk4/**, themes/targets/icons/**, themes/targets/kcolorscheme/**, themes/targets/qt5ct/**, themes/targets/qt6ct/**, scripts/test-vgsh-toolkits.sh

The shipped targets that colour GTK, Qt and KDE applications and select the icon theme and the light or dark mode. The target format, the encoders and the wiring forms are [theme-targets.md](theme-targets.md); when a hook runs is [theme-reload.md](theme-reload.md).

| Target | Encoder | Detect | Wiring | Reload |
|---|---|---|---|---|
| `color-scheme` | `hex6` | `gsettings` | None. | On every apply, `gsettings set org.gnome.desktop.interface color-scheme` to the value in `color-scheme.mode`. |
| `gtk3` | `rgba` | `gtk-launch` | `@import url("file://@{state}/gtk3.css");` in `gtk-3.0/gtk.css`, created when absent. | None. |
| `gtk4` | `rgba` | `gtk4-launch` | `@import url("file://@{state}/gtk4.css");` in `gtk-4.0/gtk.css`, created when absent. | None. |
| `icons` | `hex6` | `gsettings` | None. | On every apply, `gsettings set org.gnome.desktop.interface icon-theme` to the name in `icons.theme`. |
| `kcolorscheme` | `hex6` | `kreadconfig6` | The link `Vgs.colors` in `~/.local/share/color-schemes/`. | None. |
| `qt5ct` | `hex6` | `qt5ct` | The link `vgs.conf` in `qt5ct/colors/`. | `touch -c` of `qt5ct/qt5ct.conf`. |
| `qt6ct` | `hex6` | `qt6ct` | The link `vgs.conf` in `qt6ct/colors/`. | `touch -c` of `qt6ct/qt6ct.conf`. |

The toolkit targets draw the palette's surfaces, text, accent and status colours. Each GTK, Qt and KDE application reads them when it starts, except where a hook says otherwise.

- **GTK.** GTK 3 and 4 read `gtk.css` from the configuration home once per process, so the targets have no reload. The import goes first, as CSS requires of `@import`, and the file's own rules after it override the theme. `gtk3.css` sets the adw-gtk3 and Adwaita named colours; `gtk4.css` sets libadwaita's CSS variables, which libadwaita 1.6 and later read, and the named colours earlier releases read.
- **Qt.** qt5ct and qt6ct find colour schemes in their `colors/` directories. The user selects `vgs` once in qt5ct or qt6ct, with a custom palette on, which writes that path into `qtXct.conf`. Their platform theme watches its configuration directory and reads the settings again 3 s after an entry there changes; the swap changes nothing it watches, so the hook changes only the time of `qtXct.conf`.
- **KDE.** KDE applications find colour schemes by name in `color-schemes/` of the data directories. The user selects `Vgs` once, in System Settings or with `plasma-apply-colorscheme Vgs`, which copies the scheme's colours into `kdeglobals`. The target has no reload: `plasma-apply-colorscheme` does nothing for the scheme already selected, so a changed `Vgs` reaches `kdeglobals` when the user selects it again.
- **Mode.** `color-scheme.mode` is `prefer-dark` or `prefer-light`, from the package's `scheme.mode`. libadwaita, GTK's dark variant and the XDG portal's `prefers-color-scheme`, which browsers and Electron applications read, all start from `color-scheme`, as does Chromium under the `BrowserColorScheme` `device` policy ([theme-browsers.md § Chromium](theme-browsers.md#chromium)). The hook sets it on every apply, so a mode set by hand since is set back, and sets nothing when the value already holds. Omarchy's `omarchy-theme-set-gnome` sets it the same way.
- **Icons.** `icons.theme` is empty unless the package ships `targets/icons.theme`, one line naming an icon theme, as Omarchy's packages ship `icons.theme`. The hook sets the GTK icon theme to that name on every apply, so a theme set by hand since is set back, and sets nothing when the name is empty, already set, or no theme of that name is installed in `~/.icons`, `$XDG_DATA_HOME/icons` or `icons/` of `$XDG_DATA_DIRS`. A name holding `/` or starting with `.` fails the hook and leaves the target pending.

## Invariants

1. Each shipped toolkit target renders its colours with its encoder, `rgba` for GTK and `#rrggbb` elsewhere, and 21 roles in each qt scheme; keeps its import first in `gtk.css`, created when absent, and its link in qtXct's `colors/` and the home's `color-schemes/`; takes a package's curated file byte for byte; loses only its own line or link when disabled; touches an existing `qtXct.conf` and creates none; `color-scheme` sets `prefer-` and the package's mode on every apply, never a value already set; and `icons` sets an installed icon theme the package names on every apply, never one already set, not installed or absent, and fails on a name holding a path. Enforced by `scripts/test-vgsh-toolkits.sh` under a PATH of stub detect commands and a stub gsettings, with target copies that change an encoder, stop creating `gtk.css`, create `qt5ct.conf`, link the KDE scheme under the configuration home, run the icons and color-scheme hooks on changed bytes only, and drop the icons installed check and the color-scheme equal-value check as its controls.
