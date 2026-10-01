# v2 System plan

A System settings family for VGS v2: one System window in the spirit of the macOS Settings app, with a sidebar and a detail pane. It has sections for Sound, Displays, Bluetooth, Network, VPN (Tailscale supported), Mouse and Keyboard. Each section also offers a bar widget and an anchored flyout. Displays carries the one thing the owner asked to keep from v1: per-output brightness for every kind of display, with Apple Pro Display XDR and Apple Studio Display working out of the box, plus v1's display arrangement settings.

Status: final plan for the master, revised after the cross-model challenge (`tmp/second-opinion/challenge-codex-detached.dZWlum`). Dispositions: [v2-system-plan-review.md](v2-system-plan-review.md). Nothing is filed and nothing is built. Issue list: `tmp/plans/system/issues.json`, copied to `docs/plans/v2-system-issues.json` (keys S01–S24). Keys are stable; S22–S24 were added by the review.

## 1. Framing

**Goal.** One System window and seven section plugins. Each section has a bar widget, a flyout and a System pane. Every core capability and every validation fake lands before the plugin that needs it.

**Perspective.** The plugin contract (`docs/architecture/plugins.md`, the vgs-plugin skill) is the judge. Omarchy (`tmp/omarchy-ref`, basecamp/omarchy `quattro` at `8b4eae6`) is the first reference for approach and code. v1 (`/home/method/dev/.worktrees/vgs/v1`) is a reference for brightness and display settings only.

**Constraints read.**
- Agent instructions: `AGENTS.md`, `shell/AGENTS.md`, `shell/plugins/AGENTS.md`, `scripts/AGENTS.md`.
- The vgs-plugin skill and `references/api.md`.
- Architecture docs: overview, plugins, plugin-manifest, capabilities, surfaces, settings-window, status, configuration, hyprland, hyprland-wiring, tui-sudo, runtime-hyprland(-nested).
- `shell/Core/PluginLogic.js` (setting targets), `shell/Core/Compositor.qml` (dispatch transport), `scripts/smoke/harness.sh` (buses, PATH, auth sentinels).
- Decisions on `main`: D010, D012, D013, D028, D032, D036, D037, D044, D047, D050, D053, D057, D061, D062, D069.
- Decisions not on `main` yet: D068 (branch `vgs-597-keyboard-first`), D075/D076 (`vgs-683-slack-photos-owner-only`), D077 (uncommitted in the `vgs-686` worktree).

**Assumptions.**
- D068, D075/D076 and D077 land on `main` before the UI items. VGS-597, VGS-683 and VGS-686 are external prerequisites.
- Quickshell 0.3.1 exposes `Quickshell.Bluetooth`, `Quickshell.Networking` (NetworkManager backend) and `Quickshell.Services.Pipewire`, including `PwNodePeakMonitor`. All are under the allowed `Quickshell` prefix and none is used yet. Read from `/usr/lib/qt6/qml/Quickshell/*` (quickshell-git 0.3.1) and the v0.3.1 web reference. Each item re-verifies its types on Context7.
- Hyprland v0.56.2 is configured in Lua. The Hyprland layer is the only place VGS writes Hyprland configuration.

## 2. Architecture

### 2.1 Choice: section plugins plus one host, through a new `pane` kind

| Option | Verdict |
|---|---|
| **A. One `vgs.system` plugin** with every section | Rejected. A plugin has one entry point per kind, so it gets one bar widget, not seven. Every section's service would run while any section is in use, every requirement would land on one page, and one section could not be enabled, updated or reviewed alone. **Not** claimed: crash isolation. All plugins share the shell process (D010), so a native crash anywhere ends every section under any option. |
| **B. Seven plugins, each with its own `window`** | Rejected. Seven toplevels and no sidebar is not the macOS model. |
| **C. Section plugins with a `pane` contract, hosted by `vgs.settings`** | Viable. D032 revisits when "a setting needs a type the schema cannot hold", and device lists, pairing and arrangement are exactly that. It is the same contract as D with a different host. |
| **D. Section plugins with a `pane` contract, hosted by a separate `vgs.system` window** | **Default.** It keeps the plugin manager's window and its rows untouched while the family lands. The pane contract is host-agnostic, so moving to C later changes which plugin holds `panes`, not the sections. |

The host choice is open question Q1. Under either host, the contract is the prerequisite: a reviewed `pane` kind, its own-plugin `shell`, and one settings store (§2.2). Ordinary settings stay manifest-drawn (D032). A pane adds live device control and never replaces the schema page.

Omarchy ships one plugin per section, each a bar widget with a flyout (`shell/plugins/panels/{audio,bluetooth,network,monitor,tailscale}/manifest.json`), and no settings app. VGS keeps the per-section split and adds the pane contract.

**Needs decision record:** "System sections are `pane` plugins mounted by the core into the one holder of `panes`". Refines D013 (its revisit condition: "a plugin must draw inside another plugin's surface"), D032 and D044.

### 2.2 The `pane` kind (core, S01)

- **Entry point.** `pane`: an `Item` with `open(payloadJson)` and `close()`. It fills its container.
- **Host.** The instance holding the new exclusive capability `panes`, made exclusive through `PluginLogic.lendRefusal` like `lock`/`polkit`.
- **Members.**
  - `shell.panes.list`: bindable, one `{ id, name, icon, group, order, placed, hasWidget }` per enabled pane plugin. The new manifest key `pane: { group, order }` supplies group and order.
  - `shell.panes.mount(id, container, payloadJson)`: builds that plugin's pane through a `PluginSlot` with **that plugin's** scoped `shell`, never the host's. Returns a disposer. One mount per host; a new mount replaces the old.
  - `shell.panes.setPlaced(id, placed)`: S02's placement rule, limited to listed pane plugins. The host needs no full `manager`.
- **Own-pane summon.** `shell.surfaces.summon("pane", payload)` summons the holder's window with `{"pane":"<caller id>", ...payload}`. It answers `refused: panes=no-holder` when none is enabled.
- **One settings store.** Today a bar widget reads its layout entry, every other kind reads the `plugins` row, and the manager writes both (`PluginLogic.settingTargetOf`, `settingTargets`, `managerSettings`). A pane's `configure.set` therefore writes **every entry the plugin reads**, the manager's multi-target contract, never one store.
  - Section plugins declare no placement-specific settings. Every section setting is plugin-wide.
  - S01's row edits a setting from the pane and from the Settings page, then reads the value back from the service, the widget, the pane and the Settings page.
- **Lifetime.** Built when shown, destroyed on switch or close. A closed window costs nothing; an open one costs one section.

### 2.3 The System window (`vgs.system`, S09)

The plugin has kind `window`, so it is a Hyprland toplevel (D044) titled "System". Capabilities: `panes`, `screens`, `shortcut`, `surfaces`, `ipc`, `run`.

- **Layout.** A `Pane` (D050) with two columns.
  - Sidebar: a search `TextField`, then `ListItem` rows with one `ListCursor` (D054), grouped under `SectionHeader`s and ordered by `pane.order`. At the foot, "Shell & Plugins" opens `vgs.settings` with `run.detached(["vgsh","ipc","call","shell","summon","window","vgs.settings","{}"])`, the path `settings-window.md` § Payload prescribes.
  - Detail: a header (icon, name, "Show in bar" `Switch` through `panes.setPlaced`), then the mounted pane in a `ScrollArea`.
- **Keyboard (D068).** Up/Down move the sidebar cursor. Enter or Right enter the pane. Type-ahead goes through `KeyNav`. Escape leaves the pane, then closes the window. Ctrl+F focuses search. The `toggle` shortcut's key is Q1.
- **Payload.** `{}` opens the last section, held in memory. `{"pane":"<id>", ...}` opens that section and hands the rest to `pane.open()`. An unknown id opens with a notice.
- **Relation to `vgs.settings`.** That window stays the plugin manager: list, enable, schema settings, keys, requirements. Both windows write through the multi-target contract (§2.2), so the values agree.

### 2.4 Inside each section plugin

| Kind | Role |
|---|---|
| `service` | Owns every subprocess, poller, watcher and **lease** (discovery, Wi-Fi scanning, agent), each released with its caller (D010, one owner per source). Publishes `status` (D037): `data` entries for structured lists within 64 KiB, and setup entries with one-click `action`s (D061). Registers shortcuts and, for Sound and Displays, the OSD through `layers`. |
| `bar-widget` | Extends `BarWidget`. Reads status or the in-process Quickshell singleton. Starts no process. Click opens the anchored `panel`; scroll adjusts where it fits. Takes no focus (D068), and the tooltip shows the effective key (D059). |
| `panel` | The flyout: quick controls plus "<Section> Settings…" (own-pane summon). |
| `pane` | The full section. |

Panel and pane share plugin-local QML through quoted paths. The Quickshell `Pipewire`, `Bluetooth` and `Networking` singletons are read models that claim no session role, so reading them lends nothing (D012). Anything that claims a session role or needs one owner goes through the service or a core capability: discovery and scanning leases, the Bluetooth agent (S22), monitor rules (S05).

**Capability matrix** (each issue repeats its row; S01 and S04 add fixture readbacks of the exact delivered members):

| Plugin | Capabilities |
|---|---|
| `vgs.system` | `panes`, `screens`, `shortcut`, `surfaces`, `ipc`, `run` |
| `vgs.sound` | `status`, `surfaces`, `ipc`, `configure`, `shortcut`, `layers`, `screens`, `requirements` |
| `vgs.bluetooth` | `status`, `surfaces`, `ipc`, `configure`, `system`, `requirements`, `bluetoothAgent` |
| `vgs.network` | `status`, `surfaces`, `ipc`, `configure`, `requirements` |
| `vgs.vpn` | `status`, `surfaces`, `ipc`, `configure`, `system`, `requirements`, `run`, `tui` |
| `vgs.displays` | `status`, `surfaces`, `ipc`, `configure`, `system`, `requirements`, `shortcut`, `layers`, `screens`, `monitors` |
| `vgs.mouse` | `status`, `surfaces`, `configure`, `hyprland` |
| `vgs.keyboard` | `status`, `surfaces`, `configure`, `hyprland`, `run` |

### 2.5 "Show in bar" (core, S02)

Enabling places a widget and disabling removes the whole plugin (`manager.md`). The new operation `setPlaced(id, placed)` places the widget in its `defaultSection`, or removes its layout entries, and never touches `disabledPlugins`. `PluginLogic` decides it. It is reachable as `manager.setPlaced` (Settings) and `panes.setPlaced` (System, S01). A widget with nothing to show hides itself with `implicitWidth: 0` while staying placed.

### 2.6 New core capabilities (all NEW)

| Item | Capability | Why core |
|---|---|---|
| S01 | Kind `pane`; exclusive `panes` (`list`, `mount`, `setPlaced`); own-pane summon; `pane` key; multi-target `configure` for panes | A new kind is a core change. |
| S02 | `setPlaced` placement rule | Enablement and placement are decided once in `PluginLogic` (invariant 6). |
| S03 | `qs.Ui` `FormRow`, `DeviceRow`, `LevelOsd`; `vgs.settings` adopts `FormRow` | Pane rows must match Settings rows (D077) without one-offs. |
| S04 | Manifest `hyprland.options` rendered into the layer when set; capability `hyprland` with `overridden`, `devices`, `foreignBinds` and `switchKeyboardLayout()` on its own top-level `hyprctl` transport | No plugin writes Hyprland configuration (D028). `switchxkblayout` is not a dispatcher, so the `hyprctl dispatch` path cannot carry it. |
| S05 | Capability `monitors`: `~/.config/vgs/monitors.json`, `MonitorLogic.js`, layer `hl.monitor` rules, `outputs`, `overridden` | Session-wide rules must outlive any plugin. |
| S06 | Monitor preview, with a **detached core guard** that restores the captured pre-preview state | Recovery must not depend on the QML event loop, the shell, or the runner (§3.5). |
| S07 | **System steps**: `bin/vgsh-system`, a closed table, core TUI `core/system`, capability `system`, the `system:<step>` action, the `systemSteps` key | Root actions live in the core with stand-in-sudo tests, like D036's `vgsh-sudo-grant`. |
| S22 | Capability `bluetoothAgent` (exclusive): the core owns the BlueZ agent registration through one `bluetoothctl` child per lease | `default-agent` is a session-wide role. D012 puts session roles in the core, as with the polkit agent (D062). |
| S08 | (Validation, not shell core) sandbox device fakes and host-leak guards | No row may reach the host's audio, radios, network, VPN, DDC or hidraw. |

## 3. Per-section design

Every number declares `unit` and every string declares `presets` or `optionsFrom` (D077). Short enums draw as `SegmentedControl`. Rows are `FormRow`s at `row.height`.

### 3.1 Sound — `vgs.sound` (S10)

- **Data.** `Quickshell.Services.Pipewire`: default sink and source, `nodes`, `audio.volume`/`muted`, and streams (`isStream`).
  - Lists come from **snapshots refreshed by a short timer**, never Repeaters bound to the live model. Omarchy records that rebuilding from the removal signal crashed Quickshell's PipeWire service (`shell/plugins/panels/audio/Panel.qml:102-107`), and that crash would take the whole shell.
  - The input meter uses **`PwNodePeakMonitor`**, enabled only while shown (`Panel.qml:580-584`).
- **Default device.** Set `Pipewire.preferredDefaultAudioSink`/`Source`, then move already-playing application streams to the new sink, as Omarchy's `bin/omarchy-audio-output-set-default` does. It moves only streams that carry `application.name`, skips EasyEffects, and never touches filter-chain outputs. This uses `pactl move-sink-input`, an optional requirement offered when missing; without it, new streams follow and playing ones stay.
- **Volume target.** When the default sink is a DSP/filter sink, the slider controls the physical sink behind it (Omarchy `Panel.qml:111-131`, `volumeSink`), so loudness moves and tone does not.
- **Profiles.** Card profiles are deferred.
- **Keys and OSD.** `volume-up`, `volume-down`, `mute`, `mic-mute` on `XF86Audio*` (Q3); `LevelOsd` on the focused screen. Setting `volumeStep` (unit `%`, presets 2/5/10).
- **Failure modes.** PipeWire not ready (unavailable state), no devices, a node gone mid-drag (drag dropped).
- **UI.**
  - Widget: level glyph; scroll changes volume, middle-click mutes.
  - Panel: output slider and mute, output `Select`, input slider and mute, app rows.
  - Pane: Output, Input (with meter) and Applications sections.

### 3.2 Bluetooth — `vgs.bluetooth` (S11, over S22)

- **Data.** `Quickshell.Bluetooth`: the adapters, `enabled`, `discovering`, `blocked`, and `devices` with their paired, connected, trusted, battery and state fields. Omarchy uses the same module (`shell/plugins/panels/bluetooth/Panel.qml:5`).
- **Power: one operation, rfkill is the state** (Omarchy `bin/omarchy-bluetooth-power:1-61`). BlueZ never persists `Powered`, and `bluetoothctl power on` fails while a block is set.
  - **On:** `rfkill unblock bluetooth`, then wait up to 2 s for any controller to report powered. Otherwise set `adapter.enabled = true` and wait again. Otherwise report "Bluetooth did not turn on".
  - **Off:** `rfkill block bluetooth`, which reaches every controller.
  - States are kept apart: soft block, hard block ("Turned off by a hardware switch", no action), BlueZ powered, and service availability (no adapter → `service-bluetooth` step).
  - The widget never writes `adapter.enabled` directly.
- **Discovery.** The service holds **desired** and **confirmed** state separately.
  - Each panel or pane takes a lease tied to its lifetime. A destroyed instance's lease ends with it, as a disposer drained by the instance's teardown.
  - Discovery starts when the first lease opens. After the last lease releases, a stop is retried, bounded to 3 attempts at 1 s, while BlueZ still **confirms** discovering. This covers the race where a stop sent before BlueZ confirmed the start is swallowed (Omarchy `Panel.qml:520-560`).
  - Adapter replacement and service teardown clear the debt.
- **Pairing and inbound requests.** These go through the S22 agent lease, held while the pane shows "Discoverable" or a pairing runs.
  - Prompts: confirm passkey, enter PIN, enter passkey, **display passkey** (type the shown code on the keyboard being paired), authorize service, cancel.
  - The pane answers through a `Dialog`.
- **Requirements.** `bluetoothctl` (core, through S22) and `rfkill` (util-linux).
- **UI.** Widget: off, on or connected, plus a badge for the connected count. Panel: power switch and devices. Pane: power, Discoverable, My Devices (Connect, Rename, Trust, Forget) and Nearby (Pair).

### 3.3 Network — `vgs.network` (S12; hidden and enterprise networks in S23)

- **Data.** `Quickshell.Networking`: devices, `WifiDevice.networks` (signal, security, `known`, `connected`), wired state, `connectivity`, and `connectionFailed` reasons (Omarchy `shell/plugins/panels/network/Panel.qml:68,924-925`).
- **Scanning.** `WifiDevice.scannerEnabled` is shared state. The service owns it through the same lease rule as discovery: on while any panel or pane is open, released on close, and moved when the device is replaced (Omarchy `Panel.qml:297-317`, `setScannerEnabled`).
- **Connect.** Call `connect()` first. If that fails with a credentials reason on a `known` network, **reprompt for the passphrase** and use `connectWithPsk`, because a failed profile stays known and a bare retry repeats the failure (Omarchy `Model.js:360`, `shouldRepromptPassphrase`).
- **Secrets.** A PSK goes from a masked field to NetworkManager, never into argv, status, logs or VGS storage. The NetworkManager secret store as the owner is recorded as a D061 exception in decision record 6.
- **States.** NetworkManager absent, stopped, device unmanaged, access denied, and connectivity limited. Each has its own wording.
  - Absent or stopped reads "NetworkManager isn't running on this computer". It never claims another service manages the network.
  - No action switches stacks (Q6).
- **S23.** Hidden SSID, and WPA-Enterprise (PEAP/MSCHAPv2, TTLS/PAP), through a plugin helper modelled on Omarchy's `enterpriseConnectScript` (`Model.js:335-342`).
  - The password goes on **stdin**.
  - The profile is created under a fresh UUID and **deleted when activation fails**.
  - The helper has offline tests with fake `nmcli`.
- **UI.** Widget: strength, wired or offline. Panel: Wi-Fi switch and networks with an inline password field. Pane: Wi-Fi (networks, Forget, Auto-join, Other Network…), Ethernet, and per-connection Details (`nmcli -t device show`).

### 3.4 VPN — `vgs.vpn` (S13 Tailscale, S14 NetworkManager profiles)

- **Polling.** `tailscale status --json` every 30 s while idle (unit `s`, presets 10/30/60) and every 3 s while a surface is open.
  - **One poll in flight**: no overlapping process (Omarchy `Service.qml:45`, `busy`).
  - A **watchdog** kills a hung poll after 10 s and cannot be postponed by refreshes.
  - Results go to `data` status with peers bounded and the count kept.
- **Exit nodes.** Each peer carries a UI id (`peer.id`) and a separate **CLI target**: DNSName, else HostName, else the first IPv4; a Mullvad node uses its IPv4 (Omarchy `Service.qml:128-134,327-344`). `set --exit-node=<target>`; a raw peer id is never sent.
- **Login.** The auth URL from `tailscale login --timeout 0` opens through `run.detached(["xdg-open", url])`.
- **Setup.** `tailscale` (optional requirement) → Install. Then the `service-tailscaled` and `tailscale-operator` steps (S07): Enable, Allow. Omarchy uses `pkexec` (`Service.qml:349-354`); VGS elevates in a floating TUI (D061).
- **S14: NetworkManager VPN and WireGuard profiles.**
  - Toggle through `nmcli connection up|down id`.
  - "Import WireGuard configuration…" is a plugin TUI using a `gum file` picker and `nmcli connection import type wireguard file <path>`. Its script has an **offline test with fake `gum` and `nmcli`**: cancel, a path with spaces, import refused, and the identity of the new profile. The smoke row covers the launch only.
- **UI.** Widget: connected, disconnected or exit node; hidden with no backend. Pane: account, status, exit node and LAN access, this device, peers, then profiles.

### 3.5 Displays — `vgs.displays` (S15–S17, S24)

**Brightness.** The v1 port; protocol facts in §4.

- **Helper.** `helper/brightness.py`, python3 (already a core requirement), one-shot JSON: `list`, `set <id> <percent>`.
  - Why a helper: QML cannot `ioctl` a hidraw node, and `ddcutil` is an external program.
  - Writes are coalesced latest-wins per device with one run in flight, as v1's bridge did (`brightnessbridge.go:20-33,62-87`).
  - S15 records a startup-plus-write figure, naming its tool and run. A resident mode comes only if the p95 from release to write exceeds 150 ms.
- **Physical identity.** A display is identified by its **USB parent device** (sysfs devpath) plus serial. Its hidraw interfaces are grouped under that parent, which tells apart same-product units even when serials are absent or equal.
- **Mapping to outputs.**
  1. The USB serial equals the Hyprland/EDID `serial` (v1 `vshell_helper.py:10391-10419,10479-10500`).
  2. Otherwise, exactly one physical device of a product matches exactly one output whose model is `ProDisplayXDR` or `StudioDisplay` (`check-display-config-fixtures.js:69-81`).
  3. Otherwise the display is **unassigned** until the user picks with Identify.
- **Assignments.** The schema cannot hold a map, so assignments go in the plugin's own judged state file, `${XDG_STATE_HOME}/vgs/plugins/vgs.displays/assignments.json`. It maps physical identity to an output identifier.
  - A stale entry (device or output gone) is kept, marked stale and never applied.
  - A re-cabled indistinguishable unit asks again.
  - It is not a `configure` key.
- **Behaviour.** Each bar's widget controls its own screen's display (`screens.current`). Brightness keys act on the focused monitor (Omarchy `bin/omarchy-brightness-display:22-88`), or on all displays per `keysTarget`. The flyout shows one slider per display, the bar's own first, plus "Link displays". The OSD appears on the screen that changed.
- **Access: separate states, real probes.**
  - **Apple HID:** the hidraw node opens read-write, or the `apple-displays` step offers the rule.
  - **DDC:** `ddcutil` missing (requirement) / `i2c-dev` module not loaded (step `i2c-dev`: `modprobe i2c-dev` now; the package's `modules-load.d` covers later boots) / nodes present but inaccessible.
    - Arch's `ddcutil` ships `60-ddcutil-i2c.rules` (`uaccess` on display-class i2c) and `modules-load.d/ddcutil.conf` (read from `pacman -Ql ddcutil`), so on Arch the package is the grant.
    - S07 verifies the Fedora and Debian packages. Where one lacks the rule, VGS ships a rule matching ddcutil's own scope; otherwise it reports "DDC access isn't supported on this system".
  - The owner's existing v1 rule probes Ready.
- **Requirements.** `ddcutil` and `brightnessctl`, both optional. `asdcontrol` and its `sudo` call (`bin/omarchy-brightness-display-apple:1-101`) are dropped for direct hidraw, v1's primary path. S21 confirms it on both displays.

**Arrangement and modes (S17, over S05/S06).**

- **Data.** `monitors.outputs`, parsed from `hyprctl -j monitors all` (v1 `vshell_helper.py:13281-13300`). Rules are keyed `desc:<make> <model> <serial>` when a serial exists, else by connector (v1 `:13332-13342`).
- **UI.**
  - `ArrangementCanvas`: drag with snapping, arrow-key nudge, Tab between outputs.
  - `OutputCard` per output: Enabled, Resolution, Refresh, Scale (whole logical pixels only, v1 `:13371`), Rotation and Flipped, VRR, Mirror, Brightness, and an Advanced section with bit depth and colour mode (v1 `:13380-13396`).
  - Identify through `layers`.
- **Preview contract (S06).**
  1. **Capture** the effective state of every affected output from `hyprctl -j monitors all`: mode, position, scale, transform, vrr, disabled, mirror.
  2. **Write the recovery record** `$XDG_RUNTIME_DIR/vgs/monitors-preview.json` with token, deadline, captured state, and Hyprland signature.
  3. **Arm the guard.** `bin/vgsh-monitor-guard` runs in a new session with no inherited lock fd (D053), sleeps until the deadline, and restores unless the record is gone or confirmed.
  4. **Apply** through `hyprctl eval hl.monitor(...)`.
  5. **Verify** the readback.

  Revert and the guard **restore the captured state explicitly** with `eval` and verify it. Reapplying saved rules is not enough: an eval'd mode survives `reload config-only` when no file rule names the output (`runtime-hyprland.md:14`), and on first use there is no saved rule. Restoring the session (the captured state) and the saved document (`monitors.json`, untouched until Keep) are separate operations. Outputs that were unplugged are skipped, and a partial apply restores every touched output. A hung shell (SIGSTOP), a stopped runner or a clean shell exit does not stop the guard. A leftover record at shell start is handed to the guard.
- **Failure modes.** Disabling the last display is refused. A mode can vanish. The layer can be unwired (the core's Connect). A later user line can override (`overridden` → "Set by your Hyprland configuration").

**v1 display rules (S24).** When `~/.config/hypr/vgs/outputs.lua` and v1's exact include lines in `hyprland.lua` exist, the pane offers **"Move v1 display settings into VGS"**: one click, confirmed in a `Dialog`.
- Imports v1's `hl.monitor` rules into `monitors.json` through the judge.
- Removes only v1's exact include lines (`package.loaded["vgs.outputs"] = nil` / `require("vgs.outputs")`, v1 `vshell_helper.py:13465`), after a timestamped backup.
- Leaves every other line alone and reloads.
- Refuses when the lines differ from v1's (it shows the state and changes nothing).

### 3.6 Mouse — `vgs.mouse` (S18)

- **Settings.** Schema settings rendered by S04 as `hl.config({ input = {...} })`, only when the user set them; untouched values leave Hyprland and the user's lines alone. Omarchy has the user edit `~/.config/hypr/input.lua` (`config/hypr/input.lua:4-45`, `default/hypr/input.lua:50-80`).
  - Pointer: `sensitivity` (−1…1, step 0.05, unit `×`), `accelProfile`, `naturalScroll`, `leftHanded`, `scrollFactor` (unit `×`).
  - Touchpad: `tapToClick`, `naturalScroll`, `disableWhileTyping`, `clickMethod`, `scrollFactor`, and touchpad `enabled` (`hl.device`).
- **Data.** The device list comes from `shell.hyprland.devices`, not the plugin's own `hyprctl`.
- **UI.** Widget unplaced by default (Q2); its flyout has speed, natural scroll and the touchpad switch. Pane: Pointer, Touchpad (when present), Devices, a try-it area, and per-row "Overridden by your Hyprland config" from `shell.hyprland.overridden`.

### 3.7 Keyboard — `vgs.keyboard` (S19)

- **Data.** The active layout from Hyprland's `activelayout` event (`Quickshell.Hyprland`, import allowed). Layout names from `/usr/share/X11/xkb/rules/evdev.xml`, parsed once into bounded `data`.
- **Settings** (S04):
  - `layouts`: presets are the system layout and Custom…
  - `variants`
  - `options`: presets `caps:escape`, `ctrl:swapcaps`, `compose:ralt`, `grp:alt_shift_toggle`, Custom…
  - `repeatRate` (unit `/s`), `repeatDelay` (unit `ms`), `numlockByDefault`.
- **Switching.** `shell.hyprland.switchKeyboardLayout("next"|"prev"|index)`.
- **UI.**
  - Widget: the active layout code; click switches; hidden with one layout.
  - Pane: an Input Sources ordered list editor (D057 does not cover multi-select), Key Repeat with a test field, Modifier Options, and "Keyboard Shortcuts…" through `run`.

## 4. v1 brightness protocol facts (port reference)

All paths are under `/home/method/dev/.worktrees/vgs/v1`. These lines were read directly in this session (`bin/vshell_helper.py:340-358,9866-9896`).

| Fact | Value | Source |
|---|---|---|
| Apple vendor id | `05ac` | `bin/vshell_helper.py:343` |
| Pro Display XDR | product `9243`, raw `400`–`50000` | `bin/vshell_helper.py:349-352`; `third_party/asdcontrol/asdcontrol.cpp:63-64` |
| Studio Display | product `1114`, raw `400`–`60000` | same |
| Raw unit | centi-nits from the descriptor's logical range; interface number varies, so probe | `bin/vshell_helper.py:345-348` |
| Probe ceiling | `60000` | `bin/vshell_helper.py:354-356` |
| HID usage | Monitor page `0x82`, usage `0x0001` | `asdcontrol.cpp:53-56` |
| Report | id `1`, length `7`; bytes 1..4 raw, unsigned **little-endian** | `bin/vshell_helper.py:9866-9894` |
| Read / write ioctl | `HIDIOCGFEATURE(7)` = `_IOC(R\|W,'H',0x07,7)`; `HIDIOCSFEATURE(7)` = `_IOC(R\|W,'H',0x06,7)` | `bin/vshell_helper.py:9871-9879` |
| Enumeration | `/dev/hidraw*` from sysfs; zeroed report-1 probe; in-range only; prefers Monitor/VESA descriptor | `bin/vshell_helper.py:9897-9974` |
| Percent → raw | `raw = min + percent × (max − min) / 100`, clamped; XDR 100 % = 50000 | `asdcontrol.cpp:585-590`; `bin/vshell_helper.py:10037-10052`; `scripts/check-brightness.py:192` |
| Fallback | `asdcontrol` over `/dev/hiddev*` (**not ported**; S21 confirms hidraw on both displays) | `bin/vshell_helper.py:9976-10017` |
| Output match | USB serial == EDID serial | `bin/vshell_helper.py:10391-10419,10479-10500` |
| DDC | `ddcutil detect` cached 30 s; `--bus N getvcp 10 --brief`; `--bus N setvcp 10 V`; `V = round(p/100 × max)` | `bin/vshell_helper.py:10152-10282` |
| Backlight | `brightnessctl -m -c backlight`; `-d DEV set N%` | `bin/vshell_helper.py:10317-10347,10637-10647` |
| Bridge | 8 s timeout, 250 ms settle, latest-wins per device | `backend/internal/services/brightnessbridge/brightnessbridge.go:20-33,59-87` |
| udev rule | hidraw + hiddev lines for `05ac:1114`/`05ac:9243`, `TAG+="uaccess", MODE="0660", GROUP="users"`; at `/etc/udev/rules.d/60-vshell-apple-displays.rules` | `config/vshell/udev/60-vshell-apple-displays.rules:1-17`; `bin/vshell_helper.py:10769,10787-10834` |

**v2 rule.** `config/system/udev/60-vgs-apple-displays.rules`: the two `hidraw` lines with `TAG+="uaccess"` only.
- No `hiddev`, since `asdcontrol` is not ported.
- No `GROUP="users"`, which would reach SSH and other-seat sessions.
- `60-` sorts ahead of `73-seat-late.rules`, where uaccess is applied.

## 5. Validation strategy

**Principles.**
- No real authentication. The harness sentinels for `sudo`, `doas`, `run0`, `pkexec`, `su`, `loginctl` and `secret-tool` stay. A row that needs a stand-in uses `sentinel_stand_over`/`sentinel_restore` (`harness.sh:233-300`), never a global success stub, and `rows/auth-sentinel.sh` still reads the log empty.
- No real hardware writes. QML runs only in the nested sandbox.
- Every item carries its row and offline tests registered in `scripts/validate` with must-fail controls.

**Sandbox device fakes (S08).**
- **Buses.** `python-dbusmock` bluez5 and networkmanager templates on the sandbox system bus (`harness.sh:436-490`). A Gio fake covers any member Quickshell calls that a template lacks.
- **Audio.** A private `pipewire` + `wireplumber` with an **explicit null-device-only configuration**: ALSA, BlueZ, libcamera and V4L2 monitors disabled, two null sinks, one null source and a filter-chain sink for the DSP case. The row asserts from `/proc/<pid>/fd` that neither process holds `/dev/snd/*` or `/dev/video*`.
- **Stand-ins** recording argv and answering from fixtures, placed in the shell's shim directory ahead of the host PATH (`harness.sh:333`): `rfkill` (with a fake soft/hard state file, so no row reaches `/dev/rfkill`), `tailscale`, `ddcutil`, `brightnessctl`, `nmcli`, `pactl`, `bluetoothctl` (transcript replay), `systemctl`, `udevadm`, `modprobe`, `xdg-open`, `gum`.
- **Hardware.** The brightness helper takes `VGS_SYSFS_ROOT`/`VGS_DEV_ROOT` and an **injected ioctl seam** (`VGS_HID_FAKE=<socket>`, served by a fixture process). A FIFO cannot answer `HIDIOCGFEATURE`.
- **Guards.** A row aborts (exit 77) when the shell's system bus, `PIPEWIRE_RUNTIME_DIR`, `VGS_DEV_ROOT` or PATH shim is outside the sandbox. A control copy that leaks each one must turn the guard red.
- **Isolation.** The new plugin ids start in the harness's `disabledPlugins` (`harness.sh:722`), so existing rows and budgets do not move.

**Rows.**
- Core: `panes.sh`, `placement.sh`, `hyprland-options.sh`, `monitors.sh`, `system-steps.sh`, `bluetooth-agent.sh`.
- Plugins: `system-window.sh`, `sound.sh`, `bluetooth.sh`, `network.sh`, `vpn.sh`, `displays.sh`, `mouse.sh`, `keyboard.sh`.

Each row reads back from instances and probes, walks a keyboard-only path (D068) and carries a must-fail control. The specific proofs the review asked for:
- Settings: a value edited in one interface reads the same in all four.
- Bluetooth power: unblock → confirmed power, persistent off, hard block, failure.
- Discovery: a start confirmed only after the last release still gets stopped.
- Wi-Fi: wrong saved password → reprompt.
- Sound: an **already-playing stream** follows the new default; the DSP-sink slider moves the physical sink.
- Monitors: guard recovery with the shell stopped by SIGSTOP, the runner stopped, and a kill injected between each of capture, record, arm, apply and verify; first use with no `monitors.json`.

**Offline tests.**
- `test-plugin-logic.js`: pane, `panes`, multi-target configure, `setPlaced`, `hyprland.options`, `systemSteps`.
- `test-hyprland-layer.js`, `test-monitor-logic.js`, `test-vgsh-monitor-guard.sh`.
- `test-vgsh-system.sh`: stand-in sudo, NixOS rows.
- `test-bluetooth-agent.js`: transcripts, including display-passkey and inbound requests.
- `test-displays-brightness.py`: bytes, ioctls, identity, mapping, coalescing.
- `test-network-enterprise.sh`, `test-vpn-import.sh`, plus one `test-<plugin>-logic.js` per plugin.

**Hardware acceptance (S21, owner).** On the owner's desk with the XDR and the Studio Display: the hidraw path on both displays, per-display sliders, focused-display keys, each bar's widget, Identify, hotplug, the v1 rule reading Ready, and preview revert and Keep.

## 6. Ordered items

`ext:` marks prerequisites outside this plan.

| Key | Item | Est | Blocked by |
|---|---|---|---|
| S02 | core: `setPlaced` placement rule | 2 | — |
| S01 | core: `pane` kind, `panes` (`list`/`mount`/`setPlaced`), own-pane summon, multi-target pane configure | 4 | S02; ext VGS-597 |
| S03 | design: `FormRow`, `DeviceRow`, `LevelOsd`; Settings adopts `FormRow` | 3 | ext VGS-686, VGS-597 |
| S04 | core: `hyprland.options` + capability `hyprland` (`overridden`, `devices`, `foreignBinds`, `switchKeyboardLayout` transport) | 4 | — |
| S05 | core: `monitors` capability, `monitors.json`, layer rules | 4 | S04 |
| S06 | core: monitor preview with a detached guard restoring captured state | 4 | S05 |
| S07 | core: system steps with sudo-grant protections | 4 | ext VGS-683 |
| S22 | core: `bluetoothAgent` exclusive capability | 3 | S07 |
| S08 | validation: device fakes, null-only audio, rfkill/xdg-open stand-ins, leak guards | 4 | — |
| S09 | plugin `vgs.system` | 3 | S01, S03 |
| S10 | plugin `vgs.sound` | 4 | S03, S08, S09 |
| S11 | plugin `vgs.bluetooth` | 4 | S03, S07, S08, S09, S22 |
| S12 | plugin `vgs.network` | 4 | S03, S08, S09 |
| S23 | `vgs.network`: hidden and enterprise Wi-Fi | 2 | S12 |
| S13 | plugin `vgs.vpn`: Tailscale | 4 | S03, S07, S08, S09 |
| S14 | `vgs.vpn`: NetworkManager VPN and WireGuard profiles and import | 2 | S12, S13 |
| S15 | `vgs.displays`: brightness helper, identity, mapping | 3 | S08 |
| S16 | `vgs.displays`: per-screen widget, flyout, keys, OSD, access, assignments | 4 | S03, S07, S09, S15 |
| S17 | `vgs.displays`: arrangement and output pane with preview | 4 | S06, S16 |
| S24 | `vgs.displays`: one-click move of v1 display settings | 2 | S17 |
| S18 | plugin `vgs.mouse` | 3 | S03, S04, S08, S09 |
| S19 | plugin `vgs.keyboard` | 3 | S03, S04, S08, S09 |
| S20 | integration: default placement, docs, READMEs, full-family budget | 2 | S10–S14, S16–S19, S23, S24 |
| S21 | owner: hardware acceptance (agent:human) | 1 | S16, S17 |

**Lanes.**
- A: S02 → S01 → S09.
- B: S04 → S05 → S06.
- C: S07 → S22.
- D: S08, with S15 started on offline tests at once.
- E: S03.

The sections fan out after S09 and S08.

## 7. Decision records needed (unnumbered; D078 is next free)

1. **System sections are `pane` plugins mounted by the one `panes` holder; panes write every settings entry their plugin reads** (S01; refines D013, D032, D044).
2. **Hyprland options and monitor rules are rendered from data and written only when set. Monitor previews are guarded by a detached core process that restores the captured state** (S04–S06; refines D028, D053).
3. **Privileged one-time setup is a closed core table of system steps** (S07; refines D036, D061). On NixOS the state reads "Needs your NixOS configuration", with the snippet behind Show command, as `vgsh sudo` does (D036).
4. **Brightness uses a one-shot plugin helper over hidraw, DDC and backlight, with a uaccess-only rule** (S15; the D010 helper justification).
5. **The Bluetooth agent is a core-lent exclusive capability over `bluetoothctl`, held per lease** (S22; refines D012; differs from Omarchy's always-on `bt-agent` unit because VGS installs no user unit by default).
6. **Network is NetworkManager-only, VGS never switches stacks, and Wi-Fi secrets live in NetworkManager's store** (S12/S23; a D061 exception).

## 8. Doc updates forced

- `overview.md`, `plugins.md`, `plugin-manifest.md`, `capabilities.md`, `surfaces.md`.
- `hyprland.md`, `runtime-hyprland.md`.
- `manager.md`, `settings-window.md`, `status-actions.md`, `tui-sudo.md` (sibling).
- `components.md`, `design-system.md`.
- `validation-smoke-host.md`, `topics.md`.
- New `system.md` and `displays.md`.
- The vgs-plugin skill (`SKILL.md`, `api.md`, new `templates/Pane.qml`).
- `INDEX.md` with the six records.
- The README and `shots.tsv`.

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| A sandbox row reaches host radios, audio, DDC or hidraw | S08 null-only audio with an fd assertion, `rfkill` and other stand-ins, the ioctl seam, and leak guards with must-fail controls. Plugins start disabled. |
| `python-dbusmock` templates lack what Quickshell calls | Each template is checked first, with a Gio fake for gaps. A row that cannot measure exits 77, never a silent pass. |
| A monitor preview leaves an unusable screen | S06: capture, record, arm the guard, then apply. The guard runs outside the shell and the runner and restores captured values explicitly, with fault-injection tests at each step. |
| A native crash in a Quickshell service (PipeWire Repeater) takes the whole shell | Snapshot lists (Omarchy `audio/Panel.qml:102-107`). D069 relaunches. The section split does not isolate crashes, and the plan does not claim it does. |
| Bluetooth agent coexistence (blueman, `bt-agent`) | S22 registers only per lease, waits for BlueZ's acknowledgement, releases on dispose, and records BlueZ's default-agent fallback from its source in the decision record. It refuses when another agent holds the default, rather than stealing it silently. |
| A user's Hyprland lines override VGS (v1 `outputs.lua`, `input.lua`, media binds) | `overridden` and `foreignBinds` readbacks show per row. Keys offers one-click "Use my binding" (unbinds VGS's key). S24 moves v1 display rules with confirmation. |
| `ddcutil` is slow or hangs | One run per bus, latest-wins, 8 s timeout, reads on open only. |
| A hidraw write fails on one Apple model where v1 relied on `asdcontrol` | S21 checks both displays. If one fails, a follow-up item restores a scoped hiddev path. |
| The status ceiling for layouts or peers | Bounded lists with the count kept. |
| In-flight D068/D075–D077 change the APIs used here | ext prerequisites per item. |

**Rollback.** Each item is its own commit series. A section is disabled with one `disabledPlugins` entry. Core items have no consumers until S09, so revert consumers first.

**TPM handoff.** Needed: 24 items, three external prerequisites, one owner-gated and one owner hardware item (§11).

## 10. Open questions for the owner (recommended defaults apply unless overridden)

1. **Q1 — Host and shortcut.** *Default:* a separate `vgs.system` window (option D) with a "Shell & Plugins" row; `SUPER+COMMA`, unbound on conflict. Option C (`vgs.settings` hosts panes) is the same contract with another host and can follow later.
2. **Q2 — Default bar placement** (fresh installs). *Default:* Sound, Network, Bluetooth, Displays, Keyboard and VPN, each hiding when it has nothing to show; Mouse unplaced. Existing layouts are unchanged, and "Show in bar" adds a widget.
3. **Q3 — Media and brightness keys.** *Default:* VGS binds `XF86Audio*` and `XF86MonBrightness*`. Where `foreignBinds` shows the user's own bind on the same key, the Keys row offers one click, "Use my binding". VGS never edits the user's file.
4. **Q4 — udev delivery.** *Default:* a one-click system step for every install. The Arch and Fedora packages ship no system files yet, keeping one relocatable tree (D040).
5. **Q5 — v1 display rules.** *Default (changed by the review):* offer the one-click, confirmed "Move v1 display settings into VGS" (S24); never delete user lines that are not v1's exact include.
6. **Q6 — Network backend.** *Default:* NetworkManager only; other stacks see an explicit read-only state and no offer to switch.

## 11. Handoff

**Implementer, per item:** "Implement `<key>` from `docs/plans/v2-system-plan.md`. Load the code-quality and vgs-plugin skills. Read the item's References, §2 and its §3 section. Land the row and offline tests its Acceptance names in the same change. Run `scripts/validate` once, then `--changed` for fix rounds. Never touch the live session or real devices. Write the decision record the item names."

**TPM**, for the caller to pass on: "File the 24 items in `docs/plans/v2-system-issues.json` under one VGS project 'System settings'.
- Use the given priorities, estimates and labels, with blocking relations from `blocked_by`.
- Add VGS-597 → S01, S03 and S09; VGS-686 → S03; VGS-683 → S07.
- Mark S21 `agent:human` + `hardware-blocked`, and S09 `owner-gated` until Q1–Q3 are answered.
- Cycle order: S02, S01, S03–S08, S22, then S09, then the sections."
