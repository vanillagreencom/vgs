# Smoke device fakes

Covers: scripts/smoke/devices.sh, scripts/smoke/fixtures/devices/, scripts/smoke/rows/device-fakes.sh, scripts/smoke/fixtures/plugins/acme.devices/

The fakes a System row reads instead of the host's audio, radios, network, VPN, DDC and hidraw, the stand-ins for the commands that reach them, and the guard a device row starts behind. The nested sandbox shares the host's devices and files, so a row that reached one would change the owner's machine. What else no row may reach on the host is in [validation-smoke-host.md](validation-smoke-host.md); the Quickshell facts the fakes satisfy are in [runtime-devices.md](runtime-devices.md).

## Contract

- `scripts/smoke/devices.sh`, sourced by the harness, owns every fake, stand-in and guard. A System row builds on its helpers and adds no fake of its own: its header states each helper's arguments and answers.
- Every sandbox process gets `devices_env_words`: `PIPEWIRE_RUNTIME_DIR` is the sandbox runtime dir, and `VGS_DEV_ROOT`, `VGS_SYSFS_ROOT` and `VGS_HID_FAKE` name the brightness helper's device tree, sysfs tree and feature-report socket inside the sandbox.
- `devices_up` starts the fakes once per run, on the first row that calls it, and leaves them up until the teardown. Quickshell's Bluetooth, Networking and Pipewire singletons look for their service once, when a plugin first reads them, so a row calls it before it enables a plugin that reads one.
- `devices_ready ROW` is a device row's first line. It runs `devices_up`, then `devices_guard` over the running shell. A missing prerequisite or a leak records the row as not measured through `not_measured` in `scripts/smoke/verdict.sh` and the row returns; every other row still runs, and a run with no failure and a not-measured row exits 77 with `rows=<row>:<reason>`. A fake that fails to start, an empty shell pid, or an unreadable shell environment fails the row.
- The smoke set's user file lists the System family's ids, `vgs.system`, `vgs.sound`, `vgs.bluetooth`, `vgs.network`, `vgs.vpn`, `vgs.displays`, `vgs.mouse` and `vgs.keyboard`, in `disabledPlugins`, so a section's own row enables it over the fakes and no earlier row, lending record or first-bar reading counts it. The configuration keeps an id no plugin has, and `vgsh plugin list` reports it as unknown. The default set lists none of them: it starts every first-party plugin, as a live session does.

## Fakes

- Buses: python-dbusmock's `bluez5` and `networkmanager` templates on the sandbox system bus. `fixtures/devices/world.py` plants one adapter, `hci0`, with one paired, bonded and connected device, and one Wi-Fi device, `wlan0`, that sees one access point. It fills the members Quickshell reads that the templates lack through dbusmock's own `org.freedesktop.DBus.Mock` interface, `AddProperty` and `AddMethod`, so no second fake owns an object and no Gio fake is needed.
- Audio: a private `pipewire` reads `fixtures/devices/pipewire/` alone through `PIPEWIRE_CONFIG_DIR`, so no host fragment reaches it. Its SPA libraries hold no ALSA, BlueZ, V4L2 or libcamera plugin. Its nodes are two null sinks, a filter-chain sink in front of the speakers for the DSP case, and one `audiotestsrc` source. A null sink given `media.class` `Audio/Source` never activates in WirePlumber 0.5.17, and Quickshell lists only that class as a source. A private `wireplumber` runs the profile `vgs-smoke` from `fixtures/devices/wireplumber/`, copied into the sandbox HOME, with every hardware monitor, device reservation, the portal, logind and saved state off.
- HID: `fixtures/devices/hid-fake.py` serves `VGS_HID_FAKE`, since a FIFO cannot answer `HIDIOCGFEATURE`. Its header holds the protocol: one JSON line per ioctl, `HIDIOCGFEATURE` and `HIDIOCSFEATURE` of any length, and `ENOENT`, `ENOTTY`, `EINVAL` and `EIO` for the rest. It plants each device of `hid-world.json`, a Pro Display XDR by default, as an empty `VGS_DEV_ROOT/<name>` and a `VGS_SYSFS_ROOT/class/hidraw/<name>/device/uevent`, and logs every request.

## Stand-ins

- `rfkill`, `tailscale`, `ddcutil`, `brightnessctl`, `nmcli`, `pactl`, `bluetoothctl`, `systemctl`, `udevadm`, `modprobe`, `xdg-open` and `gum` stand in the shell's own PATH directory for the whole run, written before the first shell starts. Each runs `fixtures/devices/stand-in.py`, which records the argv and never runs the host's command.
- `rfkill` keeps its radios in the sandbox's `rfkill.json`, a Bluetooth and a Wi-Fi radio unblocked at start. Block, unblock and toggle accept one or more ids, types, aliases or `all`, and change the soft state alone; a hard block never changes.
- `bluetoothctl` with no argument, or with exactly `--agent <capability>` as the core's Bluetooth agent starts it, replays the transcript `device_transcript` plants and ends with status 1 on a line it does not expect. Past the transcript's last step it records each stdin line, then `{"eof": true}` when its stdin ends.
- Every other call answers from a reply `device_reply` planted for its exact argv. A later reply for the same argv replaces the earlier reply. `device_reply_clear NAME` removes one stand-in's planted replies. A call no reply answers prints `stand-in: name=<name> reply=none argv=<json>` on stderr and exits 1.
- A row that needs a stand-in to answer its own way stands over it with `sentinel_stand_over` and puts it back with `sentinel_restore`, as `scripts/smoke/rows/agent-warden.sh` does for `systemctl`. `scripts/smoke/rows/auth-sentinel.sh` reads that list empty at the end.

## Guards

`devices_guard PID` reads a process's environment from `/proc/<pid>/environ` and answers `inside` or the first rule it breaks, as `leak=<rule> value=<value>`. It exits non-zero with the unreadable pid on stderr when `/proc/<pid>/environ` cannot be read:

| Rule | Holds when |
|---|---|
| `system-bus` | `DBUS_SYSTEM_BUS_ADDRESS` is the sandbox's system bus |
| `pipewire-runtime` | `PIPEWIRE_RUNTIME_DIR` lies in the sandbox runtime dir |
| `hardware-root` | `VGS_DEV_ROOT`, `VGS_SYSFS_ROOT` and `VGS_HID_FAKE` each lie in the sandbox or its runtime dir |
| `path-shim` | every stand-in name resolves on its PATH to the shell's stand-in directory |

An unset variable breaks its rule.

## Validation

`scripts/smoke/rows/device-fakes.sh` reads each fake through the shell with the `acme.devices` fixture, from `/proc/<pid>/fd` that neither the sandbox PipeWire nor its WirePlumber holds `/dev/snd/*` or `/dev/video*` after WirePlumber reports its defaults, that a fixture `rfkill block` changes the stand-in's state file alone while the host's `/sys/class/rfkill` reads as before, and the stand-ins' and the HID fake's answers. Its controls: each guard rule turns red on a process given the shell's environment words with the host's system bus, the host's PipeWire dir, `/dev`, an unset HID fake socket or a PATH that finds the host's `rfkill` first after them; `devices_ready` maps a guard leak and a missing dbusmock import to not measured, and fails an empty or exited shell pid; the fd reader finds the `/dev/null` PipeWire holds; a stand-in copy that drops its state write leaves the radio unblocked; `scripts/test-smoke-verdict.sh` holds the not-measured verdict's controls.
