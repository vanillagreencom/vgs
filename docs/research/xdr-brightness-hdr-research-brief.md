# Research brief: pushing Apple Pro Display XDR (and Studio Display) brightness on Linux to macOS parity

**Audience:** a research agent tasked with deep investigation.
**Status:** open investigation. The brightness *control plumbing* is done and working; the
open problem is **peak luminance / HDR-EDR parity with macOS**.
**Date of snapshot:** 2026-07-15.

---

## 1. Objective

On macOS the Pro Display XDR reaches **~500 nits SDR sustained** and, with HDR/EDR
("Reference Modes" / XDR profile) engaged, **1000 nits sustained full-screen and 1600 nits
peak**. On this Linux box the XDR is currently driven in **8-bit SDR** and tops out around
**~500 nits** (possibly less — see §6). The user perceives it as **dimmer than on the Mac**.

Goal, in priority order:

1. **Primary — XDR:** make the XDR *at least as bright as on macOS with dynamic range / the
   XDR reference profile enabled.* That almost certainly means getting a working **HDR/EDR
   output path** on Linux (10-bit + BT.2020/PQ + HDR metadata) so the panel will unlock its
   >500-nit headroom, and/or controlling the display's **reference preset** (which caps SDR
   nits). Secondarily, confirm/raise the SDR ceiling itself.
2. **Secondary — Studio Display:** same investigation, lower priority (its brightness control
   already works well via the existing tooling; it is a 600-nit SDR panel with no XDR-style
   HDR headroom, so the ceiling is lower and the payoff smaller).

**Exhaust reasonable software/config/driver avenues. Do not do anything that risks damaging
the monitors (see §2).**

---

## 2. Hard safety constraints (read first)

The XDR and Studio Display are expensive and their control surface is a partially
reverse-engineered Apple USB-HID protocol. Observe these:

- **Never flash or modify display firmware.** No NVM writes, no `nvm_authenticate` on the
  Thunderbolt node, no vendor firmware tools.
- **The known-safe write surface is exactly one thing:** the VESA-style brightness feature
  report (HID report id 1, 32-bit little-endian value, range **400–60000**) — this is what
  `vshell brightness` and `asdcontrol`/`asdbctl` use. Values are clamped to that range and
  are fully reversible.
- **Do not blind-write unknown HID reports or raw USB control transfers to the display.**
  Reverse-engineering must be **read-only first** (dump `report_descriptor`, read feature
  reports). Only attempt a *write* to a new report if it is corroborated by a trustworthy
  reference implementation (asdbctl / BetterDisplay / BrightIntosh) *and* is understood; even
  then, treat it as experimental and reversible.
- **Compositor/GPU changes (HDR, 10-bit, color management) are software and non-damaging** —
  worst realistic case is a black screen recoverable via a TTY switch or reverting the monitor
  config. But **always keep an escape hatch** (SSH session, a VT, or a revert keybind) before
  toggling output mode, because a wedged modeset here has historically needed a TTY cycle.
- Avoid pathological rapid mode-flipping loops; step deliberately and observe.

---

## 3. System inventory (verified 2026-07-15)

| Component | Value |
|---|---|
| GPU | NVIDIA GeForce RTX 5090 (GB202), PCI `01:00.0` |
| GPU driver | **NVIDIA Open Kernel Module 610.43.03** (note: *open*, not the legacy proprietary module) |
| CPU | AMD Ryzen 9 9950X (**has RDNA2 iGPU, currently inactive** — only the 5090 drives displays) |
| Kernel | `7.1.3-2-cachyos` (bleeding-edge rolling) |
| Compositor | **Hyprland 0.55.4** (aquamarine backend) — *has* a color-management/HDR pipeline |
| Display 1 | Apple **Pro Display XDR**, connector `DP-1` (Hyprland primary/focused), 6016×3384 @60, scale 2 |
| Display 2 | Apple **Studio Display**, connector `DP-2`, portrait (`transform 1`) |
| XDR video path | 5090 DP-out → ASUS board **DP-IN** → motherboard **Thunderbolt/USB4** (ASMedia ASM4242) → XDR (DP tunneled; USB tunneled) |
| XDR USB control | `05ac:9243`, `bcdDevice=400c`, on the tunneled USB bus (behind XDR hubs `05ac:9138`/`9139`) |
| XDR Thunderbolt NVM | `nvm_version=55.0` |

### Current XDR output state (Hyprland `hyprctl monitors`, DP-1)

```
currentFormat        = XRGB8888        # 8-bit, SDR — HDR is NOT engaged
colorManagementPreset = srgb
sdrBrightness        = 1.0
sdrMaxLuminance      = 80              # nits reference white used by the CM pipeline
sdrMinLuminance      = 0.2
vrr                  = False
```

### XDR EDID-advertised capability (parsed from `/sys/class/drm/card1-DP-1/edid`)

```
HDR static metadata block present:
  EOTF: SDR + traditional-HDR + PQ/ST2084 (HDR10)   [HLG not advertised]
  Desired max luminance:      1600 nits
  Desired max frame-avg lum:   508 nits
```

So the **panel advertises HDR10/PQ up to 1600 nits** but the compositor is driving plain 8-bit
SDR, leaving all of that headroom unused.

---

## 4. What already exists (the brightness plumbing — done, not the problem)

`vshell brightness` (in `bin/vshell-helper`, this repo; architecture:
`docs/architecture/display-brightness.md`) already provides robust brightness control:

- **Apple backend:** native **hidraw** feature-report read/write (HID report id 1, 32-bit LE,
  400–60000) — pure Python, no `CONFIG_USB_HIDDEV` needed; `asdcontrol` (hiddev) is a fallback.
  Control interface is **discovered at runtime** (probes each HID interface). Hardware-validated
  read+write on both displays.
- **udev:** `config/vshell/udev/60-vshell-apple-displays.rules`, matched by USB **product id**
  (`05ac:9243`/`1114`) + `TAG+="uaccess"`, no interface-path pinning. `vshell brightness
  install-udev` regenerates + applies it.
- **Other backends:** `brightnessctl` (backlight), `ddcutil` (DDC/CI) — auto-selected per display.
- **Diagnostics:** `vshell brightness doctor`.

**What this controls:** the display's **SDR backlight level within the current reference
preset** — i.e. the 400–60000 HID value maps to the panel's SDR brightness, roughly 0→~500
nits in the standard preset. **It cannot exceed the SDR ceiling.** The >500-nit HDR/EDR range
is a *different mechanism* (see §5) that this HID channel does not touch. Setting `100%`
writes raw 60000 and was confirmed to reach the panel's SDR max.

**Conclusion:** the control path is solved. The remaining problem is entirely about **HDR/EDR
output and/or the reference preset**, not about the USB brightness channel.

---

## 5. The core technical distinction (why it's capped)

There are **two independent luminance levers** on the XDR:

1. **SDR backlight (HID brightness, 0x10).** What `vshell brightness` controls. Scales 0→(SDR
   ceiling of the active reference preset). Max ~500 nits. **Already maxed.**
2. **HDR/EDR headroom.** To exceed the SDR ceiling the display must be put into **HDR mode**:
   the DisplayPort stream carries **BT.2020 + PQ (ST.2084) with HDR10 static metadata**, and
   the compositor tone-maps SDR content to a reference white while letting HDR (or
   EDR-upscaled) content use the range above it — up to the panel's 1000/1600-nit capability.
   This is a **GPU + compositor** function, *not* the USB HID channel. On macOS this is
   "Reference Modes" / EDR; BetterDisplay/BrightIntosh emulate it via GPU EDR/gamma tricks.

On Linux/Wayland this requires the whole HDR pipeline to be working:
`app → wayland color-management-v1 → Hyprland CM → 10-bit BT2020/PQ scanout → DRM
HDR_OUTPUT_METADATA → DP → XDR HDR mode`. Currently **none of that is active** (output is
8-bit sRGB), so the headroom is unreachable.

**Note on the historical blocker:** the dotfiles config disables 10-bit + wide-gamut because,
per the note in `~/dotfiles/hypr/.config/hypr/config/monitors.lua`, a **10-bit XR30 swapchain
on nvidia + aquamarine could not be GBM-allocated, wedging DPMS-off→on to a black screen
(recoverable only by a TTY cycle).** That note predates the **current open-module driver
610.43.03**. **This bug may now be stale — re-verifying it is research track A.**

---

## 6. Why it may look "dimmer than the Mac" — hypotheses to test

1. **SDR-only, no EDR headroom** (most likely). macOS makes even nominally-SDR UI feel brighter
   because EDR keeps headroom and the reference white is higher; Linux is flat SDR at ~500.
2. **The XDR reference preset caps nits below 500.** The preset (Apple's "Preset" dropdown:
   e.g. *Apple Display (P3-500 nits)* = 500, but *Design & Print*/*Photography* presets = ~160
   nits) sets the SDR ceiling. macOS sets it; **we cannot currently read or set it on Linux.**
   If the display is stuck in a low-nit preset, HID 100% is far below 500 nits. **Determining
   and controlling the active preset is a key lever (research track C).**
3. **Compositor SDR reference is low.** Hyprland reports `sdrMaxLuminance = 80`,
   `sdrBrightness = 1.0`. In its CM pipeline SDR white is mapped to ~80–200 nits; if HDR mode is
   enabled without raising `sdrbrightness`, the *desktop* can actually get **dimmer**, not
   brighter. Tuning `sdrbrightness`/`sdrMaxLuminance` matters.
4. **Gamma/tone/EOTF mismatch** making perceived brightness lower even at equal peak.

The user believes it is currently ~500 nits SDR and wants to (a) confirm, and (b) push higher
via HDR/EDR or preset control.

---

## 7. Research tracks

### Track A — Re-validate (and hopefully retire) the nvidia 10-bit / GBM black-screen bug
- **Question:** does 10-bit (XR30 / `XRGB2101010`) output + DPMS-off→on still wedge on the
  **open** driver **610.43.03** + Hyprland 0.55.4/aquamarine + kernel 7.1.3? The disabling note
  predates this driver.
- **Why:** 10-bit is a prerequisite for HDR. If the bug is gone, the whole HDR path opens up.
- **Do:** with an escape hatch ready (VT/SSH/revert keybind), enable `bitdepth 10` on DP-1 only,
  test normal use + a DPMS off→on cycle (`hyprctl dispatch dpms off/on`, lid/idle). Watch
  `dmesg` for GBM/allocation errors, aquamarine swapchain errors, nvidia-drm messages.
- **Validate safe:** revert to 8-bit immediately if it wedges; confirm recovery path first.
- **References:** nvidia open-gpu-kernel-modules issues on 10-bit/HDR Wayland; Hyprland +
  aquamarine HDR issues; wlroots/Mesa GBM format-modifier support for XR30 on nvidia.

### Track B — Stand up the Hyprland HDR pipeline and drive the XDR into HDR mode
- **Question:** can Hyprland 0.55.4 output BT2020/PQ + HDR10 metadata to the XDR so the panel
  enters HDR mode and unlocks >500 nits?
- **Why:** this is the direct path to macOS-parity peak brightness.
- **Do:** research Hyprland's current color-management/HDR knobs (monitor `cm` =
  `srgb|wide|edid|hdr|hdredid|auto`, `bitdepth 10`, `sdrbrightness`, `sdrsaturation`); the
  `experimental` CM settings; the `wayland color-management-v1` protocol support in this build.
  Try `cm hdr` (or `hdredid`) + 10-bit on DP-1. Confirm the DRM connector's
  `HDR_OUTPUT_METADATA` / `Colorspace` / `max bpc` props flip (install/use `drm_info`,
  `proptest`, or `wayland-info`). Confirm the XDR reports/enters HDR (it should visibly change;
  EDID EOTF supports PQ). Then **tune `sdrbrightness`/`sdrMaxLuminance` so the SDR desktop is not
  dimmer** while HDR content uses headroom.
- **Success signal:** connector shows HDR10/PQ + BT2020 active; a known HDR test pattern/video
  exceeds SDR white; measured or perceived peak clearly above the SDR ~500-nit level.
- **Validate safe:** software-only; keep the escape hatch. No display risk.
- **References:** Hyprland wiki (color management / HDR); wayland-protocols
  `color-management-v1`; nvidia 610 HDR-on-Wayland notes; Mesa/`kwin`/`gamescope` HDR behavior
  for cross-checking expected DRM state.

### Track C — Read/control the XDR "reference preset" (the SDR nit ceiling + HDR behavior)
- **Question:** which reference preset is the XDR in, and can it be read/set over USB on Linux?
  This directly determines the SDR nit ceiling and whether the panel will honor HDR.
- **Why:** if the display is in a sub-500-nit preset, that alone explains the dimness, and
  fixing it may not even need full HDR.
- **Do:** dump the XDR's HID `report_descriptor` for all its interfaces; enumerate feature
  reports beyond 0x10; compare against macOS USB captures and the reverse-engineered protocols
  in **asdbctl**, **BetterDisplay**, **BrightIntosh**. Identify whether preset selection / EOTF
  / "XDR mode" is exposed as an Apple vendor HID report. **Read-only first** (see §2); only
  attempt a write if corroborated and understood.
- **Success signal:** ability to read the active preset; ideally a validated, reversible way to
  select the 500-nit (or an HDR/reference) preset.
- **Validate safe:** read-only exploration is safe; writes only per §2 constraints.
- **References:** github.com/juliuszint/asdbctl (USB control-transfer protocol: bmRequestType
  0x21, bRequest 0x09, wValue 0x0301, LE value, 400–60000); github.com/waydabber/BetterDisplay
  (+ its "XDR and HDR brightness upscaling" wiki); github.com/niklasr22/BrightIntosh;
  github.com/nikosdion/asdcontrol (issue #6 on ranges). USB-sniff an actual Mac if available.

### Track D — EDR-style software upscaling analog on Linux
- **Question:** is there a Linux/Wayland analog to macOS EDR (tone-map/boost SDR content into HDR
  headroom so the *whole* screen can be brighter than SDR reference)?
- **Why:** macOS "brightness beyond 100%" for the XDR is largely EDR, not the backlight.
- **Do:** research whether Hyprland's CM pipeline (or a shader/LUT/gamma approach) can push SDR
  content above the SDR reference white once HDR output is active (Track B). Evaluate
  `sdrbrightness > 1.0`, per-window HDR, or a compositor tone-curve. Cross-check how gamescope
  handles SDR-on-HDR "SDR gamut/luminance" boosts.
- **Validate safe:** software-only.

### Track E — Verify the USB/Thunderbolt tunnel + preset are stable and repeatable
- **Context:** the XDR's control device (`05ac:9243`) intermittently fails to enumerate
  (`error -71`, "not responding to setup address") after firmware update / re-cable; the fix is
  a **display power-cycle** (not a TB replug). Any HDR/preset work must account for this so it
  isn't confused with a mode-switch failure.
- **Do:** document a reliable bring-up (power-cycle display → confirm `9243` → `vshell
  brightness install-udev`). Check whether HDR modeset itself perturbs the tunnel.

### Track F — Rule out / characterize DDC and other channels
- The XDR is USB-HID controlled (no meaningful DDC/CI expected), but confirm whether `ddcutil`
  sees anything on the XDR (likely not) and whether the DP-IN→TB path exposes any MCCS controls.
  Low priority.

---

## 8. Suggested first experiments (ordered, all reversible)

1. **Measure the baseline.** Confirm current perceived/measured nits at HID 100% (a colorimeter
   if available; otherwise a known reference). Establishes whether we're at 500 or a lower preset.
2. **Track A quick test:** enable 10-bit on DP-1 with an escape hatch; DPMS off/on; read `dmesg`.
   Decide if the historical GBM wedge is gone on driver 610-open.
3. **If 10-bit is stable → Track B:** enable Hyprland `cm hdr`/`hdredid` + 10-bit on DP-1;
   verify DRM connector goes HDR10/PQ/BT2020; test an HDR clip for >SDR peak; tune
   `sdrbrightness` so the desktop isn't dimmer.
4. **In parallel → Track C (read-only):** dump XDR HID descriptors + feature reports; map against
   asdbctl/BetterDisplay to find preset/EOTF controls. No writes until §2 is satisfied.

Report findings per track with: what was tried, observed DRM/compositor state, dmesg evidence,
and whether peak luminance measurably increased — plus any dead ends, so effort isn't repeated.

---

## 9. Open questions

- Is the historical 10-bit/GBM/DPMS wedge fixed on **open driver 610.43.03** + Hyprland 0.55.4?
- Does Hyprland 0.55.4 + aquamarine emit correct `HDR_OUTPUT_METADATA`/BT2020/PQ to a
  DP-IN→Thunderbolt-tunneled sink (does the tunnel pass HDR infoframes)?
- What reference preset is the XDR in right now, and is preset selection reachable over USB on
  Linux at all?
- Does the TB DP-tunnel (mobo DP-IN → USB4) impose any bandwidth/HDR limitation vs a direct DP
  link? (6K@60 already works; HDR10 adds metadata, not much bandwidth, but confirm.)
- Can SDR content be boosted (EDR-analog) once HDR is on, or only true-HDR content?

## 10. Key references (starting points, verify current)

- Hyprland color management / HDR docs (wiki) — monitor `cm`, `bitdepth`, `sdrbrightness`.
- `wayland-protocols` **color-management-v1** (staging) — the HDR handshake.
- NVIDIA **open-gpu-kernel-modules** issues re: 10-bit/HDR/Wayland/GBM on 5xx–61x drivers.
- **asdbctl** (github.com/juliuszint/asdbctl) — XDR/Studio USB control-transfer protocol + ranges.
- **BetterDisplay** + its wiki *"XDR and HDR brightness upscaling"* (github.com/waydabber/BetterDisplay) — the definitive description of EDR/HDR upscaling mechanism (macOS).
- **BrightIntosh** (github.com/niklasr22/BrightIntosh) — EDR-based brightness boost.
- **asdcontrol** (github.com/nikosdion/asdcontrol), issue #6 — brightness ranges (400–50000/60000).
- `gamescope` HDR implementation — reference for expected DRM HDR state and SDR-on-HDR luminance handling.

---

### Appendix: reproduce the current-state readings
```bash
hyprctl -j monitors | jq '.[] | select(.name=="DP-1") | {currentFormat, colorManagementPreset, sdrBrightness, sdrMaxLuminance}'
# EDID HDR caps:
python3 - <<'PY'
data=open('/sys/class/drm/card1-DP-1/edid','rb').read()
# (HDR static metadata parser — see this repo's git history / brief author for the snippet)
PY
vshell brightness doctor
vshell brightness list --json
```
