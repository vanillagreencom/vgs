
---

# Round 4 — P1, P2, P3, P4

Three commits, local only, nothing pushed, no threads resolved:

- `5deaf7c3` `frontend(VGS-64): stamp provenance only on a new record, and read the one-shot back from disk` — P2 + the helper half of P1
- `544dd713` `frontend(VGS-64): take nothing until the one-shot is confirmed on disk` — P1 (shell), P3, P4
- `e125f43c` `frontend(VGS-65): pin the announcement's category on the call, not the file` — a weak assertion of mine, found by mutation-proving P4

No takeover, mask, stop or start on this machine; no `settings.json` was
corrupted or chmodded. Live state re-checked after every nested run: the takeover
record's mtime is still `2026-08-04 11:11:08`, `~/.local/share/dbus-1/services/`
still does not exist.

## P1 — the one-shot spend was never verified — **fixed**

### What the takeover now does on an unwritable config: nothing, and it says so

Three gates, in order:

1. **Before writing anything.** If `SettingsData._isReadOnly` is already true,
   VGS refuses outright — no spend, no takeover — and reports.
2. **Immediately after `SettingsData.set()`.** A save that failed synchronously
   has already flipped `_isReadOnly` via `FileView.onSaveFailed`; if it did,
   refuse and report.
3. **Before masking or stopping anything.** This is the real fix. The takeover
   does not run on the strength of the in-memory property at all. It waits for
   `status --json`'s new `vgsFirstRunTakeoverDone`, which the helper reads out of
   `settings.json` **in a separate process**. Only when that comes back `true`
   does `_resolveFirstRunSpend()` fire the takeover.

### How the write was established to have succeeded

By having a different process read it back. That is the whole point: the failure
the reviewers describe is precisely "the next process reads the flag as false",
so the only evidence that answers it is a read by another process. Checking
`_isReadOnly` alone would not have — it is the store's own opinion, and gates 1
and 2 are cheap early exits, not the proof.

`vgs_first_run_takeover_done()` returns **False on any error** — absent file,
unparseable JSON, missing key, non-boolean value. Unreadable is not evidence of a
durable write, and the shell requires `true` to proceed, so every uncertainty
fails closed.

Polling and bound: `_firstRunSpendPending` is resolved by the 1.2s
`ownershipSettleTimer` re-probe, under a 15s wall-clock deadline
(`_firstRunSpendDeadline`). Past it, VGS gives up on the takeover permanently for
that session. An opt-out while confirming abandons it.

**Cost:** roughly one settle probe (~1.2s) added to a takeover that already
waited 4s for the startup probe. Nothing is masked during it, and the conflict
warning stays suppressed while confirming (`_maybeTakeOverOnFirstRun()` returns
true), so there is no flash of a warning that is about to be resolved.

**What the user sees when it is declined** — one warning toast, standing in for
the generic conflict warning rather than arriving beside it (it sets
`_serverConflictAnnounced`), announced once per session, and skipped entirely if
there is no conflict to report:

> **VGS is not handling notifications**
> VGS would normally take over org.freedesktop.Notifications on its first run,
> but settings.json could not be written, so it could not record having done so —
> and a takeover it cannot record is one it could not undo later. Nothing was
> changed. Fix the permissions on ~/.config/vshell/settings.json, or take it over
> yourself from Settings › Notifications.

with an *Open settings* button. Category `notification-server-unrecordable`,
dismissed alongside the conflict toast when VGS wins the name.

**On the next start** the disk still reads `false`, so the flag is `false`, so
VGS tries again — reaches the same gate, declines again, reports again. That is
the correct loop: repeated *refusal*, never repeated masking.

### Helper-side coverage (`scripts/check-vshell-helper.py`)

`persisted_one_shot_is_read_from_disk` pins false for absent / unparseable /
`false` / non-boolean, and true only for a persisted `true`. It also asserts the
shipped seed `config/vshell/settings.default.json` has the key `false`, because
`load_settings()` falls back to that seed when there is no user config — were the
seed `true`, an absent config would answer "already spent" and VGS would refuse
the takeover on exactly the config it exists for.

Mutations, both red:

```
=== mutation: the disk read-back defaults to true on error ===
AssertionError: an unreadable settings.json must not read as a spent one-shot: expected False, got True
=== mutation: status stops reporting the on-disk one-shot ===
AssertionError: status must surface the on-disk answer: expected True, got False
```

## P2 — automatic relabelled manual state — **fixed**

`notification_takeover(automatic=True)` now stamps `initiator` **only when the
record is being created**, tested with `_takeover_record_has_changes()` — the
same emptiness test `_save_takeover_record()` already used to decide whether to
delete the file, so the two agree by construction rather than by coincidence.

Consequence worth stating: if a manual record already exists when the automatic
pass runs, the record stays `"manual"` and VGS will not auto-reverse it — even
though some of the changes in it are VGS's. That is the conservative direction
and the one P2 asks for (an existing record's provenance is history). It is
reachable only if the user ran `vshell notifications takeover` themselves before
the shell's first ownership probe on a first run, and in that case they have
demonstrably asked for VGS to own the name.

### The test

`an_existing_record_is_never_relabelled` — the user takes the name themselves,
an automatic pass follows, and both `_load_takeover_record()["initiator"]` and
`status["restore"]["automatic"]` must still say manual. Paired with
`a_record_is_stamped_only_when_created`, so the fix cannot be "never stamp".

```
=== mutation: automatic relabels an existing record (the P2 bug) ===
AssertionError: an automatic takeover must not relabel a record the user created: expected 'manual', got 'first-run'
=== mutation: stamping is dropped entirely ===
AssertionError: the first-run takeover must be recorded on disk, not only in the shell: expected 'first-run', got 'manual'
```

## P3 — the deferred restore could stall — **fixed**

**Deadline: 15 s wall-clock (`reverseDeadlineTimer`). Chosen action: act —
restore without having established provenance.**

Why 15 s: once the server is off, `ownershipRecheckTimer` stops (it is bound to
`serverEnabled`), so the 1.2 s settle probe is the only poll left. 15 s covers
that probe with room for retries and still resolves well inside a user's
attention span.

Why acting rather than reporting-and-giving-up, three reasons in order of weight:

1. The invariant is "after an opt-out, some notification daemon is running".
   Waiting forever breaks it *precisely* in the cases where it was owed —
   giving up quietly is the same outcome with a log line.
2. Acting is nearly free when it was not owed: `notification_restore()` on an
   empty record does nothing, returns `ok: true`, prints "nothing to do". The
   common case (VGS never took anything) costs one helper invocation.
3. The one residual risk — undoing a takeover the user ran themselves — is **not
   contrary to what they just asked for**. They have turned VGS's notification
   server off, so they want some other daemon handling notifications; `restore`
   is what unmasks and starts it. The J3 scope boundary exists to avoid undoing a
   deliberate choice, and here the deliberate choice being expressed is the
   opt-out itself.

And it is not silent either way: whatever the restore does or fails to do is
reported through `_applyRestoreResult()` / M2.

Implementation note: the deadline path calls
`_reverseFirstRunTakeover(unconditional = true)`, so the ordinary provenance gate
is untouched on every other path. Re-enabling the server cancels the timer.

## P4 — the success toast could be dropped by the queue cap — **fixed**

**Both halves, because either alone leaves it undelivered.**

- `ToastService.undroppableCategories` — a new list, currently just
  `notification-server-takeover`, exempt from the `toastQueue.length >=
  maxQueueSize` drop. Bounded, not unbounded: `showToast()` already replaces any
  queued entry sharing a category before enqueueing, so each listed category can
  hold at most one slot over the cap.
- `stickyCategories` gains the same category, so it does not auto-dismiss.

**Why both, rather than just making it sticky** (which is what your note
suggested, and which alone would not have fixed it): sticky controls how long a
toast stays *once shown*. The bug is that it never gets shown — `showToast()`
returns early at the cap for any non-error level. Sticky would have changed
nothing about the drop.

**Why the exemption rather than raising it to `showError`:** it is not an error.
Nothing went wrong; VGS did something deliberate and is explaining it. Borrowing
the error level to borrow the error level's cap behaviour would misreport the
event to get the right delivery, and the error path's own overflow rule evicts
*other* errors, which is worse.

**Why this category earns the exemption at all:** it is the only place an
unrequested change to the user's system — which daemon owns
`org.freedesktop.Notifications` — is explained, and the only in-UI pointer at the
undo. Every other toast in the shell describes something the user just did. The
test enforces the coupling rather than the list: **every** undroppable category
must also be sticky, so a future addition cannot be guaranteed into the queue and
then auto-dismissed.

### Mutation proof

```
=== mutation: the takeover category is no longer undroppable ===
AssertionError: notification-server-takeover must be undroppable, or the queue cap can silently discard the only explanation of an unrequested change
=== mutation: the cap stops consulting the exemption (the P4 bug) ===
AssertionError: the queue cap must exempt undroppable categories, or the list is decorative
=== mutation: undroppable but not sticky (half-delivered) ===
AssertionError: notification-server-takeover must be sticky; reaching the queue is not delivery if it auto-dismisses in 10s
=== mutation: the announcing call renames its category ===
AssertionError: the first-run announcement must be raised under the category ToastService guarantees (notification-server-takeover)
```

The fourth mutation **passed** on my first version of the check, which searched
the whole file for the category string — `dismissCategory()` names it too, so
renaming it on the `showInfo` call alone (exactly the mistake that returns the
toast to droppable) went undetected. Fixed in `e125f43c`; the check now reads the
announcing call. Worth recording because it is the same defect class as J5, found
in my own work by the mutation step rather than by review.

## Verified vs reasoned

**Verified by running:** every mutation above (eight, all red, files restored);
the helper's on-disk read-back and provenance rules through real code paths in
scratch homes; the parsed `stickyCategories` / `undroppableCategories` lists and
the cap guard's source; the nested QML smoke; the full suite below.

**Reasoned, not executed:**
- Every QML-side timing path in P1 and P3. Exercising P1 needs an unwritable
  `settings.json` on a real first run; P3 needs an ownership probe that never
  answers. Both forbidden or impractical here.
- **The premise behind gate 2**, that `FileView` with `blockWrites: true`
  surfaces a failed save synchronously through `onSaveFailed` before
  `SettingsData.set()` returns. I did not confirm that against Quickshell's
  source or docs. The fix does not depend on it: gate 2 is an early exit, and
  gate 3 — the cross-process read-back — is correct whether the save fails
  synchronously, asynchronously, or silently. If `blockWrites` does not behave
  that way, gate 2 is dead code and nothing else changes.
- The exact rendering of the two new toasts.

## Gaps

- **Still no automated coverage of NotificationService's own logic.** The helper
  contract it depends on is now well pinned on both sides, and P4's cross-file
  coupling is pinned, but the ordering inside `_maybeTakeOverOnFirstRun` /
  `_resolveFirstRunSpend` / `reverseDeadlineTimer` is not. A source-pinning check
  in the shape of `test-toast-actions.js` could assert that no
  `takeOverNotificationServer(true)` call is reachable without
  `serverPersistedOneShotDone` having been consulted — that is the single most
  valuable assertion left on this PR, and it is the one that would have caught P1
  before review. Still offering; say the word and it is ~30 lines.
- The nested smoke ran again (exit 0) and again exercises none of this: the
  sandbox's private bus has no foreign daemon, so the first-run branch is never
  entered. It proves the shell still loads and binds with these changes.
- `scripts/smoke-surfaces.sh` not run (forbidden).
- The pre-existing `wayland-wm@hyprland.desktop.service` record on this machine,
  flagged in round 3, is unchanged and still worth a separate look. Under P2 it
  is additionally now immune to relabelling.

## Validation output — round 4

```
### scripts/check-naming.sh
No legacy upstream naming residue found.
-> exit 0
### python3 scripts/lib/shell_scan.py
shell_scan selftest: ok
-> exit 0
### scripts/check-command-declarations.py
check-command-declarations: ok (67 probed commands, 70 declared, 23 excluded)
-> exit 0
### node --check scripts/check-settings-migration.js
-> exit 0
### scripts/check-settings-migration.js
Marking the notification first-run takeover as already spent for an existing config
Settings migration smoke tests passed.
-> exit 0
### scripts/test-toast-actions.js
Toast action tests passed (4 settingsTab literals resolved).
-> exit 0
### scripts/check-vshell-helper.py
Passwordless sudo disabled
VGS helper smoke tests passed.
-> exit 0
### scripts/check-validation-inventory.py
check-validation-inventory: ok (36 executable checks, 39 documented commands)
-> exit 0
### scripts/check-workflows.sh
check-workflows: ok (4 workflows, run: blocks linted by shellcheck 0.11.0)
-> exit 0
### scripts/check-vshell-ipc.sh
vshell IPC selector checks passed
-> exit 0
### python3 -m py_compile bin/vshell-helper
-> exit 0
### bash -n bin/vshell
-> exit 0
### git diff --check
-> exit 0
```

```
$ WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 \
    scripts/qml-smoke.sh --nested --require-static --require-nested
qml-smoke: static parse check passed (581 QML files)
qml-smoke: starting nested compositor sandbox (runtime dir /run/user/1000/vs.3692061)
qml-smoke: running the shell inside the sandbox (timeout 40s)
qml-smoke: isolated runtime check passed (shell loaded, all 7 bundled plugins loaded, answered IPC in the sandbox)
qml-smoke: ok
qml-smoke: live VGS instances unchanged by validation
qml-smoke: no live VGS layer surfaces to compare (nothing of that kind exists on this system)
-> exit 0
```

`check-settings-migration.js` is unchanged and green — still no new persisted
key, so still no migration and no schema-version claim on v23 or v24.
