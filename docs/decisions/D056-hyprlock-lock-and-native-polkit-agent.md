# D056: hyprlock locks the session, and a native plugin is the polkit agent

[← Decision Index](INDEX.md)

**Date**: 2026-09-29
**Status**: Active
**Research**: VGS-611

**Context**: A VGS-only session had no lock screen and no polkit agent. The core already owns the one `WlSessionLock` and the one `PolkitAgent` and lends each through the exclusive `lock` and `polkit` capabilities ([D012](D012-core-owns-lent-objects.md)), but no plugin held either, and the launcher's Lock row ran bare `hyprlock`. Omarchy's default branch (`basecamp/omarchy` 8b4eae6) retired `hyprlock`, `hypridle` and `hyprpolkitagent` for a native `omarchy.lock` service (`WlSessionLock` with PAM services it installs under `/etc/pam.d`) and a native `omarchy.polkit` service. Both lock options hold ext-session-lock-v1, so Hyprland keeps the session locked when the locking client dies either way; they differ in what a shell crash does to the lock.

**Decision**: The lock is hyprlock. `vgsh lock` runs it on the theme's lock screen, which the `hyprlock` theme target renders from the tokens, and `vgs.lock` binds `SUPER+L` and an IPC function to `vgsh lock`, run detached. The polkit agent is native: `vgs.polkit` holds the core's `polkit` capability and draws its prompt from the tokens and `qs.Ui`. The core `lock` capability stays open to a third-party plugin.

**Rationale**:
- A native lock dies with the shell. `vgsh run` does not restart a crashed shell, so a crash leaves Hyprland's dead-lock screen, which only a TTY recovers, and a Quickshell 0.3.1 reload while locked can unlock ([runtime.md](../architecture/runtime.md)). hyprlock is its own process: a shell crash leaves the lock working and unlockable. VGS differs from Omarchy here for these two reasons.
- `vgsh lock` needs no running shell, so hypridle's `lock_cmd` and a lid bind call the same command as the shortcut.
- A polkit agent fails closed: with no agent, or a dead one, polkitd denies the request. So a native agent carries no lock-style risk, and it gains the design system's tokens and components, which `hyprpolkitagent`'s own Qt Quick style never reads. This matches Omarchy.
- A native lock would need PAM service files under `/etc/pam.d`, which the package would own; hyprlock ships its own.

**Revisit When**: The runner supervises and restarts a crashed shell and Quickshell keeps a session lock across a reload; or hyprlock stops reading environment variables in its configuration.

**Verification**: `scripts/test-vgsh-lock.sh`, `scripts/test-theme-hyprlock.js`, `scripts/test-polkit-model.js`, `scripts/smoke/rows/lock.sh` and `scripts/smoke/rows/polkit.sh`, each with its controls; [lock-polkit.md](../architecture/lock-polkit.md) names what each proves.

**References**: [D012](D012-core-owns-lent-objects.md), [D035](D035-manifest-requirements.md), [D039](D039-per-screen-wallpaper-map.md), [lock-polkit.md](../architecture/lock-polkit.md)
