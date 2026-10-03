# Displays

`vgs.displays`: set the brightness of each display on its own. Apple Pro Display XDR and Apple Studio Display work over USB, other external displays over DDC, and a laptop's built-in display over its backlight.

![System → Displays: one row per display with its brightness, and the screen each display shows on](../../../docs/images/plugins/vgs.displays-pane.webp)

Screenshot made with `scripts/readme-shots.sh` in the nested sandbox, with the default theme at scale 2, over the sandbox's fake Pro Display XDR and two Studio Displays.

## Features

- A brightness item in each bar. It controls the display on its own screen: scroll to change the brightness, click to open the flyout. It hides while no display it can control lights that screen.
- A flyout with one slider per display, the bar's own display first, Link displays, and Display Settings.
- The brightness keys change the display you work on, or every display, as Brightness keys change sets. An on-screen display shows the new level on that screen.
- System → Displays: each display's brightness, the screen a display shows on when VGS cannot tell, Identify, Link displays, and the access each kind of display needs.

## How it works

1. The plugin reads each display through its brightness helper, which talks to Apple displays over USB, to other external displays through `ddcutil` and to a built-in display through `brightnessctl`.
2. VGS matches each display to the screen it lights. Two units of one model look the same, so the pane asks which screen each one shows on. Identify shows each screen's name and flashes the display, so you can tell them apart. VGS keeps your choice and asks again when you plug a display into another port.
3. A change goes to the display at once. While one change runs, VGS keeps only your latest value, so a fast drag does not queue up.
4. When a display needs your permission, the Access section and the display's row show Allow. Allow opens a terminal that shows the one-time setup and asks for your password.

## Settings

| Setting | Default | What it does |
|---|---|---|
| Brightness step | 5% | How much one key press or scroll changes the brightness. |
| Brightness keys change | focused | The display the brightness keys change: the one you work on, or all. |
| Link displays | off | Change every display by the same amount. |

The keys are `XF86MonBrightnessUp` and `XF86MonBrightnessDown`. When your Hyprland configuration also binds them, the Keys row in Settings shows the conflict, and Clear there leaves your own binding.

## Validation

`scripts/test-displays-logic.js` holds the plugin's decisions, and `scripts/smoke/rows/displays.sh` runs it in the nested sandbox over fake displays: [docs/architecture/displays-plugin.md](../../../docs/architecture/displays-plugin.md).
