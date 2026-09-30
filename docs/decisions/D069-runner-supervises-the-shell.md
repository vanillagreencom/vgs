# D069: The runner supervises the shell

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: VGS-679

**Refines**: [D053](D053-runner-holds-the-instance-lock.md)

**Context**: `vgsh run` started the shell once and exited with its status ([D053](D053-runner-holds-the-instance-lock.md)). A shell that died stayed dead: the bar, the notifications and the launcher were gone until the user started a shell by hand. The VGS-611 lane report named the worst case. `vgs.lock` holds the session lock through Hyprland's ext-session-lock ([D062](D062-native-lock-and-polkit-plugins.md)), and Hyprland keeps that lock after its client dies, behind its own warning screen. A shell that died while locked left the user only a TTY to get back in. Quickshell 0.3.1 relaunches itself after some crashes, but not after all of them: its crash handler catches SIGSEGV, SIGABRT, SIGFPE, SIGILL, SIGBUS and SIGTRAP and execs itself again in the same pid (`src/crash/handler.cpp`, revision 41651d7), and `checkCrashRelaunch` in `src/launch/main.cpp` exits with status 255 instead when the crashed instance ran under 10 s. SIGKILL, as from the kernel's out-of-memory killer, and Qt's `_exit` when the Wayland connection fails raise no signal it catches.

**Decision**: `vgsh run` supervises the shell it starts. It keeps D053's lock and child model: one preflight, the lock on descriptor 9 held by the runner alone, a child that writes its own pid and execs `qs` through `setpriv --pdeathsig TERM`. Before each start it empties the lock file, creates the directories and removes the stale snapshot roots. After the shell exits it decides in this order:

1. HUP, INT or TERM reached the runner: it exits with the shell's status. A stop signal during a relaunch delay ends the runner at once, since the delay is a background `sleep` it waits on.
2. The shell exited 0, a deliberate stop: it exits 0.
3. `hyprctl -j monitors` gives no answer in three tries 0.5 s apart: Hyprland is gone or going, and it exits with the shell's status.
4. Otherwise it counts the exit in a streak. A run of 60 s or more starts a new streak. The relaunches of a streak wait 0.5, 1, 2, 4 and 8 s, and the lock file is empty while it waits.
5. The sixth exit of a streak gives up: a `vgsh: shell=gave-up` line, a `hyprctl notify` error notice for 10 minutes that tells the user to log out and back in, and an exit with the shell's status. While `LockModel.sessionLockState` reads the monitors as other than `unlocked`, it never gives up and relaunches every 8 s.

`vgsh restart` sends TERM to the runner, the parent of the shell's pid when that parent holds the lock on descriptor 9, so the runner stops the shell and starts none again. A parent that holds no lock, as a runner from before D053 that execed `qs` in place, leaves the TERM to the shell's pid. The numbers are one table in `bin/vgsh`, beside the preflight table. The contract is [runtime.md § Process](../architecture/runtime.md#process).

### The options

| Option | Taken | Rejected, and why |
|---|---|---|
| A: the runner relaunches the shell with a backoff and a give-up | Yes | |
| B: a systemd user service with `Restart=on-failure` | | VGS ships no systemd unit and starts from Hyprland's `exec_cmd` autostart ([runtime.md § Process](../architecture/runtime.md#process)). The instance lock and the guard's pid model belong to the runner, and a unit would need a second owner of the shell's lifetime. |
| C: rely on Quickshell's own relaunch after a crash | | It misses SIGKILL, `_exit` on a lost Wayland connection and every crash under 10 s, which exits 255. |
| D: give up after a crash streak while locked too | | A stopped runner leaves Hyprland's dead-lock screen, which only a new lock client or a TTY clears. |

**Rationale**:

- The runner already waits on the shell and holds the lock, so a loop around its start keeps one owner of the shell's lifetime. The lock stays held from the first start to the runner's exit, so no second `vgsh run` starts in a relaunch gap.
- A relaunch while locked needs no new lock code. The Hyprland layer sets `misc.allow_session_lock_restore`, and the new shell's `vgs.lock` reads the stranded lock at start and takes it over ([lock-polkit.md](../architecture/lock-polkit.md)).
- The session lock reading is `vgs.lock`'s `LockModel.sessionLockState`, which the runner runs under node through `bin/lib/qml-library.js`. A reading that is not `unlocked` counts as locked, since giving up then can strand the user.
- A streak that a healthy run resets gives each crash after a long run the short first delay. A window counter would count a crash an hour ago the same as one a second ago.

**Consequences**:

- A shell that crashes at every start costs five starts over 15.5 s before the notice. While locked, it costs one start every 8 s until the session ends.
- Between two starts the lock file is empty, so `vgsh pid`, `ipc` and `restart` refuse `shell=not-running` for up to 8 s.
- The nested smoke's rows take up a relaunched shell with the harness's `adopt_shell` instead of starting one by hand.

## Where VGS differs from Omarchy

Checked against basecamp/omarchy at `8b4eae6`: `bin/omarchy-launch-shell`, `bin/omarchy-restart-shell`.

| Omarchy | VGS | Why |
|---|---|---|
| A stop signal, a clean exit or a Hyprland that fails `hyprctl -j monitors` three times 0.5 s apart ends the launcher. | The same, in the same order. | Taken from Omarchy. |
| More than five relaunches in one 60 s window give up. | Five relaunches in a streak give up, and a run of 60 s or more starts a new streak. | A window that restarts on the clock can count crashes that a long healthy run separated. |
| Every relaunch waits 1 s. | The waits are 0.5, 1, 2, 4 and 8 s. | The first crash comes back sooner, and a crash loop costs fewer starts per minute. |
| The give-up is a `logger` line in the journal. | The give-up is a `hyprctl notify` error notice, and a keyed stderr line. | The shell that shows notices is the one that died, and a journal line is out of the user's sight. |
| The launcher gives up while locked as well. | The runner never gives up while locked. | A stopped runner leaves Hyprland's dead-lock screen; Omarchy recovers that with `omarchy-restart-shell`, which the user must run. |
| `omarchy-restart-shell` stops every instance with `quickshell kill` and dispatches the launcher. | `vgsh restart` stops the runner, which starts no shell again, and dispatches `vgsh run`. | A TERM to the shell alone now brings a relaunch that holds the lock the new runner waits on. |

**Revisit When**: Quickshell relaunches itself after every exit that is not a clean one; VGS ships a systemd user unit; or a relaunch while locked stops taking the lock over.

**Verification**: `scripts/test-vgsh-run.sh` runs the runner against a stub `qs` and a stub `hyprctl` and pins the relaunch after a SIGKILL with the lock held throughout, no relaunch after exit 0, a stop or a gone Hyprland, a stop during the delay, the give-up and its notice, no give-up while locked or unreadable, the healthy-run reset and `vgsh restart`'s stop of the runner or the shell, each with a control on a copy of `bin/vgsh`. `scripts/smoke/rows/supervise.sh` reads, in the nested sandbox, the relaunch within its budget and the give-up after six quick deaths with a notice Hyprland answers ok, with a copy that relaunches nothing and a copy whose limit is out of reach as controls. `scripts/smoke/rows/lock.sh` reads the lock screen back within its budget after a kill while locked, and a sampler that finds the session locked from before the kill to the new lock, with the second lock client's unlock as the sampler's control. `scripts/smoke/rows/start-order.sh` reads the relaunch after a crash with a live child while the runner holds the lock.

**References**: [runtime.md § Process](../architecture/runtime.md#process), [lock-polkit.md](../architecture/lock-polkit.md), [validation-smoke-harness.md](../architecture/validation-smoke-harness.md), [validation-latency.md](../architecture/validation-latency.md)
