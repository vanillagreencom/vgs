# D083: Brightness uses a one-shot plugin helper over hidraw, DDC and backlight, with a uaccess-only rule

[← Decision Index](INDEX.md)

**Date**: 2026-10-01

**Status**: Active

**Research**: [VGS-705](https://linear.app/vanillagreen/issue/VGS-705), [System plan § 3.5](../plans/v2-system-plan.md#35-displays--vgsdisplays-s15s17-s24), [§ 4](../plans/v2-system-plan.md#4-v1-brightness-protocol-facts-port-reference), [plan review](../plans/v2-system-plan-review.md) E1, E2, M12, M13

**Applies to**: `vgs.displays`

**Context**: `vgs.displays` reads and sets the brightness of three kinds of display. An Apple Pro Display XDR or Studio Display takes a USB HID feature report on its hidraw node. An external monitor takes DDC/CI over I2C through `ddcutil`. A laptop panel takes a kernel backlight through `brightnessctl`. QML cannot `ioctl` a hidraw node, and `ddcutil` and `brightnessctl` are external programs. [D010](D010-facade-scope-not-sandbox.md) keeps every plugin in the shell process, so a process outside it needs a stated reason. A hidraw node is root-owned unless a udev rule grants it.

**Decision**: A plugin-owned helper, `shell/plugins/vgs.displays/helper/brightness.py`, does every read and write. The Apple displays get a udev rule that grants the hidraw nodes to the active local seat alone.

- **One run per call.** The helper runs under `python3`, which `config/requirements.json` already names as a core requirement. Each `list` or `set` is one run with one JSON answer on stdout. [displays.md](../architecture/displays.md) states its contract.
- **Coalesced writes.** The `vgs.displays` service (S16) keeps one helper run in flight per device and sends the latest value when it ends, as v1's bridge did (v1 `backend/internal/services/brightnessbridge/brightnessbridge.go:20-33,62-87`).
- **No resident mode.** A resident helper comes only if the p95 from key or slider release to the device write exceeds 150 ms.
- **hidraw for Apple displays.** The helper sends the feature reports itself. `asdcontrol` and `hiddev` are not ported.
- **The Apple rule.** Its path is `config/system/udev/60-vgs-apple-displays.rules`, and this record fixes its content to these two lines:

```text
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="05ac", ATTRS{idProduct}=="1114", TAG+="uaccess"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="05ac", ATTRS{idProduct}=="9243", TAG+="uaccess"
```

- The rule has no `hiddev` line, no `GROUP` and no `MODE`. Its `60-` prefix sorts before `73-seat-late.rules`, where systemd applies `uaccess`.
- VGS-705 ships no rule file. The `apple-displays` system step (S07, S16) ships and installs it.
- **DDC access is the package's.** On Arch the `ddcutil` package ships `60-ddcutil-i2c.rules`, `uaccess` on display-class I2C nodes, and `modules-load.d/ddcutil.conf`, so the package is the grant (review M12). S07 checks the other distributions' packages.

## Measurement

The helper's own start-up plus one write, measured on 2026-10-01 at commit `6fff1623f`:

- **Tool**: `hyperfine --warmup 3 --runs 50 "env -i PATH=$T/bin VGS_HID_FAKE=$T/sock VGS_DEV_ROOT=$T/dev VGS_SYSFS_ROOT=$T/sys /usr/bin/python3 shell/plugins/vgs.displays/helper/brightness.py set hidraw:class/hidraw/hidraw0/device 50"`.
- **Device**: `scripts/smoke/fixtures/devices/hid-fake.py` served its `hid-world.json`, one Pro Display XDR, on a socket in the temporary directory `$T`, with temporary `/dev` and sysfs trees. The fake logged 53 write requests: 3 warm-up runs and 50 timed runs.
- **Result**: mean 31.9 ms ± 2.3 ms, median 31.3 ms, min 28.2 ms, p95 36.6 ms, max 39.5 ms; user 26.0 ms, system 5.3 ms.
- **Machine**: host `cachy`, AMD Ryzen 9 9950X with 32 threads, kernel 7.2.8-1-cachyos, Python 3.14.7, `/proc/loadavg` 6.22 6.98 7.18.

The helper's own cost does not reach the 150 ms budget. The figure does not hold a real USB transfer or a `ddcutil` call. S21, the owner's hardware acceptance, measures both on the real displays. A DDC call starts `ddcutil`, which talks over I2C. `ddcutil detect` probes every bus, so the helper keeps its result for 30 s and drops it on a hotplug.

**Rationale**:

- A run per call holds no memory between calls. D010 bounds the resident size, and the measured cost gives no reason to spend it.
- One helper holds the hidraw grouping, the output mapping and the access states in one file. `scripts/test-displays-brightness.py` runs it end to end against the device fakes.
- v1 used hidraw first and `asdcontrol` only as a fallback (v1 `bin/vshell_helper.py:9976-10017`). S21 confirms hidraw on both Apple displays (review E2).
- `uaccess` grants the node to the user of the active local seat and takes it back when the seat changes. A group grant reaches every session of a group member.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| A resident helper or daemon | The measured p95 is 36.6 ms against a 150 ms budget. A resident process adds the size D010 bounds. |
| `asdcontrol` over `hiddev` | Each call needs `sudo` or a second rule for `hiddev`. hidraw was v1's primary path. If S21 finds a display hidraw cannot drive, a follow-up adds a scoped `hiddev` path. |
| v1's rule, `MODE="0660", GROUP="users"` beside `uaccess` | The group grant reaches SSH sessions and sessions on other seats. |
| A QML `Process` per backend | QML still cannot send a feature report. The identity, mapping and access logic would split across QML and three programs. |

## Omarchy comparison

Omarchy (basecamp/omarchy `quattro`, `bin/omarchy-brightness-display-apple`, read at 8b4eae6) finds the display with `sudo asdcontrol --detect` over `/dev/usb/hiddev*` and `/dev/hiddev*`, caches the node under `$XDG_RUNTIME_DIR`, and reads and sets brightness with `sudo asdcontrol`. VGS takes the runtime-dir cache, for `ddcutil detect`. It differs on access: every Omarchy call runs `sudo`, which asks for a password or needs a sudo rule, and [D061](D061-no-manual-commands.md) allows no manual command. A hidraw node with `uaccess` needs no privilege, so a slider write is a plain open and `ioctl`.

**Revisit When**: S21 measures a p95 from release to write above 150 ms; hidraw cannot drive one of the two Apple models; or a distribution ships `ddcutil` without a `uaccess` rule for display-class I2C nodes.

**Verification**: `scripts/test-displays-brightness.py`, the `cli` row "displays brightness helper" of `scripts/validate`, with one planted defect per rule; the measurement above; S21 on the owner's displays.

**References**: [D010](D010-facade-scope-not-sandbox.md), [D061](D061-no-manual-commands.md), [displays.md](../architecture/displays.md), [validation-smoke-devices.md](../architecture/validation-smoke-devices.md).
