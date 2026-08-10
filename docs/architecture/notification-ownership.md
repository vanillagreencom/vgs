# Notification ownership

VGS is a notification daemon. `Services/NotificationService.qml` registers
`org.freedesktop.Notifications` on the session bus through Quickshell's
`NotificationServer`, and everything the user sees — popups, the notification
center, history, rules, grouping — is fed by that one registration.

The bus name is **first-come, first-served**: exactly one connection owns it
per session. The loser is not told to try harder — Quickshell logs "Could not
register notification server…" and keeps a pending registration that only
completes if the current owner disappears.

## Why VGS usually loses on a stock system

A distribution that ships any notification daemon also ships its D-Bus
activation file (e.g. `/usr/share/dbus-1/services/fr.emersion.mako.service`
with `Name=org.freedesktop.Notifications`), so the first notification any app
sends after login bus-activates that daemon and it holds the name for the rest
of the session — even with its unit reading `disabled` in `systemctl --user
status`. VGS starts a moment later and loses the race, and the only symptom is
a notification center that draws nothing while notifications appear in another
daemon's style.

That is why the **first run takes the name rather than reporting the loss** —
see § First run. Every later session reports and offers; only the first one
acts on its own.

## The three layers

| Layer | Owner | What it does |
|-------|-------|--------------|
| Packaging | `packaging/` | Declares that two notification daemons on one session is not a supported configuration |
| Helper | `bin/vshell-helper` (`vshell notifications`) | Detects the owner, and takes the name back reversibly |
| Shell | `NotificationService.qml`, Settings, notification center | Takes the name once on first run, then surfaces the loss where the user is and offers the fix |

### Packaging

The Arch packages declare `provides=('notification-daemon')` and conflict with
`notification-daemon`, `mako` and `swaync` (`dunst` provides
`notification-daemon`, so it is covered); Debian, Fedora, Gentoo and Void carry
the equivalent declaration. `conflicts` removes the race before it can happen.
Package metadata cannot help a daemon installed outside the package manager —
that is what the helper is for.

### Helper — `vshell notifications`

| Command | Effect |
|---------|--------|
| `status [--json]` | Who owns the bus name (`vgs`, `foreign`, `unowned`, `unknown`), every conflicting daemon found, and whether a takeover is possible. Exits non-zero when VGS does not own it. |
| `takeover [--json] [--automatic]` | Masks and stops the conflicting user unit, and shadows its D-Bus activation file. Reversible. `--automatic` stamps the undo record as VGS's own first-run action; only the shell passes it. |
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
else — busctl missing, a timeout, an unparseable reply, an unresolvable owner
pid — becomes `unknown` with the reason attached, never a claimed-healthy
"unowned".

Details that are easy to get wrong:

- **The unit comes from `/proc/<pid>/cgroup`, not from busctl** — `busctl
  status` reports `Unit=user@1000.service` for everything on the user bus,
  which is the session manager and cannot be stopped.
- **A cgroup leaf is not proof of unit ownership.** It answers "which unit is
  this process *inside*", never "which unit *is* this process": a daemon
  started from a compositor rule (`exec-once = mako`) inherits the
  compositor's unit, and masking that would end the graphical session.
  `_unit_runs_this_daemon()` therefore gates every mask and stop — act only
  when the unit's `MainPID` is the bus owner or its `ExecStart` names the
  owner's binary (a `SystemdService=` line in the daemon's own activation file
  also counts). Anything else is reported through `manual`, naming the unit
  VGS refused to touch, with no takeover offered.
- **Shadowing is by file name in `$XDG_DATA_HOME/dbus-1/services/`** — D-Bus
  stops at the first hit in data-directory order, so a same-named user file
  wins over `/usr/share`. The shadow's `Exec` is `false`: failing the
  activation is honest, silently starting the daemon the user asked to
  displace is not.
- **A displaced file is kept.** A same-named activation file already in the
  data home is moved to `<name>.vgs-orig` before the shadow is written,
  recorded in the undo state, and moved back by `restore`.
- **Restore restarts what takeover stopped** — unmasking alone would leave the
  user's daemon dead until the next login.
- **An unrecordable change is a failure.** If the undo record cannot be
  persisted, `takeover` reports `ok: false`, because masks and shadows
  `restore` cannot find are not reversible.
- **The record says who asked.** `initiator` is `"first-run"` when the shell
  took the name unasked, `"manual"` when a person did; `status --json`
  surfaces it as `restore.initiator` / `restore.automatic`. An absent or
  unrecognised value reads as `"manual"`, and once `"first-run"` it stays that
  way for the life of the record, including through a partial `restore`.

`takeover` never kills a process: it masks and stops the unit, the daemon
releases the name on its own, and Quickshell's pending registration completes —
no shell restart. A daemon that is not a user unit cannot be stopped safely
from here; it is reported for the user to quit, and the shadow still keeps it
from coming back by activation.

`vshell deps status` reports ownership too. Both surfaces read
`notificationServerEnabled`: with the shell's server deliberately off, another
daemon holding the name is the configured outcome — no warning, no takeover
advice, a zero exit.

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
rather than leaving the previous answer standing, and the re-check timer runs
on every state that is not `vgs` — including `unknown`, so a failed probe can
never switch off the only retry. A conflict raises a **sticky** toast (category
`notification-server-conflict`, dismissed automatically when VGS wins the
name), replaces the notification center's empty state with the real reason and
a *Use VGS for Notifications* button, and shows the same status and button in
Settings → Notifications.

The toast carries the fix as a **button**, not directions: *Use VGS for
Notifications* runs `takeOverNotificationServer()` when the takeover is
possible, *Open settings* routes to the Notifications tab when it is not.
Prose never names a menu path; the shortest real route is the gear on the
notifications dropdown in the bar. The mechanism is
`ToastService.showToast(..., action)` — see `Services/ToastAction.js`.

### First run

`notificationServerEnabled` decides whether VGS wants the name at all;
`notificationFirstRunTakeoverDone` decides whether it has already had its one
chance to take it. On the first ownership answer of a fresh install, with the
server enabled and the one-shot unspent, VGS masks the conflicting daemon and
claims the name, then says so with an **informational** toast — "VGS is now
handling notifications" — carrying an *Open settings* button to undo it.
Losing silently is the worse default.

The announcement is **guaranteed delivery**, not best-effort: it is the only
place an unrequested ownership change is explained and the only in-UI pointer
at the undo. Its category is in `undroppableCategories` (exempt from
`ToastService`'s queue cap; bounded, because `showToast()` replaces any queued
entry sharing a category) and in `stickyCategories` (no 10s auto-dismiss).
`scripts/test-toast-actions.js` requires every undroppable category to be
sticky too. The exemption holds at **every** trim, not only at admission: the
three paths that remove an entry unshown (`dropCategory`, `dropLevel`,
`trimToLimit` in `Services/ToastQueue.js`) never remove a protected entry, and
the tested property is that a dropped entry is unreachable from the queue the
service goes on to hold.

Six properties of the one-shot, each load-bearing:

- **It fires only from a config that actually loaded** —
  `_maybeTakeOverOnFirstRun()` requires `SettingsData._hasLoaded &&
  !SettingsData._parseError`, because a default-valued store is
  indistinguishable from a fresh install, and `saveSettings()` is disabled
  after a parse error so the spend could never be recorded.
- **It fires only once the spend is on disk, read back by another process.**
  `SettingsData.set()` does not confirm the save landed, so nothing is masked
  or stopped until `status --json`'s `vgsFirstRunTakeoverDone`, read from the
  file by the helper, comes back true. The confirmation is polled by the 1.2s
  settle probe under a 15s deadline driven by its own timer (a `Process` that
  fails to start emits no `exited`, so a deadline checked only on re-entry
  would never be checked). Past it, or with the store read-only, VGS declines
  the takeover and says why: a takeover VGS cannot record is one it could
  never honour the opt-out for.
- **It is keyed on its own state, never on "is there a conflict right now"** —
  keying on the conflict would re-fire on every update for anyone whose
  preferred daemon is a different one.
- **It persists in `settings.json`**, the user's own config, so no package
  upgrade can reset it.
- **Every config that already existed arrives with it spent** — the v22
  migration in `SettingsStore.js` sets it `true` unconditionally, and
  `scripts/check-settings-migration.js` asserts both halves.
- **It is spent on the first usable answer, whatever it says** — including
  "another daemon owns it and cannot be stopped from here". Left unspent, the
  takeover would fire weeks later on whichever session that daemon happened to
  become stoppable.

With the server disabled the one-shot is left untouched rather than spent, so
turning the server back on later still gets the takeover that re-enabling it
implies.

#### The settle window

The takeover is followed by a settle window (`firstRunTakeoverTimer`) during
which the ordinary conflict warning is suppressed — masking the other daemon
and Quickshell re-acquiring the name are separate asynchronous steps. The
window opens **after** the helper has actually started, and while the helper is
still running it re-arms instead of expiring (the helper's synchronous systemd
operations can outlast one 6s window), bounded by a 60s wall-clock deadline
(`_firstRunTakeoverDeadline`) so a helper that never exits still ends it.

`takeOverNotificationServer()` returns whether the helper started and clears
`serverTakeoverBusy` itself when it did not — a command that cannot be spawned
may never fire `onRunningChanged`, and the busy flag disables both takeover
buttons.

#### Opting out reverses what VGS did on its own

`notificationServerEnabled` is the deliberate opt-out: it drives the
`LazyLoader` around `NotificationServer`, so turning it off destroys the server
and releases the bus name, suppresses the now-wrong conflict warning, and — an
opt-out made before the update survives it — gates the first-run takeover.

The invariant the opt-out must hold is **after opting out, some notification
daemon is running**, and the first-run takeover masked and stopped the user's
daemon without being asked. So `onNotificationServerEnabledChanged` calls
`_reverseFirstRunTakeover()`, which runs `vshell notifications restore` —
unmask, restart stopped units, drop shadows, put back displaced files. It
holds the invariant in these cases:

| Case | Why a daemon is running afterwards |
|------|------------------------------------|
| VGS never took anything | `restore.available` is false and no runtime flag is set, so the reversal is a no-op. This also covers every takeover the user ran themselves: `restore.initiator` is `"manual"` and VGS leaves a deliberate choice alone. |
| The takeover finished, same shell | `restore` runs immediately and puts the daemon back. |
| The takeover finished, **shell restarted since** | Provenance comes from the helper's undo record (`restore.automatic`), not from the runtime flag, so the restart changes nothing. |
| The takeover is still in flight | The reversal is **deferred** to the helper's exit (`_restorePending`) rather than racing it — a restore that overlapped the helper could have its unmask overwritten by a mask the helper had not applied yet. |
| The takeover changed the system but its **undo record was never saved** | The invariant **cannot** be held automatically, and VGS says so instead of pretending. See below. |

Provenance is the undo record, never a runtime flag (dies with the shell
process while the masks persist) or a settings key (a second source of truth
that cannot see a record deleted by hand or a `restore` run from a terminal).
The undo record cannot drift from what needs undoing, because it *is* what
needs undoing. `_firstRunTakeoverFired` is kept only as the fast path for the
session that fired the takeover; the two are OR'd.

Three details keep the deferral honest: re-enabling the server before the
helper exits cancels the pending reversal, and `_reverseFirstRunTakeover()`
re-reads the setting at execution time rather than trusting the flag it was
deferred with; an opt-out landing before provenance is known sets
`_reverseAfterProbe` and is resolved by the next usable ownership answer
rather than guessed at (either guess does the wrong thing for someone); and
the success toast is re-gated on `serverEnabled`, since the non-conflict
branch is also reached with the server off.

That wait is **bounded**: once the server is off the 1.2s settle probe is the
only poll left, and a probe that cannot be spawned produces no next answer at
all. `reverseDeadlineTimer` gives it 15s and then restores without having
established provenance — `restore` is a no-op on an empty record, and undoing
even a manual takeover is not contrary to an opt-out. The outcome is reported
through the restore-result path below.

#### Winning the bus name is not the same claim as succeeding

The helper masks and stops the foreign daemon **first** and writes the undo
record **last**, so a record that cannot be saved leaves the daemon masked,
the name won, `state: "vgs"` in the reply — and nothing to reverse it with.
`_applyTakeoverResult()` therefore reads `ok` and `failures` as well as
ownership — "the takeover succeeded" means the change **and** its record
landed — and distinguishes two failures via `restore.available` from the same
reply:

| Reply | What VGS says |
|-------|---------------|
| `ok: false`, record intact | "The notification takeover did not fully succeed" — names the failures, offers `vshell notifications restore` to undo what did land. |
| Actions taken, `restore.available` false | "VGS took over notifications but could not record it" — says plainly that VGS cannot restore that daemon later, and to unmask and start it by hand if `restore` reports nothing to do. |

The second is deliberately **not** offered as something VGS can fix: `restore`
reads the record and the record is what is missing. For the same reason
`_reverseFirstRunTakeover()` checks `_takeoverRecordLost` **before** spawning
the helper — `restore` on an empty record exits 0 with "nothing to do", which
would log a successful reversal while the user's daemon is still masked. Both
messages ride the guaranteed-delivery categories.

#### A restore that half worked is reported

A partial restore looks finished while the masks it could not lift are still
in force. `restore --json` answers with `ok` plus a `failures` list and exits
non-zero, and the shell checks it: a failed spawn, an unreadable answer, no
answer at all, or `ok: false` all raise the same error toast — "The previous
notification daemon was not fully restored" — naming the helper's own failure
lines, saying notifications may now have no daemon at all, and giving both
ways out (`vshell notifications restore` to finish it, or turn VGS
notifications back on). The record survives a failed restore with `initiator`
intact, so `restore.available` and `restore.automatic` stay true and the next
opt-out tries again.
