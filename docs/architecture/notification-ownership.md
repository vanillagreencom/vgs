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

VGS starts a moment later than that, so on a first install it loses, and the
only symptom from the user's seat is that the shell they installed for its
notification center draws nothing while notifications keep appearing in another
daemon's style.

## The three layers

| Layer | Owner | What it does |
|-------|-------|--------------|
| Packaging | `packaging/` | Declares that two notification daemons on one session is not a supported configuration |
| Helper | `bin/vshell-helper` (`vshell notifications`) | Detects the owner, and takes the name back reversibly |
| Shell | `NotificationService.qml`, Settings, notification center | Surfaces the loss where the user is, and offers the fix |

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
| `status [--json]` | Who owns the bus name (`vgs`, `foreign`, `unowned`), every conflicting daemon found, and whether a takeover is possible. Exits non-zero when VGS does not own it. |
| `takeover [--json]` | Masks and stops the conflicting user unit, and shadows its D-Bus activation file. Reversible. |
| `restore [--json]` | Undoes exactly what `takeover` did, using the record in `~/.local/state/vshell/notification-takeover.json`. |

Detection reads the session bus, not a list of known daemons: the owner comes
from `GetNameOwner` + `GetConnectionUnixProcessID`, and the claimants that could
win a *future* session come from every D-Bus activation file in the XDG data
directories that names the bus. A daemon nobody has heard of is still found;
`KNOWN_NOTIFICATION_DAEMONS` only supplies a friendly label.

Two details that are easy to get wrong:

- **The unit comes from `/proc/<pid>/cgroup`, not from busctl.** `busctl status`
  reports `Unit=user@1000.service` for everything on the user bus, which is the
  session manager and cannot be stopped.
- **Shadowing is by file name in `$XDG_DATA_HOME/dbus-1/services/`.** D-Bus
  resolves activation files from the data directories in order and stops at the
  first hit, so a same-named file in the user's data home wins over
  `/usr/share`. The shadow's `Exec` is `false`: whenever VGS runs it owns the
  name and nothing is activated, and when VGS is not running, failing the
  activation is honest — silently starting the daemon the user asked to displace
  is the behaviour this exists to prevent.

`takeover` never kills a process. It masks and stops the unit, the daemon
releases the name on its own, and Quickshell's pending registration completes —
no shell restart. A daemon that is not a user unit (started from a compositor
rule, say) cannot be stopped safely from here; it is reported for the user to
quit, and the shadow still keeps it from coming back by activation.

`vshell deps status` reports ownership too, since that is where a user looks
when a subsystem is missing.

### Shell

`NotificationService` cannot ask Quickshell whether its registration won, so it
probes `vshell notifications status --json`:

- 4s after startup, so the probe does not race the registration it is checking;
- every 30s **while VGS is not the owner** — this is how the shell notices it
  has won after the other daemon exits, since Quickshell re-registers silently;
- when the notification center opens, when the Settings tab loads, and after a
  takeover.

Exposed as `serverOwnership`, `serverConflict`, `serverConflictDaemon`,
`serverConflictFixable` and `serverTakeoverBusy`. A conflict raises a **sticky**
toast (category `notification-server-conflict`, dismissed automatically when VGS
wins the name), replaces the notification center's "Nothing to see here" empty
state with the real reason and a *Use VGS for Notifications* button, and shows
the same status and button in Settings → Notifications.

The `notificationServerEnabled` setting is the deliberate opt-out: it drives the
`LazyLoader` around `NotificationServer`, so turning it off destroys the server
and releases the bus name for whichever daemon the user prefers, and suppresses
the warning that would otherwise be wrong.
