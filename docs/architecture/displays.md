# Displays

Covers: shell/plugins/vgs.displays/, scripts/test-displays-brightness.py

`vgs.displays` reads and sets display brightness. Today it holds one part: the brightness helper `shell/plugins/vgs.displays/helper/brightness.py`. The plugin has no manifest, service or surface yet. Why a helper and not QML, and the udev rule the Apple displays need: [D083](../decisions/D083-brightness-helper-and-uaccess-rule.md). The plan is [v2-system-plan.md § 3.5](../plans/v2-system-plan.md#35-displays--vgsdisplays-s15s17-s24).

## Helper

The helper runs once per read or write under `python3` and prints one JSON object on stdout. It never talks to Hyprland: the caller passes the outputs.

| Command | Reads | Answers |
|---|---|---|
| `list --outputs FILE` | A JSON array as `hyprctl -j monitors all` prints it, from FILE, or from stdin when FILE is `-`. Each element needs a string `name`; `model` and `serial` are read when they are strings. | `{"backends": {"ddc": STATE, "backlight": STATE}, "displays": [DISPLAY, ...]}` |
| `set ID PERCENT` | A display id and an integer. PERCENT is clamped to 0-100. | `{"id", "percent"}`, with the clamped percent |

A failure prints `{"error": KEY, ...}` on stdout. A usage error exits 2: an unknown command, a PERCENT that is not an integer, or an outputs document that cannot be read, does not parse or has the wrong shape. Every other failure exits 1. Key `state` carries the display's or backend's state when `set` cannot write, `unknown-id` names an id no display has, and `command` carries the argv, status and stderr of a failed `ddcutil` or `brightnessctl`.

A DISPLAY is `{"id", "backend", "label", "state", "percent", "output"}`:

- `backend` is `hidraw`, `ddc` or `backlight`.
- `label` is the Apple product name, the model `ddcutil detect` reports, or the backlight's kernel name. A DDC display with no model takes its id.
- `percent` is an integer 0-100 when `state` is `ready`, else `null`.
- `output` is the output name the display lights, or `null` when it is unassigned.
- An Apple display adds `product`, the USB product id, and `identity`, `{"parent", "serial"}`.

## Ids

| Id | Display |
|---|---|
| `hidraw:<parent>` | An Apple display driven through hidraw. `<parent>` is its identity parent, relative to the sysfs root. |
| `ddc:<connector>` | A DDC display on a DRM connector, `cardN-` removed: `ddc:DP-1`. |
| `ddc:i2c-<bus>` | A DDC display `ddcutil` reports with no connector. |
| `backlight:<name>` | A kernel backlight, by its name under `/sys/class/backlight`. |

## Apple HID

The protocol is v1's (`bin/vshell_helper.py:340-358,9866-10052`, table in [plan § 4](../plans/v2-system-plan.md#4-v1-brightness-protocol-facts-port-reference)).

| USB id | Product | Hyprland model | Raw range |
|---|---|---|---|
| `05ac:9243` | Apple Pro Display XDR | `ProDisplayXDR` | 400-50000 |
| `05ac:1114` | Apple Studio Display | `StudioDisplay` | 400-60000 |

- **Enumeration.** The helper reads `HID_ID` from each `class/hidraw/<name>/device/uevent` and keeps the interfaces whose vendor and product the table holds.
- **Report.** Feature report id 1 is 7 bytes. Bytes 1 to 4 hold the raw brightness, unsigned little-endian. `HIDIOCGFEATURE(7)`, `0xC0074807`, reads it, and `HIDIOCSFEATURE(7)`, `0xC0074806`, writes it.
- **Probe.** Each interface of a display is opened read-write and asked for a zeroed report 1. An answer counts when the call returns at least 5 bytes, byte 0 is 1, and the raw value is from half the product's minimum up to 60000. `EIO`, `EPIPE`, `EINVAL` and `ETIMEDOUT` count as no answer; any other errno fails the run with `hid-read`.
- **Preference.** Among the answering interfaces, the first whose report descriptor declares usage page `0x82`, usage `0x0001` is the control. With none, the first answering interface is.
- **Mapping.** A write sends `min + round(percent × (max − min) / 100)`. A read reports `round((raw − min) × 100 / (max − min))`, clamped to 0-100.
- **Write.** `set` probes the display again and writes to the control interface. A write that does not return 7 bytes fails with `hid-write`.
- **Kernel backlight first.** When a backlight `brightnessctl` lists lies under the display's identity parent in sysfs, the display's entry uses it: id `backlight:<name>`, backend `backlight`, the Apple label, product and identity, and no probe.

## DDC

- **Detect.** `ddcutil detect` lists the displays. Only its `Display N` blocks with an I2C bus count. A block that says `does not support DDC` or `DDC communication failed` is `unsupported`.
- **Cache.** The detect result is kept for 30 s at `$XDG_RUNTIME_DIR/vgs/displays/ddc-detect.json`. Its key is a SHA-256 over every `class/drm/cardN-*` connector's name and EDID bytes and every `class/i2c-dev` name, so a plugged, unplugged or swapped monitor or a renumbered bus misses it. With no `XDG_RUNTIME_DIR` nothing is cached. A cache file that does not parse is a miss and is rewritten. A failed detect sets the backend state `error`, with `detail` the failure object, and lists no DDC display.
- **Read.** `ddcutil --bus N getvcp 10 --brief`. A reply `VCP 10 C <current> <max>` with a non-zero max gives `round(current × 100 / max)`.
- **Write.** `set` reads the max again, then runs `ddcutil --bus N setvcp 10 <round(percent / 100 × max)>`.

## Backlight

- With no entry under `class/backlight`, the backend is `ready` and the helper runs no `brightnessctl`.
- `brightnessctl -l -m -c backlight` lists every backlight. A line that is not five comma-separated fields with a `N%` fourth field fails the run with `brightnessctl-unparsed`, and a failed `brightnessctl` fails the run with `command`.
- `set` runs `brightnessctl -d <name> set <percent>%`.

## Physical identity

An Apple display is its **USB parent** plus its USB serial. The parent is the nearest directory at or above the HID device that holds an `idVendor` file, relative to the sysfs root. All hidraw interfaces under one parent with one serial are one display, so two units of one product stay apart when their serials are absent or equal. With no USB device above the interface, as in the smoke's HID fake, the parent is the HID device's own directory.

## Output mapping

| Backend | Maps to |
|---|---|
| Apple | The one output whose `serial` equals the USB serial. Else, when the display is the only one of its product and exactly one output has the product's model, that output. Else unassigned. |
| DDC | The output named by its DRM connector. Else unassigned. |
| Backlight | The output named by its DRM connector parent. Else, when it is the only backlight left unplaced and exactly one internal panel output (`eDP-`, `LVDS-`, `DSI-`) is not claimed by another backlight, that panel. Else unassigned. |

An unassigned display waits for the user's choice, which S16 stores.

## Access states

| Backend state | Meaning |
|---|---|
| `ready` | The backend can run. |
| `missing` | Its command, `ddcutil` or `brightnessctl`, is not on PATH. For the backlight, only when a backlight exists. |
| `module-not-loaded` | DDC: `/sys/module/i2c_dev` does not exist. |
| `no-access` | DDC: `/dev/i2c-*` nodes exist and none is readable and writable. |
| `error` | DDC: `ddcutil detect` failed. |

| Display state | Meaning |
|---|---|
| `ready` | `percent` holds the brightness. |
| `no-access` | hidraw: no interface opens read-write. DDC: its bus node is not readable and writable. |
| `no-answer` | No in-range reply to the brightness read. |
| `unsupported` | `ddcutil` reports no DDC/CI. |

## Test seams

- `VGS_SYSFS_ROOT`, default `/sys`, and `VGS_DEV_ROOT`, default `/dev`, root every sysfs read and node open. A sysfs link that resolves outside the sysfs root fails the run with `sysfs-escape`.
- `VGS_HID_FAKE` names the socket of the HID fake in [validation-smoke-devices.md](validation-smoke-devices.md). Every feature-report call goes there in place of `ioctl(2)`. It needs both roots set, else the run fails with `seam-incomplete` before it opens a node.

## Validation

`scripts/test-displays-brightness.py`, the `cli` row of [validation.md](validation.md), runs the helper against the HID fake, `ddcutil` and `brightnessctl` stand-ins and temporary sysfs, `/dev`, HOME and runtime trees. An audit hook stops any open outside those trees and any command but the stand-ins. Its controls plant one defect per rule in a copy of the helper and require the named test to fail: big-endian bytes, the wrong write ioctl, grouping by product in place of USB parent, a probe of the first interface alone, a probe ceiling one too high, an ignored descriptor, a cache that ignores a hotplug or its age, the fake without both roots, and an ignored kernel backlight.

## Not yet built

- S16: the plugin's manifest, the service that coalesces writes, the per-screen widget, the flyout, the brightness keys, the OSD, the `apple-displays` and `i2c-dev` steps, and the assignments file `${XDG_STATE_HOME}/vgs/plugins/vgs.displays/assignments.json`.
- S17: the arrangement and output pane, with the monitor preview.
- S21: the owner's acceptance on both Apple displays and the release-to-write time.
