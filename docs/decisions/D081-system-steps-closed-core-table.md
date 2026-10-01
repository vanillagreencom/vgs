# D081: Privileged one-time setup is a closed core table of system steps

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: [docs/plans/v2-system-plan.md](../plans/v2-system-plan.md) §§ 2.6, 3.4, 3.5, 4, 7; review dispositions M12, M14 and B3 in [docs/plans/v2-system-plan-review.md](../plans/v2-system-plan-review.md)

**Refines**: [D036](D036-time-boxed-passwordless-sudo-grant.md), [D061](D061-no-manual-commands.md)

**Context**: The System sections need root once: a udev rule so brightness reaches an Apple display's hidraw node, the `i2c-dev` module for DDC, the Bluetooth and tailscaled units, and the Tailscale operator. [D061](D061-no-manual-commands.md) forbids telling the user to run a command, and [D075](D075-consumer-features-need-no-developer-setup.md) makes these consumer features. A plugin that ran its own root commands would hold system-wide privilege no plugin may own ([D003](D003-everything-is-a-plugin.md), [D036](D036-time-boxed-passwordless-sudo-grant.md)).

**Decision**: The core owns a closed table of system steps in one script, `bin/vgsh-system`, reached as `vgsh system status|apply|undo`.

- The table: `apple-displays` installs `config/system/udev/60-vgs-apple-displays.rules`, the two `hidraw` lines for `05ac:1114` and `05ac:9243` with `TAG+="uaccess"` alone, then reloads udev and triggers hidraw; `i2c-dev` runs `modprobe i2c-dev`, then `udevadm settle`; `service-bluetooth` and `service-tailscaled` run `systemctl enable --now`; `tailscale-operator` runs `tailscale set --operator=<the caller's login name>`. A step outside the table is refused as a bad invocation.
- Probes read real access: the Apple hidraw node opens read-write, a display-class i2c node opens read-write, the unit is active, `tailscale get operator` names the caller. A state is `ready`, `needed`, `denied`, `absent`, `unknown` or `nixos`, and a probe that cannot answer reads `unknown`.
- `apply` acts only on a `needed` step. It prints every root command, asks one `gum confirm` that `VGS_TUI_UNATTENDED` never answers, and only then starts one `vgs_tui_sudo_session`. Under a flock on the record directory it plans again, refuses a plan that changed, writes the record, runs the commands and probes again.
- The protections of `vgsh-sudo-grant` carry over: one `prefix=` line from which every system path derives, `PATH` pinned to the system directories, root refused so the steps act for the caller's own account, destinations from the table only and never a symbolic link, writes serialized under flock, and a rule file VGS did not write refused, never overwritten.
- Each step's record is `/var/lib/vgs/system/<step>`, root's, written through sudo before the step's commands. It names the caller's uid and what the step changed. `undo` reverts only that, for the uid that applied it.
- On NixOS a `needed` step reads `nixos`; `apply` prints the configuration snippet and `undo` reports `skipped=nixos-config`, and neither writes or runs sudo, as [D036](D036-time-boxed-passwordless-sudo-grant.md) does.
- A manifest names its steps in `systemSteps`, which needs capability `system`. The capability lends `state`, the declared steps' probed states from one core owner that runs `vgsh-system status --json`, and `revision`, raised when a report changes. A status action `{ label, system: "<step>" }`, a step the manifest declares, is run by the `manager` capability's `act`, which opens the core TUI `core/system` with `apply <step>`; the owner probes again when the run ends and after each plugin scan.

[tui-system.md](../architecture/tui-system.md) holds the contract.

**Rationale**:

- One closed table in the core keeps every root command reviewable in one file, tested with stand-in sudo, and out of every plugin's reach. A plugin can only name a step.
- A real access probe answers what the user needs. A rule file's presence proves nothing: v1's rule grants the same access under another name, and a rule udev never applied grants none. The owner's existing v1 rule therefore reads ready and needs no migration.
- The record lives where the change lives. The rule, the module and the units are system-wide, so a root-owned record under `/var/lib/vgs` describes them for every account, and no user-writable file can steer `undo` into disabling a unit or removing a rule VGS never touched. It is written before the commands, so a step that fails partway is still VGS's to undo.
- The flock is held on the record directory itself, after its creation through sudo: every account can open it read-only, so two runs from two accounts serialize, and no lock file in a world-writable directory is needed.
- Commands are named by their resolved paths in the system directories, so the command shown is the command sudo runs, whatever sudo's own `secure_path` holds.
- A unit enabled `--now` is recorded as enabled only when it was not enabled, and as started with the boot id, so `undo` never disables a unit the system enabled and never stops a unit after a reboot started it for another reason. The module follows the same boot rule, since the ddcutil package's `modules-load.d` loads it at every later boot.
- An operator another user set reads `denied`: setting the caller over it would take tailscaled away from that user.

## ddcutil packaging

VGS ships no i2c rule. Checked on 2026-09-30, the ddcutil packages of Arch (`pacman -Ql ddcutil`), Debian trixie (the packages.debian.org file list) and Fedora rawhide (the `%files` of src.fedoraproject.org's `ddcutil.spec`) all ship `/usr/lib/udev/rules.d/60-ddcutil-i2c.rules`, `SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", ATTRS{class}=="0x03*", TAG+="uaccess"`, and `/usr/lib/modules-load.d/ddcutil.conf`, `i2c-dev`. The package is the grant; the `i2c-dev` step only loads the module now, and a loaded module whose display nodes stay closed reads `denied`.

## Where VGS differs from Omarchy

| Omarchy | VGS | Why |
|---|---|---|
| `omarchy-install-service-tailscale` runs `sudo systemctl enable --now tailscaled.service` and `sudo tailscale set --operator="$USER"` in one install script. | Two steps, `service-tailscaled` and `tailscale-operator`, each offered by its own status entry. | A section shows each missing grant and offers only that one; the operator needs tailscaled running. |
| The Tailscale panel authorizes the operator through `pkexec tailscale set --operator=<user>` (`Service.qml` `authorizeTailscaleOperator`). | The step runs in the floating TUI through sudo after the commands are shown. | [D061](D061-no-manual-commands.md) elevates in a terminal the user sees, and the sandbox has no polkit authentication a row may start. |
| The panel learns the operator is missing from `tailscale switch --list` failing with "profiles access denied". | `tailscale get operator` names the operator. | The documented preference read answers the question directly and tells another user's operator from none. |
| `install/post-install/udev.sh` reloads udev and triggers `power_supply` for package-owned rules, ignoring failure. | `apple-displays` installs its own rule, then reloads and triggers `hidraw` with `--settle`, and a failure is refused with its command. | The rule is VGS's, and the probe after the commands must read the new access. |
| No record of what an install changed; nothing is undone. | A root-owned record per step, and `undo` reverts only what it records. | `undo` can revert exactly what VGS changed, and never what the system had before. |

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Each plugin runs its own root setup in its own TUI | A plugin would carry root commands the core never judged ([D007](D007-install-runs-no-plugin-code.md), [D036](D036-time-boxed-passwordless-sudo-grant.md)). |
| An installed root half like `vgsh-sudo-grant`'s | One-time setup needs no lasting root entry point; a one-shot sudo session per apply leaves nothing installed. |
| pkexec, as Omarchy does | D061 elevates in the floating TUI, and polkit's agent would ask outside the terminal the commands were shown in. |
| A per-user record under `$XDG_STATE_HOME` | The changes are system-wide, and a user-writable record could steer `undo` against changes VGS did not make. |
| Probe a rule file's presence | v1's rule and the ddcutil package grant the access under other names, and a rule udev did not apply grants nothing. |

**Revisit When**: a step needs a privilege a sudo command cannot give, a distribution ships these grants itself, VGS ships a package that can own the rule, or tailscaled stores the operator somewhere `tailscale get` cannot read.

**Verification**: `scripts/test-vgsh-system.sh` runs `vgsh system` under a temporary prefix with stand-in `sudo`, `gum`, `stat`, `udevadm`, `systemctl`, `modprobe` and `tailscale`, and binds a NixOS os-release for the `nix` rows; its controls are copies that write before the question, accept a step outside the table, read a file's presence, disable a unit VGS did not enable, and more. `scripts/test-plugin-logic.js` and `scripts/test-plugin-status.js` judge `systemSteps`, the action and the report. `scripts/smoke/rows/system-steps.sh` presses Allow in the nested sandbox.

**References**: [D003](D003-everything-is-a-plugin.md), [D007](D007-install-runs-no-plugin-code.md), [D033](D033-floating-tuis-are-core.md), [D036](D036-time-boxed-passwordless-sudo-grant.md), [D037](D037-plugin-status.md), [D061](D061-no-manual-commands.md), [D075](D075-consumer-features-need-no-developer-setup.md), [tui-system.md](../architecture/tui-system.md)
