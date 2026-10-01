# System steps

Covers: bin/vgsh-system, config/system/**, shell/Core/SystemSteps.qml, scripts/test-vgsh-system.sh, scripts/smoke/rows/system-steps.sh, scripts/smoke/fixtures/plugins/acme.system/**

`vgsh system` is the core's closed table of one-time root setup that a plugin's status action can ask for: [D081](../decisions/D081-system-steps-closed-core-table.md). `bin/vgsh-system` holds the table, and its header states each step's commands, each state, output line, refusal key and exit code. The sudo grant beside it is [tui-sudo.md](tui-sudo.md).

## The table

| Step | Grants | Probe |
|---|---|---|
| `apple-displays` | the uaccess rule `config/system/udev/60-vgs-apple-displays.rules` in `/etc/udev/rules.d` | each hidraw node whose sysfs device's `HID_ID` names `05ac:1114` or `05ac:9243` opens read-write |
| `i2c-dev` | the `i2c-dev` module, loaded now | once `/sys/class/i2c-dev` exists, a node of a display-class i2c adapter opens read-write |
| `service-bluetooth`, `service-tailscaled` | the unit, enabled and started | `systemctl is-active` |
| `tailscale-operator` | the caller's own login name as the operator | `tailscale get operator` names the caller |

- The rule holds the two `hidraw` lines with `TAG+="uaccess"` alone: no `hiddev`, since `asdcontrol` is not ported, and no `GROUP` or `MODE`, which would reach SSH and other-seat sessions. `60-` sorts ahead of `73-seat-late.rules`, which applies the tag. The trigger's `--settle` waits for the events it queued, so the probe after the commands reads the new access (`udevadm(8)`, systemd 262).
- Display class is an ancestor's sysfs `class` starting `0x03`, the match ddcutil's own rule makes. VGS ships no i2c rule: the Arch, Debian and Fedora ddcutil packages each ship `60-ddcutil-i2c.rules` and `modules-load.d/ddcutil.conf`, so a loaded module whose display nodes stay closed reads `denied`.
- `tailscale get <setting>` prints that one preference, named by `tailscale set`'s flag ([Tailscale CLI reference](https://tailscale.com/docs/reference/tailscale-cli), § get).
- A probe reads real access, never a file's presence, so a rule VGS did not write, v1's `60-vshell-apple-displays.rules` included, reads `ready` when it grants the access. A probe that cannot answer reads `unknown`, never `ready`. Another user's operator reads `denied`, so `apply` never takes it over.

## Apply and undo

- `apply <step>` acts only on a `needed` step. It prints each exact root command, every program by its path, asks one question that `VGS_TUI_UNATTENDED` never answers, and only after a yes starts one `vgs_tui_sudo_session` ([tui.md](tui.md)). It then holds a flock on `/var/lib/vgs/system`, plans again and refuses a plan that differs from the one shown, writes the step's record, runs the commands and probes again.
- The record, `/var/lib/vgs/system/<step>`, is root's and system-wide, like the change it describes. It is written before the commands, so a command that fails partway leaves on record what it may have changed. It names the caller's uid and only what the step changed.
- `undo <step>` reverts only that. It removes the rule only while its bytes hash to the record, unloads the module and stops the unit only in the boot that changed them, disables only a unit VGS enabled, resets the operator only while it still names the recorded user, and refuses another uid's record.
- A destination that is a symbolic link is refused, and a rule file whose bytes no VGS record hashes to is refused as foreign, never overwritten. A directory the commands write into and a record must be root's and writable by no one else.
- Every system path derives from the script's `prefix=` line, empty in production, and every command resolves in the system directories alone, the list [tui-sudo.md](tui-sudo.md) names.
- On NixOS, detected through the package-manager table when a step reads `needed`, the step reads `nixos`: "Needs your NixOS configuration". `apply` prints the configuration snippet and `undo` reports `skipped=nixos-config`; neither writes or runs sudo. A detection that fails reads such a step `unknown`.

## In the shell

- A manifest's `systemSteps` names steps of the table and needs capability `system`; a status action `{ label, system: "<step>" }` names one of them. `PluginLogic.systemStepsError` and `statusActionError` judge both against `PluginLogic.SYSTEM_STEPS`, which `scripts/test-vgsh-system.sh` reads against the script's own table.
- `SystemSteps`, in `Capabilities`, runs `bin/vgsh-system status --json`, one at a time, while a plugin holds `system`: once when the first holder arrives and again after each `core/system` run the manager opened ends. `PluginLogic.systemReport` judges the report; a run that gives none reads every step `unknown`, reason `probe-failed`, and logs `system: probe=...`. The lending record lists the steps under `system`.
- `shell.system.state` lends the plugin's declared steps, each `{ state, reason }`, and `shell.system.revision` rises when a report changes one. The plugin's service publishes a step's state with `action: true` while it reads `needed` or `nixos`, and the manager's `act` opens the core TUI `core/system` with `apply <step>` ([status-actions.md](status-actions.md)).

## Invariants

1. A step runs only from the closed table, only after its commands were shown and one question answered yes, and only the commands shown; a destination VGS did not write is never overwritten, `undo` reverts only VGS's own recorded changes for the caller's own uid, and NixOS writes nothing. Enforced by `scripts/test-vgsh-system.sh` under a temporary prefix with stand-in `sudo`, `gum`, `stat`, `udevadm`, `systemctl`, `modprobe` and `tailscale`, with copies that write before the question, accept a step outside the table, read a file's presence for access, disable a unit VGS did not enable, overwrite a foreign rule, follow a symbolic link, answer unattended, run a changed plan, undo another uid's record or another user's operator, stop a unit an earlier boot started, write or ask on NixOS, and read an undetected system as needed.
2. A manifest names only steps of the table, an action only a step its manifest names, and a failed probe reads every step unknown. Enforced by `scripts/test-plugin-logic.js` and `scripts/test-plugin-status.js`, a control per rule.
3. Allow opens `core/system` with the step in its argv, the run's end probes again, and no step reaches the host's devices, units or sudo. Enforced in the nested sandbox by `scripts/smoke/rows/system-steps.sh`, over a prefix tree whose sudo is the harness's sentinel, stood over and restored, and by `scripts/smoke/rows/auth-sentinel.sh`.

## Omarchy

Omarchy enables services with `sudo` in `omarchy-install-service-tailscale` and authorizes the operator through `pkexec`; VGS elevates in the floating TUI and differs where [D081](../decisions/D081-system-steps-closed-core-table.md) states.
