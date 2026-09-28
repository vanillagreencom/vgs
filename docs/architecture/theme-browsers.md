# Theme browsers

Covers: themes/targets/zen/**, themes/targets/pywalfox/**, scripts/test-vgsh-browsers.sh

The browser targets, beside the others of [theme-targets.md § Targets](theme-targets.md#targets). The target format and the encoders are [theme-targets.md](theme-targets.md); when a hook runs is [theme-apply.md § Reload](theme-apply.md#reload).

| Target | Encoder | Detect | Wiring | Reload |
|---|---|---|---|---|
| `pywalfox` | `hex6` | `pywalfox` | Link `colors.json` in `${XDG_CACHE_HOME:-~/.cache}/wal`, naming `pywalfox.json`, not owned: [theme-wiring.md § Entry wiring](theme-wiring.md#entry-wiring). | `pywalfox update`, 5000 ms. |
| `zen` | `hex6` | `zen-browser` | `@import url("file://@{state}/zen.css");` first in `chrome/userChrome.css` of every profile of `~/.zen/profiles.ini`, else `~/.config/zen/profiles.ini`, created when absent: [theme-wiring.md § Profile wiring](theme-wiring.md#profile-wiring). | None: Zen reads the file at startup. |

Chromium, Google Chrome and Brave follow the theme in GTK mode only, and no target writes their colour: [D027](../decisions/D027-chromium-follows-gtk-mode.md). The user picks GTK once under the browser's Appearance settings. In GTK mode the browser reads its colours from GTK when it starts, and GTK reads the `gtk3` and `gtk4` targets' import: [theme-toolkits.md](theme-toolkits.md). In Classic mode the browser keeps the colour the user picks inside it, since its one outside colour input is the managed policy `BrowserThemeColor`, a root-owned file under `/etc`. Theme apply runs unprivileged and writes nothing under `/etc`.

## Zen

Zen draws its toolbars, panels, URL bar and container colours from the theme: the containers from the terminal slots, the rest from the `color` tokens. The user sets `toolkit.legacyUserProfileCustomizations.stylesheets` to `true` once in `about:config`, since Zen reads `userChrome.css` only with it, and only at startup: a theme applies on the next restart. Apply never edits `prefs.js` or `user.js`.

## Pywalfox

pywalfox's native host reads pywal's `colors.json` from `${XDG_CACHE_HOME:-~/.cache}/wal/`: its `colors`, at least sixteen in key order, and a `wallpaper` key it requires, empty here. `pywalfox update` has the connected browser fetch the file again and exits 0 when no browser is connected. A `colors.json` pywal itself wrote is the user's, and the target is skipped with `entry-occupied`. Source: pywalfox-native `config.py`, `fetcher.py` and `__main__.py`.

## Invariants

1. The `zen` target writes its colours as `#rrggbb`, its container colours from the terminal slots, and keeps its import first in each profile of `~/.zen`, else `~/.config/zen`, creating the file and keeping its own text; it never runs `zen-browser`. The `pywalfox` target writes pywal's `colors.json` shape with a wallpaper and sixteen slots, links it as `colors.json` under `XDG_CACHE_HOME` alone, and runs `pywalfox update` on changed bytes, a failure leaving it `reload-pending` until `vgsh theme reload`. Enforced by `scripts/test-vgsh-browsers.sh` under a PATH holding stub `zen-browser` and `pywalfox`, with `target.json` copies that write `hex8`, try `~/.config/zen` first, link under HOME and drop the hook as its controls.
