# Notification ownership

VGS is a notification daemon. `Services/NotificationService.qml` registers
`org.freedesktop.Notifications` on the session bus through Quickshell's
`NotificationServer`, and everything the user sees — popups, the notification
center, history, rules, grouping — is fed by that one registration.

The bus name is **first-come, first-served**. Exactly one connection owns it per
session, and the loser is not told to try harder: Quickshell logs

```
Could not register notification server at org.freedesktop.Notifications,
presumably because one is already registered.
Registration will be attempted again if the active service is unregistered.
```

and keeps a pending registration that only completes if the current owner
disappears.

## Why VGS usually loses on a stock system

A distribution that ships any notification daemon also ships its D-Bus
activation file, e.g. `/usr/share/dbus-1/services/fr.emersion.mako.service`
with `Name=org.freedesktop.Notifications`. Nothing has to start that daemon:
the **first notification any app sends after login** makes the bus start it, and
it then holds the name for the rest of the session. The unit can read
`disabled` in `systemctl --user status` and still be `active (running)`.

VGS starts a moment later than that, so on a first install it loses the race,
and the only symptom from the user's seat is that the shell they installed for
its notification center draws nothing while notifications keep appearing in
another daemon's style.

That is why the **first run takes the name rather than reporting the loss** —
see § First run below. Every later session reports and offers; only the first
one acts on its own.

## The three layers

| Layer | Owner | What it does |
|-------|-------|--------------|
| Packaging | `packaging/` | Declares that two notification daemons on one session is not a supported configuration |
| Helper | `bin/vshell-helper` (`vshell notifications`) | Detects the owner, and takes the name back reversibly |
| Shell | `NotificationService.qml`, Settings, notification center | Takes the name once on first run, then surfaces the loss where the user is and offers the fix |

### Packaging

The Arch packages declare `provides=('notification-daemon')` and conflict with
`notification-daemon`, `mako` and `swaync` (`dunst` provides
`notification-daemon`, so it is covered). Debian, Fedora, Gentoo and Void carry
the equivalent declaration. `conflicts` is the honest expression: pacman already
knows how to say "these two cannot both be installed", and it removes the race
before it can happen rather than papering over it afterwards.

Package metadata cannot help a daemon that was installed outside the package
manager, or one already installed when VGS is added from a tarball. That is what
the helper is for.

### Helper — `vshell notifications`

| Command | Effect |
|---------|--------|
| `status [--json]` | Who owns the bus name (`vgs`, `foreign`, `unowned`, `unknown`), every conflicting daemon found, and whether a takeover is possible. Exits non-zero when VGS does not own it. |
| `takeover [--json]` | Masks and stops the conflicting user unit, and shadows its D-Bus activation file. Reversible. |
| `restore [--json]` | Undoes exactly what `takeover` did, using the record in `~/.local/state/vshell/notification-takeover.json`. |

Detection reads the session bus, not a list of known daemons: the owner comes
from `GetNameOwner` + `GetConnectionUnixProcessID`, and the claimants that could
win a *future* session come from every D-Bus activation file in the XDG data
directories that names the bus. A daemon nobody has heard of is still found;
`KNOWN_NOTIFICATION_DAEMONS` only supplies a friendly label.

`unknown` is a first-class state, not a variant of `unowned`. The bus reports
"nobody owns this name" as an *error*, so a failed `busctl` call has to be
classified: `_BUS_NO_SUCH_NAME` matches the three phrasings that mean unowned
(`no such name`, `does not have an owner`, `NameHasNoOwner`), and everything
else — busctl missing, a timeout, an unparseable reply, an owner whose pid
cannot be resolved — becomes `unknown` with the reason attached. Collapsing
those into "unowned" would report a broken probe as a healthy session, which is
the same silence this subsystem exists to remove.

Four details that are easy to get wrong:

- **The unit comes from `/proc/<pid>/cgroup`, not from busctl.** `busctl status`
  reports `Unit=user@1000.service` for everything on the user bus, which is the
  session manager and cannot be stopped.
- **A cgroup leaf is not proof of unit ownership.** It answers "which unit is
  this process *inside*", never "which unit *is* this process". A daemon started
  from a compositor rule (`exec-once = mako`) has no unit of its own and
  inherits the compositor's — on Hyprland + uwsm that leaf is
  `wayland-wm@hyprland.desktop.service`. Masking and stopping it would end the
  graphical session and leave the next login broken until the user unmasks from
  a TTY. So `_unit_runs_this_daemon()` gates every mask and stop: the unit is
  acted on only when its `MainPID` is the bus owner or its `ExecStart` names the
  owner's binary (a `SystemdService=` line in the daemon's own activation file
  counts as the daemon declaring the unit its own). Anything else is reported
  through `manual`, naming the unit VGS refused to touch, and no takeover is
  offered for it.
- **Shadowing is by file name in `$XDG_DATA_HOME/dbus-1/services/`.** D-Bus
  resolves activation files from the data directories in order and stops at the
  first hit, so a same-named file in the user's data home wins over
  `/usr/share`. The shadow's `Exec` is `false`: whenever VGS runs it owns the
  name and nothing is activated, and when VGS is not running, failing the
  activation is honest — silently starting the daemon the user asked to displace
  is the behaviour this exists to prevent.

- **A displaced file is kept.** The activation file being shadowed can itself
  live in the data home — one the user installed by hand. It is moved to
  `<name>.vgs-orig` before the shadow is written, recorded in the undo state,
  and moved back by `restore`; overwriting it would make the reversibility
  guarantee false.
- **Restore restarts what takeover stopped.** Unmasking alone would leave the
  user's daemon dead until the next login, which is not what "undo" means, so
  stopped units are recorded and started again after the unmask.
- **An unrecordable change is a failure.** If the undo record cannot be
  persisted, `takeover` reports `ok: false` and says so, because masks and
  shadows that `restore` cannot find are not reversible.

`takeover` never kills a process. It masks and stops the unit, the daemon
releases the name on its own, and Quickshell's pending registration completes —
no shell restart. A daemon that is not a user unit (started from a compositor
rule, say) cannot be stopped safely from here; it is reported for the user to
quit, and the shadow still keeps it from coming back by activation.

`vshell deps status` reports ownership too, since that is where a user looks
when a subsystem is missing. Both surfaces read `notificationServerEnabled`: with
the shell's server deliberately turned off, another daemon holding the name is
the configured outcome, so it is reported as such — no "VGS notifications are
inert", no takeover advice, and a zero exit.

### Shell

`NotificationService` cannot ask Quickshell whether its registration won, so it
probes `vshell notifications status --json`:

- 4s after startup, so the probe does not race the registration it is checking;
- every 30s **while VGS is not the owner** — this is how the shell notices it
  has won after the other daemon exits, since Quickshell re-registers silently;
- when the notification center opens, when the Settings tab loads, and after a
  takeover.

Exposed as `serverOwnership`, `serverConflict`, `serverConflictDaemon`,
`serverConflictFixable`, `serverStatusError` and `serverTakeoverBusy`. A probe
that cannot be spawned or returns nothing readable sets `unknown` with a reason
rather than leaving the previous answer standing, and the re-check timer runs on
every state that is not `vgs` — including `unknown`, so a failed probe can never
switch off the only retry. A conflict raises a **sticky**
toast (category `notification-server-conflict`, dismissed automatically when VGS
wins the name), replaces the notification center's "Nothing to see here" empty
state with the real reason and a *Use VGS for Notifications* button, and shows
the same status and button in Settings → Notifications.

That toast carries the fix as a **button**, not as directions. When the takeover
is possible the button is *Use VGS for Notifications* and runs
`takeOverNotificationServer()` directly; when it is not, the button is *Open
settings* and routes to the Notifications tab. Prose no longer names a menu
path: there is no visible breadcrumb called "Settings > Notifications", and the
shortest real route is the gear on the notifications dropdown in the bar, which
is what the remaining copy points at. The mechanism is
`ToastService.showToast(..., action)`; see `Services/ToastAction.js`.

### First run

`notificationServerEnabled` decides whether VGS wants the name at all.
`notificationFirstRunTakeoverDone` decides whether it has already had its one
chance to take it.

On the first ownership answer of a fresh install, with the server enabled and
the one-shot unspent, VGS masks the conflicting daemon and claims the name, then
says so with an **informational** toast — "VGS is now handling notifications" —
carrying an *Open settings* button back to Notifications to undo it. Losing
silently is the worse default: it hands a new user a shell that looks broken
plus a chore, when the packaging layer already declares two daemons on one
session unsupported.

Five properties of the one-shot, each load-bearing:

- **It fires only from a config that actually loaded.** A `settings.json` that
  failed to parse — or has not been read yet — leaves every property at its
  default: `notificationServerEnabled` true and the one-shot false, which is
  indistinguishable from a fresh install. Acting on that would mask and stop
  the daemon of a months-old session, and `saveSettings()` is disabled after a
  parse error, so the one-shot could not even be recorded as spent and the same
  takeover would fire again next start. `_maybeTakeOverOnFirstRun()` therefore
  requires `SettingsData._hasLoaded && !SettingsData._parseError` before
  anything else. "The properties look like defaults" is not evidence of a first
  run; "the config loaded and said so" is.
- **It is keyed on its own state, never on "is there a conflict right now".**
  Keying it on the conflict would re-fire on every update for anyone whose
  preferred daemon is a different one.
- **It persists in `settings.json`**, the user's own config. No package upgrade
  rewrites that file, so a `-git` bump cannot reset it.
- **Every config that already existed arrives with it spent.** The v22 migration
  in `SettingsStore.js` sets it `true` unconditionally: an existing config is by
  definition not a first run, and without that line the key would land on its
  `false` default at every upgrade and re-arm the takeover — including for a
  user who had deliberately turned VGS notifications off.
  `scripts/check-settings-migration.js` asserts both halves.
- **It is spent on the first usable answer, whatever it says** — including
  "another daemon owns it and cannot be stopped from here". Leaving it unspent
  in that case would arm a takeover to fire weeks later, on whichever session
  the other daemon happened to become stoppable.

With the server disabled the one-shot is left untouched rather than spent: that
is not a first run to act on, and turning the server back on later should still
get the takeover that re-enabling it implies.

#### The settle window

Masking the other daemon and Quickshell re-acquiring the name are separate
asynchronous steps, so the takeover is followed by a settle window
(`firstRunTakeoverTimer`) during which the ordinary conflict warning is
suppressed — warning there would report the state the takeover exists to change.

The window opens **after** the helper has actually started, not before
`takeOverNotificationServer()` is called, and while the helper is still running
the window re-arms instead of expiring. The helper's systemd operations are
synchronous and can outlast one 6s window; ending the takeover underneath a
still-running helper produced a false conflict warning on a *slow but
successful* takeover and then discarded the state the success toast needed, so
the success was never announced either. Re-arming is bounded by a wall-clock
deadline (`_firstRunTakeoverDeadline`, 60s from the helper's start), so a helper
that never exits still ends the window rather than extending it forever.

`takeOverNotificationServer()` returns whether the helper started, and clears
`serverTakeoverBusy` itself when it did not. Quickshell may never make `running`
true for a command that cannot be spawned at all, in which case
`onRunningChanged` never fires — and the busy flag disables both takeover
buttons, so one failed launch would have wedged them for the rest of the
session.

#### Opting out reverses what VGS did on its own

The `notificationServerEnabled` setting is the deliberate opt-out: it drives the
`LazyLoader` around `NotificationServer`, so turning it off destroys the server
and releases the bus name for whichever daemon the user prefers, and suppresses
the warning that would otherwise be wrong. It also gates the first-run takeover,
so an opt-out made before the update survives it.

The invariant the opt-out has to hold is **after opting out, some notification
daemon is running** — and clearing VGS's own bookkeeping does not hold it. The
first-run takeover masked and stopped the user's daemon without being asked; if
the opt-out only tore down the settle window, VGS would go inert *and* the
user's daemon would stay dead, which is precisely the outcome the opt-out
exists to prevent.

So `onNotificationServerEnabledChanged` calls `_reverseFirstRunTakeover()`,
which runs `vshell notifications restore` — unmasking every unit the takeover
masked, starting every unit it stopped, dropping every activation shadow it
wrote and putting back any user file those shadows displaced. It holds the
invariant in three cases:

| Case | Why a daemon is running afterwards |
|------|------------------------------------|
| VGS never took anything (`_firstRunTakeoverFired` false) | Nothing was changed, so whatever was handling notifications before still is. This covers the ordinary opt-out and every manual takeover the user made themselves. |
| The takeover finished | `restore` runs immediately and puts the daemon back. |
| The takeover is still in flight | The reversal is **deferred** to the helper's exit (`_restorePending`) rather than racing it — a restore that overlapped the helper could have its unmask overwritten by a mask the helper had not applied yet. |

Two details that keep the deferral honest: re-enabling the server before the
helper exits cancels the pending reversal (it would undo the state the user just
asked for again), and `_reverseFirstRunTakeover()` re-reads the setting at
execution time rather than trusting the flag it was deferred with. The success
toast is likewise re-gated on `serverEnabled`, since the non-conflict branch is
also reached with the server off — announcing a takeover to someone who just
opted out of it would describe a change already on its way to being undone.

If the restore helper itself cannot be spawned, VGS says so with an error toast
naming the exact command (`vshell notifications restore`). That is the one case
the invariant cannot be held automatically, and it is reported rather than left
silent.
