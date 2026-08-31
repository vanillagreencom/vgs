# Display brightness architecture

`vshell brightness` controls per-display brightness across every backend a
machine actually has, with stable device identity and precise diagnostics.
Logic lives in `bin/vshell-helper` (`cmd_brightness` and helpers); the Go
backend (`backend/internal/services/brightnessbridge`) is a thin pass-through to
the helper, and QML (`quickshell/vshell/Services/DisplayService.qml`) consumes
the JSON. Heavy logic stays in the helper — QML shells out to `vshell
brightness ...`.

## Backends (auto-selected per display)

For each physical display VGS picks the highest-priority backend that can reach
it. Priority: **backlight → DDC/CI → Apple HID**.

| Class | Backend | Mechanism | Notes |
|-------|---------|-----------|-------|
| `backlight` | `brightnessctl` | `/sys/class/backlight/*` | Laptop panels, and Apple panels when the in-kernel `appledisplay` module claims them. Preferred when present. |
| `ddc` | `ddcutil` | DDC/CI over the video link, VESA MCCS feature `0x10` | Standard external monitors. No-ops with guidance if `ddcutil` isn't installed. Addressed by a stable EDID-derived id, resolved to its i2c bus at write time. `ddcutil detect` topology is cached (in-process + on-disk, 30 s TTL) so rescans and per-keypress `set` don't re-run the slow probe; brightness values are still read live via getvcp, and the cache is dropped on a setvcp failure. An Apple/backlight `set` resolves against the cheap backends first and skips DDC entirely. |
| `apple` | native **hidraw** (pure Python) or vendored **asdcontrol** | USB HID monitor-control feature report (report id 1, 32-bit little-endian value, range 400–60000) | Apple Pro Display XDR / Studio Display. See below. |

A single physical panel visible on multiple backends (shared EDID serial) is
deduplicated to the highest-priority one.

## Apple displays

Apple displays expose brightness as a USB HID feature report, not a backlight
(unless `appledisplay` is loaded). VGS talks to them two ways, preferring the
first:

1. **Native hidraw** (`_apple_hidraw_read` / `_apple_hidraw_write`,
   `HIDIOCGFEATURE` / `HIDIOCSFEATURE`). Pure Python, no compilation, and works
   even when the kernel is built without `CONFIG_USB_HIDDEV` (hidraw is created
   by the HID core for every HID device; hiddev is not).
2. **asdcontrol** (`third_party/asdcontrol`, hiddev ioctls) as a fallback,
   compiled on demand to `~/.cache/vshell/bin/asdcontrol`.

The **control interface number is never hardcoded.** Apple displays expose
several HID interfaces (e.g. the Studio Display exposes five); VGS probes each
candidate and keeps the one whose feature report both declares a Monitor/VESA
usage page and answers a brightness read within the display's raw range. Other
interfaces cleanly reject the read.

Raw range is the HID logical range in **centi-nits** (the descriptor declares
unit cd/m² with exponent −2) and is **per display**: the XDR declares
`400 … 50000` (4–500.00 nits, its SDR ceiling) and the Studio Display
`400 … 60000` (4–600.00 nits) — both confirmed from live report-descriptor
dumps. `asdcontrol#6`'s "practical ceiling of 50000" is simply the XDR's
declared max; a display accepts and stores values above its max but clamps
physical output, and the probe gate tolerates such stored values
(`APPLE_RAW_PROBE_CEILING`). "HDR/EDR brightness upscaling" to higher nits (à
la BetterDisplay/BrightIntosh) is a **separate GPU/compositor mechanism** over
the video link — it does not go through this USB control channel (and per
`docs/research/xdr-brightness-hdr-findings.md` the XDR clamps HDR10 input at
its SDR ceiling anyway).

### udev access (`config/vshell/udev/60-vshell-apple-displays.rules`)

The rule is **generated from the `APPLE_DISPLAYS` table** and matched purely by
`ATTRS{idVendor}`/`ATTRS{idProduct}` + `TAG+="uaccess"` — **no `DEVPATH` /
interface-path pinning**, so re-cabling the display to a different DP / USB /
Thunderbolt port keeps working. It grants the active-seat user access to every
HID control endpoint (hiddev *and* hidraw) the display exposes; the runtime
probe then selects the brightness interface.

`vshell brightness install-udev` regenerates the rule, writes it idempotently
(no rewrite when unchanged), and reloads + re-triggers udev so `uaccess` applies
to already-connected displays. `install-udev --print` dumps the rule without
root (used by the test that keeps the shipped file in sync). Note: udev rejects
trailing inline comments on a rule line, so labels sit on their own comment
lines.

## Device identity & targeting

`brightness list` reports a **stable id** per display — derived from the EDID /
USB descriptor (Apple: `apple-xdr` / `apple-studio`, serial-suffixed for a
second unit of the same model; DDC: `ddc-<mfg>-<model>-<serial>`) — so ids do
not change when connectors renumber on re-cable. `_resolve_targets` accepts:

- stable id or name
- legacy aliases `apple-xdr` / `apple-studio` (keybinds keep working)
- connector name (`DP-1`)
- role: `primary` (focused/origin monitor via Niri IPC or `hyprctl`, else
  backlight, else first) or `all`
- monitor-name substring

Empty target resolves to the primary display.

## Rescan scheduling & dead-hardware protection

QML rescans are **event-driven** — startup, display hotplug (staggered
retries), session resume, backend arrival, and failed or ambiguous write
responses — with one bounded timed exception: a committed failure arms a
single-shot recovery rescan two minutes later, at most
`scanRecoveryRetryBudget` per episode, and each failed retry counts toward
quarantine. No repeating poll: a poll re-enters the i2c/PCI bus even when the
probed device is dead in D3hot, wedging probes in uninterruptible sleep.
External brightness changes surface at the next event, not continuously.

On a dead bus the backend kills the helper at a hard timeout, and that
context deadline is the operative bound for the ddcutil chain: the helper
runs every probe pipe-isolated (`_run_timeout` and `run` use `stdout=PIPE`,
`stderr=PIPE`, plus Python's `close_fds` default), so a D-state ddcutil holds
the helper's pipes, not the backend's, and the kill on the killable helper
releases the backend's pipes at the deadline. `cmd.WaitDelay` is
defense-in-depth for a descendant that does inherit the backend's pipes,
bounding a read toward EOF that would otherwise never end. Neither bound can
abandon a helper that is itself in uninterruptible sleep — Wait blocks in
wait4 regardless — so probes that can D-state must stay in helper
subprocesses, never in the helper's own process; the QML pending-request
sweep and the scan quarantine are the backstop for that case.
`DisplayService` quarantines scanning after `scanQuarantineThreshold`
consecutive failures within one counting episode. Every lift — hotplug,
resume, backend arrival, a successful ddc write (backlight and apple writes
take the cheap path and prove nothing about the scanned i2c bus, so they
leave the quarantine held), or a late success
from a scan already in flight — starts a new
episode: failures of scans launched before it never count, every failure
inside it does, and the threshold sits above the 3-attempt retry ladders so a
fully failed ladder alone cannot latch. A settled-scan generation keeps
out-of-order responses from overwriting a newer verdict — a stale failure
cannot clobber a newer scan's success, and a stale success cannot restore
devices a newer committed failure cleared
(`scripts/test-brightness-scan-ordering.js` executes that decision). A
committed failure that cleared state also arms one recovery rescan minutes
later, at most `scanRecoveryRetryBudget` per episode — the write entry points
gate on availability, so without it a machine with no hotplug, resume, or
backend event never recovers; each failed retry counts toward quarantine.
Writes stay allowed — user-initiated, cheap backends first.

## `vshell brightness doctor`

Reports backend availability and, for every display, whether it is controllable
and — when it is not — the *specific* failing precondition rather than a generic
"install udev rules" message. It cross-references DRM connectors and Thunderbolt
topology, so it distinguishes:

- **connected but no `uaccess`** → `sudo vshell brightness install-udev`
- **DDC monitor, no `ddcutil`** → install `ddcutil`
- **DDC monitor, `ddcutil` present but no VCP 0x10 / i2c permissions** →
  i2c-dev / permissions
- **Apple display present over Thunderbolt (video/DP tunnel up) but its USB
  control interface never enumerated** → the host is not tunneling USB to the
  display; brightness cannot be reached until the display's USB enumerates.
  This is a Thunderbolt/USB-tunnel limitation, not a permissions problem (e.g.
  a Pro Display XDR fed DP-in → motherboard Thunderbolt: DisplayPort tunnels and
  video works, but `05ac:9243` is absent from USB, so no backend can reach it).

## Tests

`scripts/check-brightness.py` (pure logic, no hardware/root): backend
priority + dedup, target resolution, udev-rule generation (and that the shipped
file matches the generator), the Apple HID feature-report codec + range gate,
and the DDC/EDID parsers.

## Companion note: connector-name brittleness

Placement paths elsewhere still key off connector names (`DP-N`) that break on
re-cable (e.g. `VSHELL_SCREENSHOT_EDITOR_MONITOR`, greeter output selection).
The brightness `primary`/EDID-serial resolution here is the model for a shared
stable "primary display" concept those paths should adopt — tracked separately.
