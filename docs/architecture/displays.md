# Displays

Covers: shell/plugins/vgs.displays/, scripts/test-displays-brightness.py

`vgs.displays` reads and sets display brightness. Today it holds one part: the brightness helper `shell/plugins/vgs.displays/helper/brightness.py`. The plugin has no manifest, service or surface yet. Why a helper and not QML, and the udev rule the Apple displays need: [D083](../decisions/D083-brightness-helper-and-uaccess-rule.md). The plan is [v2-system-plan.md § 3.5](../plans/v2-system-plan.md#35-displays--vgsdisplays-s15s17-s24).

## Helper

The helper runs once per read or write under `python3` and prints one JSON object on stdout. It never talks to Hyprland: the caller passes the outputs.

| Command | Reads | Answers |
|---|---|---|
| `list --outputs FILE` | A JSON array as `hyprctl -j monitors all` prints it, from FILE, or from stdin when FILE is `-`. Each element needs a string `name`; `make`, `model` and `serial` are read when they are strings. | `{"backends": {"ddc": STATE, "backlight": STATE}, "displays": [DISPLAY, ...]}` |
| `set ID PERCENT` | A display id and an integer. PERCENT is clamped to 0-100. | `{"id", "percent"}`, with the clamped percent |

A failure prints `{"error": KEY, ...}` on stdout. A usage error exits 2: an unknown command, a PERCENT that is not an integer, or an outputs document that cannot be read, does not parse or has the wrong shape. Every other failure exits 1. Key `state` carries the state `list` reports for the display or its backend when `set` cannot write, `unknown-id` names an id no display has, and `command` carries the argv, status and stderr of a failed `ddcutil` or `brightnessctl`.

A DISPLAY is `{"id", "backend", "label", "state", "percent", "outputs"}`:

- `backend` is `hidraw`, `ddc` or `backlight`.
- `label` is the Apple product name, the model `ddcutil detect` reports, or the backlight's kernel name. A DDC display with no model takes its id.
- `percent` is an integer 0-100 when `state` is `ready`, else `null`.
- `outputs` lists the names of the outputs the display lights, empty when it is unassigned. A tiled monitor lights more than one.
- A display in state `error` or `unsupported` adds `detail`, the reason.
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
- **Probe.** Each interface of a display is opened read-write and asked for a zeroed report 1. An answer counts when the call returns at least 5 bytes, byte 0 is 1, and the raw value is from half the product's minimum up to 60000. `EIO`, `EPIPE`, `EINVAL` and `ETIMEDOUT` count as no answer. Any other errno, on the open or the read, is that interface's error alone: the other interfaces and displays still answer.
- **State.** A display with an answering interface is `ready`. Else it is `no-access` when an interface refused the read-write open, else `error` when one failed with another errno, with `detail` naming each interface and errno, else `no-answer`.
- **Preference.** Among the answering interfaces, the first whose report descriptor declares usage page `0x82` (VESA Virtual Controls), usage `0x10` (Brightness) is the control. With none, the first answering interface is. The brightness interface of both displays declares it inside a Monitor page `0x80` collection: the Studio Display's descriptor starts `05 80 09 01 a1 01 85 01 06 82 00 09 10 16 90 01 27 60 ea 00 00`, the XDR's the same with `27 50 c3 00 00`, its 50000 maximum. `0x820001` is `asdcontrol`'s `hiddev` usage code and matches no hidraw descriptor.
- **Mapping.** A write sends `min + round(percent × (max − min) / 100)`. A read reports `round((raw − min) × 100 / (max − min))`, clamped to 0-100.
- **Write.** `set` probes the display again and writes to the control interface. A display that is not `ready` fails `set` with its state. A write that does not return 7 bytes fails with `hid-write`.
- **Kernel backlight first.** When a backlight `brightnessctl` lists lies under the display's identity parent in sysfs, the display's entry uses it: id `backlight:<name>`, backend `backlight`, the Apple label, product and identity, and no probe.

## DDC

- **Detect.** `ddcutil detect` lists the displays and exits 0 whatever it finds; with none it prints `No displays found.`, and the backend is `ready` with no DDC display. Its blocks with an I2C bus count, by header, as ddcutil 3.0.2's `ddc_report_display_by_dref` prints them: `Display N` is a DDC display, and `Invalid display` is `unsupported`, with `detail` its reason lines, such as `DDC communication failed` or `This monitor does not support DDC/CI.`. Every other header (phantom, busy, removed, DDC disabled) is skipped.
- **Skipped invalid displays.** A laptop panel's block, whose reason names a laptop display, is the backlight's. A block whose EDID manufacturer is `APP` and whose model is the model of an Apple display the same run lists is the HID backend's, so the Studio Display and Pro Display XDR do not show twice. An Apple display with no HID interface still shows as DDC `unsupported`.
- **Cache.** The detect result is kept for 30 s at `$XDG_RUNTIME_DIR/vgs/displays/ddc-detect.json`. Its key is a SHA-256 over every `class/drm/cardN-*` connector's name and EDID bytes and every `class/i2c-dev` name, so a plugged, unplugged or swapped monitor or a renumbered bus misses it. The cache is best effort: with no `XDG_RUNTIME_DIR`, or a cache file that cannot be read, parsed or written, the run detects and lists as without one. A write goes through a unique temporary file in the cache directory and a rename, so concurrent runs never share a file. A failed detect sets the backend state `error`, with `detail` the failure object, and lists no DDC display.
- **State.** One function judges a DDC display for `list` and `set`: `unsupported` from detect, `no-access` when its `/dev/i2c-N` is not readable and writable, `no-answer` when `getvcp` fails or does not parse, else `ready`.
- **Read.** `ddcutil --bus N getvcp 10 --brief`. A reply `VCP 10 C <current> <max>` with a non-zero max gives `round(current × 100 / max)`.
- **Write.** `set` judges the display's state; one that is not `ready` fails with that state. It then runs `ddcutil --bus N setvcp 10 <round(percent / 100 × max)>`, max from the state's reading.

## Backlight

- With no entry under `class/backlight`, the backend is `ready` and the helper runs no `brightnessctl`.
- `brightnessctl -l -m -c backlight` lists every backlight. A failed `brightnessctl`, or a line that is not five comma-separated fields with a `N%` fourth field, sets the backlight backend state `error`, with `detail` the `command` or `brightnessctl-unparsed` object, and lists no backlight. The other backends still list.
- `set` runs `brightnessctl -d <name> set <percent>%`.

## Physical identity

An Apple display is its **USB parent** plus its USB serial. The parent is the nearest directory at or above the HID device that holds an `idVendor` file, relative to the sysfs root. All hidraw interfaces under one parent with one serial are one display, so two units of one product stay apart when their serials are absent or equal. With no USB device above the interface, as in the smoke's HID fake, the parent is the HID device's own directory.

## Output mapping

| Backend | Maps to |
|---|---|
| Apple | The one monitor whose `serial` equals the USB serial. Else, when the display is the only one of its product and exactly one monitor has the product's model, that monitor's outputs. Else unassigned. |
| DDC | The output named by its DRM connector. Else unassigned. |
| Backlight | The output named by its DRM connector parent. Else, when it is the only backlight left unplaced and exactly one internal panel output (`eDP-`, `LVDS-`, `DSI-`) is not claimed by another backlight, that panel. Else unassigned. |

Outputs that share `make`, `model` and a non-empty `serial` are one monitor. The owner's Pro Display XDR is tiled over DP-1 and DP-5, which both carry serial `0x030B1303`, so it maps to both.

The serial rule does not fire on the Studio Display or the Pro Display XDR. Hyprland reports the EDID binary serial in hex, `0x030B1303` for the XDR and `0xE6BB516A` for the Studio Display, while the USB serial is `C020106008NJLC0AX` and `00008030-0003681A3685802E`. Their EDIDs, read from `/sys/class/drm/*/edid` on 2026-10-01, hold no serial string descriptor (tag `0xFF`) and no copy of the USB serial, so no EDID field links the two. v1 compared the USB serial with that string descriptor (`bin/vshell_helper.py:10391-10419,10479-10500`) and matched neither display either. The model rule maps them.

An unassigned display waits for the user's choice, which S16 stores.

## Access states

| Backend state | Meaning |
|---|---|
| `ready` | The backend can run. |
| `missing` | Its command, `ddcutil` or `brightnessctl`, is not on PATH. For the backlight, only when a backlight exists. |
| `module-not-loaded` | DDC: `/sys/module/i2c_dev` does not exist. |
| `no-access` | DDC: `/dev/i2c-*` nodes exist and none is readable and writable. |
| `error` | DDC: `ddcutil detect` failed. Backlight: `brightnessctl` failed or printed a line that does not parse. Adds `detail`. |

| Display state | Meaning |
|---|---|
| `ready` | `percent` holds the brightness. |
| `no-access` | hidraw: an interface refused a read-write open and none answered. DDC: its bus node is not readable and writable. |
| `no-answer` | No in-range reply to the brightness read. |
| `error` | hidraw: no interface answered and one failed with an errno no probe miss gives. Adds `detail`. |
| `unsupported` | DDC: `ddcutil detect` reports an invalid display. Adds `detail`. |

## Test seams

- `VGS_SYSFS_ROOT`, default `/sys`, and `VGS_DEV_ROOT`, default `/dev`, root every sysfs read and node open. A sysfs link that resolves outside the sysfs root fails the run with `sysfs-escape`.
- `VGS_HID_FAKE` names the socket of the HID fake in [validation-smoke-devices.md](validation-smoke-devices.md). Every feature-report call goes there in place of `ioctl(2)`. It needs both roots set, else the run fails with `seam-incomplete` before it opens a node.

## Validation

`scripts/test-displays-brightness.py`, the `cli` row of [validation.md](validation.md), selects on `shell/plugins/vgs.displays/helper/*`, `scripts/smoke/fixtures/devices/hid-fake.py`, `scripts/smoke/fixtures/devices/hid-world.json` and `scripts/smoke/fixtures/devices/stand-in.py`. It runs the helper against the HID fake, `ddcutil` and `brightnessctl` stand-ins and temporary sysfs, `/dev`, HOME and runtime trees. An audit hook stops any open outside those trees, any subprocess, exec, posix_spawn or spawn of a program but the stand-ins, and any `os.system`, fork or forkpty. In-process cases load the helper as a module and replace `fcntl.ioctl`, the HID reports object or `os.replace` with recorders. Its controls plant one defect per rule in a copy of the helper and require the named test to fail:

- HID: big-endian bytes, the wrong write ioctl, grouping by product in place of USB parent, a probe of the first interface alone, a probe ceiling one too high, a short report or another report id accepted, every probe errno read as a miss, a probe errno that fails the run, an ignored descriptor, `asdcontrol`'s usage code, an immutable `ioctl` buffer, a dropped `ioctl` answer, a short write accepted.
- Mapping: one monitor per output, so a tiled XDR goes unassigned.
- DDC: a shared cache temporary name, a cache that ignores a hotplug or its age, a cache write failure that fails the run, invalid displays dropped, a laptop panel listed, an Apple display listed twice, and `set` judging state its own way.
- Backlight and seams: a `brightnessctl` failure that fails the run, an ignored kernel backlight, and the fake without both roots.

## Not yet built

- S16: the plugin's manifest, the service that coalesces writes, the per-screen widget, the flyout, the brightness keys, the OSD, the `apple-displays` and `i2c-dev` steps, and the assignments file `${XDG_STATE_HOME}/vgs/plugins/vgs.displays/assignments.json`.
- S17: the arrangement and output pane, with the monitor preview.
- S21: the owner's acceptance on both Apple displays and the release-to-write time.
