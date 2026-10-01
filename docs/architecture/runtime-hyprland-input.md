# Runtime: Hyprland input options and devices

Covers: shell/Core/HyprlandState.qml, shell/Core/HyprlandState.js, scripts/test-hyprland-state.js, scripts/smoke/rows/hyprland-options.sh

The Hyprland v0.56.2 facts the input options of the Hyprland layer and the `hyprland` capability rest on ([hyprland-options.md](hyprland-options.md)), each with the source or the reading that establishes it. The source is the `v0.56.2` tag of hyprwm/Hyprland. Each reading was taken in a nested Hyprland 0.56.2 on host cachy on 2026-09-30, either a throwaway instance with its own runtime directory or `scripts/smoke/rows/hyprland-options.sh`. The other Hyprland facts are in [runtime-hyprland.md](runtime-hyprland.md).

## Options

- A Lua `hl.config` table key is the option's name with every `-` turned into `_` (`CConfigManager::luaConfigValueName` in `src/config/lua/ConfigManager.cpp`). `hl.config({ input = { touchpad = { ["tap-to-click"] = false } } })` is refused: `configerrors -j` lists `unknown config key 'input.touchpad.tap-to-click'` with its file and line, and the option keeps its value. `tap_to_click = false` sets it. So the layer writes no quoted, hyphenated key.
- `hyprctl getoption` takes the option under any of its spellings, `input:touchpad:tap-to-click`, `input:touchpad:tap_to_click` or `input.touchpad.tap_to_click`, and echoes the spelling it was given as `option`.
- `getoption -j` prints one object: `option`, the value under a field named for its type, `int`, `float`, `bool` or `str`, and `set`, true once a configuration line set the option since the last reload (`dispatchGetOption` in `src/debug/HyprCtl.cpp`). A float prints to six places, `0.350000`. An unknown option prints `no such option`, which is no JSON. A `str` from the Lua configuration is printed without JSON escaping.
- An option no line sets keeps Hyprland's default with `set: false`: `input:natural_scroll` read `{"bool": false, "set": false}` while the layer set other input options.
- The types and ranges the layer's option table holds are those of `src/config/values/ConfigValues.cpp`: `repeat_rate` is an int from 0 to 200, `repeat_delay` an int from 0 to 2000, `sensitivity` a float from -1 to 1, both `scroll_factor`s floats from 0 to 2, `accel_profile` a string Hyprland takes as `adaptive`, `flat` or `custom`, and the layouts, variants and options strings.
- A later line wins: with the layer's `repeat_rate = 40` and a user line `repeat_rate = 30` after the loading line, `getoption` read 30.
- `hyprctl --batch "j/getoption A;j/getoption B"` answers each request in order, joined by `\n\n\n`, as other batches do ([runtime-hyprland.md](runtime-hyprland.md)).
- The reload resets every option and clears every `hl.device` setting before it runs `hyprland.lua` again (`CConfigManager::reload`, `m_deviceConfigs.clear()`), so an option or a device setting the layer stops writing returns to Hyprland's default.

## Devices

- Hyprland keeps a touchpad's `enabled` per device, set by `hl.device({ name = "<device>", enabled = false })` (`hlDevice` in `src/config/lua/bindings/LuaBindingsConfigRules.cpp`). A name no device carries is no error: `configerrors` stayed empty. Hyprland's Lua lists no input device, so the name comes from `hyprctl devices`.
- `devices -j` prints `mice`, `keyboards`, `tablets`, `touch` and `switches` (`devicesRequest` in `src/debug/HyprCtl.cpp`). A mouse has `address`, `name`, `defaultSpeed` and `scrollFactor` and no class, so a touchpad is told by its name, as Omarchy's `omarchy-hw-touchpad` does. A keyboard has `name`, `rules`, `model`, `layout`, `variant`, `options`, `active_layout_index`, `active_keymap`, `capsLock`, `numLock` and `main`. A keyboard with no active layout prints `"active_layout_index": none`, which is no JSON. The nested instance lists `wl_pointer` and `wl_keyboard`, and `active_keymap` read `English (US)`.
- A device name is the device's own name in lower case with each space, comma and line break turned into `-` (`deviceNameToInternalString` in `src/helpers/MiscFunctions.cpp`); every other byte stays, quotes included.
- The event socket posts `activelayout>><keyboard>,<keymap>` when a keyboard switches layout and when a keyboard comes or goes: `wtype` posted `activelayout>>hl-virtual-keyboard-wtype,English (US)` when it started and `activelayout>>hl-virtual-keyboard-wtype,error` when it ended. It posts `configreloaded` after every reload. Nothing is posted when a pointer comes or goes: the event socket's events in `src/` name no pointer, and Hyprland's Lua events, `LuaEventHandler.cpp`, name no input device.

## Binds

- `binds -j` prints each bind's `modmask`, `submap`, `key`, `keycode`, `description` and `dispatcher` among other fields (`bindsRequest`). The default submap prints as `submap: ""`. `key` is the key name as the bind wrote it, `F7` or `space`, and `""` for a `code:` bind. `modmask` holds the bits of `src/devices/IKeyboard.hpp`: SHIFT 1, Caps Lock 2, CTRL 4, ALT 8, MOD2 16, MOD3 32, SUPER 64, MOD5 128. A user bind on the layer's own key is a second entry with its own description, `""` when it gives none.

## Layout switch

- `switchxkblayout` is a top-level `hyprctl` command, not a dispatcher (`switchXKBLayoutRequest`). `hyprctl switchxkblayout all next` answered `ok` and exit 0, and `active_keymap` read `German` with `kb_layout = "us,de"`. `all` moves every keyboard from the layout it is on. An index past the list answers `layout idx out of range of 2`, and a word other than `next` or `prev` answers `invalid arg 2`, each with exit 0, since Hyprland reads an index with `std::stoi`.
- `hyprctl dispatch switchxkblayout all next` in a Lua session runs `hl.dispatch(switchxkblayout all next)` as Lua and exits 7 with a syntax error. A dispatch cannot carry the switch.
