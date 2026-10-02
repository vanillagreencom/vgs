# Runtime: Hyprland outputs

Covers: shell/Core/MonitorLogic.js, shell/Core/MonitorState.qml, scripts/smoke/rows/monitor-outputs.sh

The Hyprland v0.56.2 facts the `monitors` capability's outputs reading rests on ([hyprland-monitors.md](hyprland-monitors.md)), each with the source or the reading that establishes it. The source is the `v0.56.2` tag of hyprwm/Hyprland. A reading that names no date was taken in the nested sandbox of `scripts/qml-smoke.sh` on host cachy on 2026-10-01. The other Hyprland facts are in [runtime-hyprland.md](runtime-hyprland.md). The nested output's facts, the `hl.monitor` rule the smoke harness holds among them, are in [runtime-hyprland-nested.md](runtime-hyprland-nested.md).

## Outputs

- `monitors -j all` lists every output, disabled ones included, as `getMonitorData` in `src/debug/HyprCtl.cpp` prints it: `id`, `name`, `description` (the short description), `make`, `model`, `serial`, `width` and `height` (the mode in device pixels), `refreshRate` to five places, `x`, `y`, `scale`, `transform`, `vrr`, `disabled`, `currentFormat`, `mirrorOf` (the mirrored output's `id` as text, or `none`) and `availableModes`, each `WxH@R.RRHz`.
- `vrr` is whether adaptive sync runs on the output now, a boolean, not a rule's 0 to 3: it reads false on an output without adaptive sync whatever the rule says.
- The nested Wayland output has no make, model or serial and lists no mode: Aquamarine's Wayland backend (`src/backend/Wayland.cpp`, aquamarine v0.15.1) adds none. It read `{"name": "WAYLAND-1", "serial": "", "availableModes": [], "refreshRate": 60.00000}`.
- A `desc:` selector matches an output whose description or short description starts with the rest of the selector, trimmed. The short description is the make, model and serial joined by spaces, trimmed, with every comma removed (`CMonitor::onConnect`, `CMonitor::matchesStaticSelector` in `src/output/Monitor.cpp`). `MonitorLogic.identifier` builds the same text.

## Events

- The event socket posts `monitoradded>>NAME` and `monitoraddedv2>>ID,NAME,DESCRIPTION` when an output connects, `monitorremoved` and `monitorremovedv2` when it goes (`src/output/Monitor.cpp`), and `configreloaded` after each reload.

## Rules

- A configuration reload runs `CConfigManager::reload`, which clears the monitor rules, runs `hyprland.lua` again and applies the rules (`ensureMonitorStatus`) before it answers (`src/config/lua/ConfigManager.cpp`). A read that follows `configreloaded` therefore sees the outputs as the reloaded rules set them.
- The reload drops a monitor rule `hyprctl eval` added and applies a rule a loaded file names for an output, but it does not give an output the default rule's mode. Read in a nested Hyprland 0.56.2 on host cachy on 2026-09-29, `WAYLAND-1` on a 1755 × 933 window, twice each: held at 3510 × 1866 and scale 2 through `hyprctl eval`, then dropped to scale 1 the same way, the output stays at 3510 × 1866 and scale 1 after the reload; with a file `dofile` loads naming 3510 × 1866 at scale 2, the same drop and reload give it 3510 × 1866 at scale 2 again; with no such file, an output at 3510 × 1866 and scale 2 from `hyprctl eval` keeps that mode and scale through `reload config-only` and a full `hyprctl reload`, and the default `output = ""` rule at scale 1 is not applied to it. The smoke harness therefore keeps a held rule in a file its `hyprland.lua` runs, and `scripts/smoke/rows/hidpi.sh` reads a reload bring it back and, without the file, not.
- An `hl.monitor` in `hyprctl eval` schedules a monitor refresh and returns (`hlMonitor` in `src/config/lua/bindings/LuaBindingsConfigRules.cpp`), so `hyprctl eval` answers `ok` before the output changes.
