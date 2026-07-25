# Findings: XDR brightness / HDR-EDR parity investigation

**Executed:** 2026-07-15, live workstation (RTX 5090, nvidia-open 610.43.03,
Hyprland 0.55.4 / aquamarine 0.12.1, kernel 7.1.3-2-cachyos).
**Brief:** `docs/research/xdr-brightness-hdr-research-brief.md`.
**TL;DR:** The full Linux HDR pipeline now works end-to-end (10-bit + BT2020/PQ +
HDR10 metadata + client passthrough) and is persisted in dotfiles. But the XDR
**physically clamps at its ~500-nit SDR ceiling even for correct HDR10/PQ input**
(verified with the display's own light sensors), while already sitting in its
factory "Pro Display XDR (P3-1600 nits)" preset. macOS-parity peak brightness is
therefore *not* reachable via standard HDR10 signaling; the unlock lives in
Apple's proprietary EDR path. The panel's reference-preset state **is readable
over USB on Linux** (vendor HID interface 4) — the most promising next lever.

---

## Track A — nvidia 10-bit / GBM wedge: **retired** ✅

- `GBM: format XR30 isn't supported by primary backend` **still occurs** on
  nvidia-open 610.43.03 — the historical failure is real and unfixed.
- **But aquamarine 0.12.1 now falls back to XB30 (`XBGR2101010`)**, which
  allocates with native NVIDIA block-linear modifiers
  (`0x300000000606014`). `currentFormat` lands on `XBGR2101010`, not
  `XRGB2101010`.
- DPMS off→on at 10-bit: tested per-monitor (DP-1, DP-2) and all-monitors —
  clean recovery every time, zero page-flip/nvidia errors in dmesg or the
  Hyprland log. The old "permanent black until TTY cycle" wedge did not
  reproduce.
- The XR30 failure lines still print on every swapchain rebuild; they are
  cosmetic (the XB30 retry follows immediately).
- **User field note:** DP-1 sometimes needs a few `dpms on` cycles to light up
  after `dpms off` (pre-existing behavior, independent of bit depth/HDR; always
  recovers). Likely DP-link bring-up flakiness on the TB-tunneled path.

## Track B — Hyprland HDR pipeline: **fully working** ✅

Persisted config (`~/dotfiles/hypr/.config/hypr/config/monitors.lua`):

```lua
hl.config({
    debug = { full_cm_proto = true },
    render = { cm_auto_hdr = 2 },  -- fullscreen HDR apps flip an SDR output to hdredid
})
hl.monitor({ output = "DP-1", mode = "6016x3384@60", position = "0x0",
             scale = 2, bitdepth = 10, cm = "hdr", sdr_max_luminance = 500 })
hl.monitor({ output = "DP-2", mode = "5120x2880@60", position = "-1440x-620",
             scale = 2, transform = 1, bitdepth = 10 })
```

Verified state:

- DRM connector (XDR): `Colorspace = 9 (BT2020_RGB)`, `HDR_OUTPUT_METADATA`
  blob: `eotf=2 (PQ)`, BT.2020 primaries, max 1600 / max_cll 1600 /
  max_fall 507 — matches the panel EDID exactly. nvidia-drm exposes no
  `max bpc` property; bit depth follows the framebuffer format. (Caveat: the
  generic debugfs `dri/1/state` still prints `colorspace=Default` — nvidia
  tracks these out of band, so infoframe emission can't be introspected there.)
- `wp_color_manager_v1` v1 is advertised; **`debug:full_cm_proto = true` is
  required** for real HDR passthrough — without it Hyprland offers clients only
  an 80-nit sRGB preferred image description and mpv tone-maps HDR *down* to
  SDR. With it, a surface on DP-1 receives
  `pq / bt.2020, max_luma 1600, max_cll 1600, max_fall 507, ref_luma 203` and
  mpv (`--vo=gpu-next --target-colorspace-hint=yes`) does true PQ passthrough.
  The preferred description update arrives only once the surface is *placed on*
  the HDR output (initial feedback is sRGB — clients must handle the update;
  mpv does).
- `sdr_max_luminance` (monitorv2 key) sets the nit level SDR white maps to in
  the PQ signal. At `500` the SDR desktop measures the same as sRGB mode at
  full backlight (ALS A/B: HDR-mode white ≈ +5% vs sRGB-mode white), i.e. **no
  desktop dimming** — hypothesis §6.3 of the brief solved. `sdrbrightness`
  (multiplier, accepted at runtime) stacks on top; note that runtime monitor
  rules *merge*: omitting a key does not reset it, set it explicitly.
- Hyprland 0.55.4 exposes further CM knobs: `render:cm_enabled` (true),
  `render:cm_auto_hdr` (1), `render:cm_sdr_eotf`, `render:fp16_sdr_tf`,
  `experimental:wp_cm_1_2` (untested).
- Hyprland's Lua config: runtime changes go through `hyprctl eval
  'hl.monitor({...})'` / `hl.config({...})` (`hyprctl keyword` is rejected:
  "keyword can't work with non-legacy parsers"). DPMS via
  `hl.dispatch(hl.dsp.dpms({action="off", monitor="DP-1"}))`.

## The core negative result — panel clamps HDR at the SDR ceiling ❌

Photometric evidence via the displays' own ambient-light sensors
(`/sys/bus/iio/devices/iio:device1` = XDR ALS, `device0` = Studio ALS —
IIO `in_illuminance_raw`, stable to ~±0.3%):

| Condition (fullscreen on DP-1) | XDR ALS delta vs black |
|---|---|
| SDR white, full-field (mapped to 500 nits) | +2430 |
| **HDR PQ 10000-nit white, full-field** (mpv passthrough → 1600 target) | **+2710 (+12% vs SDR)** |
| SDR white, 25% patch | +587 |
| **HDR PQ white, 25% patch** (small-window case where XDR specs 1600 nits) | **+609 (+4% vs SDR)** |

If the panel honored PQ luminance above SDR, the patch case should read ~3×
the SDR delta (1600 vs 500 nits), and full-field ~2× (1000-nit sustained spec).
It reads essentially equal. Additional control: sRGB-mode white ≈ HDR-mode
white (rules out "panel ignores PQ entirely" — a PQ-code-0.678 white
misdecoded as sRGB would display at ~210 nits, i.e. *much dimmer*; it doesn't).

**Conclusion:** the XDR decodes PQ correctly but limits output to the SDR
ceiling (~500 nits) for a generic HDR10 DisplayPort source. The >500-nit range
on macOS is granted through Apple's EDR mechanism (macOS-driven, not
plain HDR10 infoframes). Windows reportedly shows the same behavior class —
the panel is not a standard HDR10 sink above its SDR range.

## Track C — XDR USB control surface: **preset is readable on Linux** 🔓

`05ac:9243` exposes 5 HID interfaces (all on the tunneled USB bus):

| iface | descriptor | content |
|---|---|---|
| 0, 1 | 359 B | sensor-hub: ambient light sensors (the IIO `als` devices), incl. Apple vendor page `0xFF15` fields |
| 2 | 79 B | **brightness**: Monitor/VESA page, report id 1, feature, 32-bit LE, logical 400–50000, unit cd/m² exp −2 → **centi-nits, 4.00–500.00 nits**; plus a 16-bit 0–20000 ms feature (usage page 0x0F "Duration" — likely fade time); plus an INPUT report mirroring brightness |
| 3 | 40 B | orientation sensor (0–360°, three 9-bit fields; kernel `hid_sensor_rotation` probe fails −22, harmless) |
| 4 | 492 B | **Apple vendor surface** — kernel can't bind it (`invalid report_size 32768`), see below |

Interface 4 decoded (vendor pages `0xFF00/16/20/22/23/28/2A/2B/2D`):

- Report 2: 4096-byte INPUT + OUTPUT pipe (page 0xFF22) — bulk data channel
  (why the kernel rejects the descriptor). Report 7: second pipe, 2000-byte
  frames (page 0xFF23). Almost certainly firmware/diagnostic transport.
- Reports 3/4/5 (page 0xFF20): **report 0x05 (GET_REPORT feature, read-only)
  returns UTF-16LE text: "Pro Display XDR (P3-1600 nits)" + the full macOS
  reference-mode description.** The panel is in its factory default preset —
  so a low-nit preset is *not* the cause of the clamp (brief hypothesis §6.2
  ruled out). Report 0x04 is a writable 32-bit selector (currently 0) directly
  preceding it — plausibly an index for enumerating/selecting presets, **not
  written** (no corroborating reference implementation yet; brief §2).
- Reports 0x0D / 0x0E (pages 0xFF2B/0xFF2D): writable 1-byte features with
  logical range **0–7** plus a 64-bit blob — small-integer selectors of
  unknown meaning (preset? input? power profile?). Read-only values today: 0.
- Reports 0x08/0x09 (pages 0xFF28/0xFF2A): writable feature blocks, currently
  all zeros, with interesting logical maxima (6112, 2048, 14336) — geometry or
  luminance-table shaped; unidentified.
- GET_REPORT of all declared feature IDs succeeded except 0x06/0x07/0x0C/0xFC
  (stall = not readable). No writes were performed anywhere.

Studio Display cross-check: same 79-byte brightness descriptor but logical max
**60000 (600.00 nits)**; no 492-byte vendor interface (largest 253 B).
`asdcontrol#6`'s "practical ceiling of 50000" is simply the XDR's declared
descriptor max.

**vshell fix landed:** `APPLE_DISPLAYS` now carries per-display maxima
(XDR 50000, Studio 60000) with a probe gate that still tolerates an XDR that
stored 60000 from before (`bin/vshell-helper`, `scripts/check-brightness.py`
extended). The XDR previously *stored* 60000 (clamped physically); `set 100`
now writes exactly 50000.

## Track D — EDR-style SDR boost

Mechanically works: `sdr_max_luminance` (and `sdrbrightness`) push SDR white to
any nit level in the PQ signal, verified by the compositor accepting up to 1600.
**Physically moot until the panel clamp is lifted** — the panel renders
everything above ~500 identically. If the clamp is ever cracked (see next
steps), whole-desktop macOS-EDR-parity brightness is a one-line config change
(`sdr_max_luminance = 1000`).

## Post-session addendum (same evening): HID backlight vs PQ mode, and a panel wedge

- With the persistent HDR desktop active, the user found brightness keys dead.
  ALS-verified: in PQ mode the XDR **stores** HID brightness writes (reads
  round-trip) but does **not apply them** — matching macOS locking the slider
  in fixed-luminance reference modes and Boot Camp disabling brightness in the
  1600-nit preset. Consequence: a persistent HDR desktop costs physical
  brightness control (compositor-side `sdr_max_luminance` becomes the only
  lever, à la Windows "SDR content brightness").
- **Config changed accordingly**: DP-1 back to a 10-bit SDR desktop;
  `render:cm_auto_hdr = 2` keeps real HDR for fullscreen HDR clients on
  demand. Re-enable the persistent HDR desktop only when compositor-side
  brightness is wired into the shell (or the preset unlock lands).
- **Caveat**: after reverting to SDR (DRM confirmed: Colorspace=Default, HDR
  blob 0), the XDR *still* ignored applied brightness while a Studio Display
  positive control responded normally — i.e. the panel's brightness engine
  had wedged (stores-but-ignores) after the day's mode churn / USB resets.
  Fix: display power-cycle. Because every brightness-response measurement
  today postdates the first HDR enable, "PQ mode ignores HID" is confirmed
  behavior-wise but the exact trigger boundary (PQ mode vs controller wedge)
  should be re-verified once after a power-cycle: test HID response in SDR,
  then optionally in HDR again.
- A separate user-visible event: fullscreen white in a browser briefly
  blacked out DP-1 (compositor saw a connector rescan = DP link blip; no USB
  drop, no errors). Same family as the known DPMS-wake retry flakiness on
  this tunneled link; cause unproven, watch for recurrence in SDR mode.
- **Recovery playbook (validated end-to-end that evening):**
  - The stores-but-ignores brightness wedge survives a *quick* power replug —
    the XDR has no power switch and its MCU rides through. The working fix is
    a **deep power-cycle**: unplug power AND Thunderbolt, wait 60–90 s,
    reconnect power first, wait ~30 s for firmware boot, then Thunderbolt.
    Cold boot confirmed by brightness resetting to its 35000 power-on default;
    backlight obeyed HID again immediately after (ALS-verified 100↔20%).
  - Panel-black-after-reconnect: **every bring-up attempt is probabilistic.**
    In one episode six DPMS cycles failed and an output disable→enable
    (`hl.monitor({output="DP-1", disabled=true})` then re-apply) lit it first
    try; in a later episode two rescues failed and six manual DPMS toggles
    won. Treat DPMS cycles and the output-cycle rescue (bound to
    Super+Shift+F6, `hypr/scripts/xdr-rescue.sh`) as complementary rerolls.
    **Never modeset a lit panel** — a "test" rescue on a healthy panel knocked
    it black. The flakiness predates 10-bit (user-reported on the old 8-bit
    config), but if wake-lottery worsens in daily use, dropping DP-1 to 8-bit
    is the first variable to try.
  - Hyprland can miss the hotplug when the TB link comes back (kernel shows
    the connector `connected` but the monitor is absent from `hyprctl
    monitors`): `hyprctl reload` re-adds it.
  - "Is the panel actually emitting?" can be answered headlessly via its own
    ALS: fullscreen white vs black via mpv, delta >300 counts on the high-gain
    XDR sensor = lit. `dpmsStatus`, `link-status`, and DRM state all read
    healthy while the panel is dark — don't trust them.

## Track E — tunnel/bring-up reliability

- The HDR modeset itself did **not** drop the DP link or the USB tunnel.
- **But** rapid repeated monitor-rule application (5 rule changes in ~40 s
  during the luminance sweep) coincided with the XDR's *internal USB hub*
  (05ac:9139) disconnecting and re-enumerating twice on its own. Space out
  mode changes; treat mid-experiment ALS/HID dropouts as this, not as a
  modeset failure.
- **`usbhid-dump` detaches usbhid from every interface it dumps and does not
  rebind** — after using it, both displays' brightness control disappears
  ("USB control interface not enumerated" from doctor while lsusb still shows
  the device). Recovery without touching the display: `USBDEVFS_RESET` ioctl
  on the USB device node, then `echo <iface> > /sys/bus/usb/drivers/usbhid/bind`
  for each HID interface. Display power-cycle also works (and remains the fix
  for the true error-71 non-enumeration case).
- ALS reading of 300000 (device1) observed mid-USB-teardown: garbage during
  hub reset, not a real luminance sample.

## Track F — DDC: **ruled out** ✅

With `i2c-dev` loaded, both panels expose i2c buses via DP-AUX (EDID readable)
but **"DDC communication failed"** on both — no MCCS. USB-HID is the only
control channel. (`i2c-dev` unloaded again afterwards.)

---

## Research corroboration (source-verified web research, 2026-07-16)

A parallel research pass (Hyprland v0.55.4 + aquamarine v0.12.1 source, NVIDIA
docs/issues, mpv/gamescope source) confirms and extends the local results:

- `cm`/`sdrbrightness`/`sdrsaturation` landed in Hyprland 0.48.0;
  `cm_auto_hdr`, `sdr_min/max_luminance`, `min/max/max_avg_luminance`,
  `supports_hdr`/`supports_wide_color` in 0.50.0. `render:cm_fs_passthrough`
  was **removed in 0.55.0** (passthrough is automatic via `cm_auto_hdr`).
  SDR reference white is hardcoded 80 cd/m² (`SDR_REF_LUMINANCE`);
  `sdr_max_luminance` is the per-monitor override and `sdrbrightness` is a
  shader multiplier on top (wiki-sanctioned range 1.0–2.0). `monitorv2` also
  supports `min_luminance`/`max_luminance`/`max_avg_luminance` (EDID
  overrides) and `supports_hdr = 1` as a force-flag if EDID caps are misread.
- nvidia-drm has supported `HDR_OUTPUT_METADATA`/`Colorspace` since 545.29.02;
  it registers **no `max bpc`/`active bpc`** properties at all (code-search
  verified) — their absence here is normal. If HDR enable ever blanks the
  screen on kernels with the new color-pipeline API, `nvidia_drm.color_pipeline=0`
  is NVIDIA's documented workaround (not needed today).
- The XR30 GBM failure + XB30 fallback is reproduced upstream (Hyprland
  discussion #14799, RTX 4090). That report also describes an **unresolved
  0.55.2+ regression: newly-opened windows render dark on a persistent NVIDIA
  HDR desktop** (output-side only; screenshots correct). Not observed here so
  far — **watch for it**; fallback is `cm = "auto"` + relying on
  `cm_auto_hdr` fullscreen switching instead of a persistent HDR desktop.
  Other open 0.55.x HDR issues: over-bright cursor (#14419), lifted blacks
  (mitigate `sdr_min_luminance = 0.0`, #15195), red-shift on some panels
  (try `hdredid`, #14504).
- The suspend/DPMS "washed-out after resume" bug (kernel drops the HDR blob)
  was fixed in aquamarine 0.11.0 (PR #250, re-send HDR metadata on modeset) —
  present in 0.12.1 here, consistent with the clean DPMS cycles observed.
- mpv: Wayland target-colorspace support is complete in v0.41.0;
  `--target-colorspace-hint-mode=source` is required for `cm_auto_hdr` to
  trigger from mpv (>0.40). gamescope's SDR-in-HDR default is **400 nits**
  (`--hdr-sdr-content-nits`) — cross-validates mapping the SDR desktop well
  above Hyprland's 80-nit default (we use 500).
- **XDR on non-Mac hosts**: Windows 11 reports (imbushuo.net) say XDR HDR
  "works" via Windows Advanced Color **under the "Pro Display XDR" preset**
  — but *no published luminance measurements exist* for any non-Mac host, and
  Boot Camp forum reports say HDR is unavailable in non-HDR presets (preset
  persists in display hardware across hosts; only macOS can change it today).
  Apple's XDR white paper confirms the panel does **no tone mapping** —
  reference-mode behavior is fixed and out-of-range PQ simply clips. Our ALS
  measurement (HDR clamps at the SDR ceiling despite the P3-1600 preset) is
  therefore likely **the first real luminance data point for a non-Mac host**,
  and "HDR works on Windows" ≠ ">500 nits on Windows".
- Caveat from the same research: the XDR presents different EDIDs direct vs
  daisy-chained on Thunderbolt — if HDR caps ever look wrong, check topology.

### Track C corroboration (preset/USB research pass)

- **No public reverse-engineering of the XDR vendor HID interface exists** —
  no dumps of the 492-byte descriptor, no captures of preset switching, in any
  public project (asdbctl, asdcontrol, apdctl, studi all touch only brightness
  report 1). The interface-4 map in this document appears to be a first.
- **Preset switching over USB is proven to exist**: Apple's Boot Camp driver
  (`AppleProDisplayXDRUSBCompositeDevice`) switches XDR presets from generic
  Windows PCs where no Apple code can touch DP AUX, and requires the cable to
  carry USB. Display-side state, not a host ICC trick: selecting the P3-1600
  preset from Windows "activates HDR mode in Windows" and disables the
  brightness slider. The 0x0D/0x0E selectors + 0x04/0x05 preset-text reports
  found here are almost certainly that control path — wire format unconfirmed.
- **macOS EDR boost apps issue no display-side commands.** BrightIntosh/
  BrightXDR/xdr-boost force EDR with a 1×1 HDR Metal overlay + gamma trick;
  BetterDisplay's software path rewrites host color tables. The one exception
  (BetterDisplay's dead "Hardware Native XDR Upscaling") rode Apple's private
  *preset-management* APIs — i.e. still the preset mechanism. Conclusion: given
  (preset, SDR-reference-white), the panel displays >SDR pixel values from the
  DP signal alone, no per-frame USB traffic.
- **Tension with our measurement**: Windows reportedly gets working HDR (and
  LTT reports local dimming/brightness behavior) in the P3-1600 preset via the
  plain DP signal — yet this panel, *reading* as "Pro Display XDR (P3-1600
  nits)" over USB, clamps PQ at ~500 nits under Linux. Possible resolutions:
  (a) report 0x05 describes a preset *slot* (selector 0x04 = 0), not the
  *active* preset — the panel may actually be in a non-HDR preset;
  (b) the nvidia-open driver's DP colorimetry/SDP signaling differs from
  Windows drivers in a way the panel rejects; (c) Windows "HDR works" reports
  were never photometrically measured. Discriminating between these is the
  core of the next step.
- asdbctl's README notes an "unexplained vendor control (~usage 0x0f, max
  20000)" on the Studio Display — identified here: HID Physical Interface
  Device page, usage 0x50 (Duration), 0–20000 ms — a brightness *fade
  duration* alongside the brightness value (present in both panels'
  descriptors). Candidate upstream contribution.
- asdbctl supports PIDs 0x1116 (Studio Display XDR 2026) / 0x1118 (Studio
  Display 2026) — candidates for vshell's `APPLE_DISPLAYS` table if such a
  panel ever appears here (ranges unverified; don't guess).

## Where the remaining headroom actually lives (next steps, in order of promise)

1. **Locate the preset register via Mac state-diff (no capture tooling
   needed).** Preset state persists inside the display across hosts, so a Mac
   laptop can act as the "state setter":
   1. Baseline dump saved: `xdr-vendor-reports-baseline.txt` (tool:
      `xdr-iface4-read.py`, read-only; volatile registers annotated in the
      file header).
   2. Plug the XDR into a Mac. **First note which preset macOS shows as
      active** — this alone settles whether report 0x05 is the *active*
      preset or a *slot* description. Then switch to a distinctive preset
      (e.g. "Design & Print (P3-D50, 160 nits)").
   3. Replug into this box, re-dump, diff against the baseline → the changed
      stable bytes are the preset register, decoded for free.
   4. Repeat with a second preset ("HDR Video (P3-ST 2084)") for a second
      known value — two observed values of a known register make a Linux-side
      SET_REPORT both corroborated and reversible (satisfies brief §2; until
      then, **no writes** — the 0x0D/0x0E semantics could be anything).
   5. While on the Mac: verify the panel visibly exceeds SDR white with HDR
      content / an EDR boost app — confirms the hardware gap is protocol-only.
   Fallback if the diff shows nothing: Wireshark USB capture on the Mac, or
   USBPcap + Boot Camp Control Panel (`AppleProDisplayXDRUSBCompositeDevice`)
   in the Windows dual-boot — Boot Camp switches presets over this same USB
   channel from generic PCs, which is the existence proof for the whole path.
   Replug caveat: the XDR's USB control may need a display power-cycle after
   re-cabling (known −71 flakiness).
   After the register is known: preset control from Linux is a small,
   reversible SET_REPORT away, and per the Windows evidence the P3-1600
   preset + plain DP HDR10 signal is what unlocks >500-nit output.
2. **Verify the nvidia infoframe end-to-end** with an HDR10-capable reference
   sink (TV/capture card) to fully exclude a driver-side SDP gap — the +5%
   PQ-white response and correct PQ decode strongly suggest the signal is fine,
   but only an external sink proves it.
3. **Re-test after Hyprland/nvidia updates** — `experimental:wp_cm_1_2`,
   future `cm_auto_hdr` behavior, and any nvidia fix for XR30 GBM allocation.

## What was gained today (net)

- Both panels at 10-bit (banding ↓), XDR in real HDR10/PQ with wide-gamut
  (BT2020 container / P3 panel) output and working HDR passthrough for
  HDR-aware clients — at identical desktop brightness.
- SDR ceiling confirmed truly maxed (descriptor-exact 500.00 nits; vshell
  range bug fixed).
- The DPMS/10-bit fear that kept the setup on 8-bit is retired.
- A validated, safe, read-only map of the XDR's vendor control surface, with
  the preset name readable from Linux for the first time.
