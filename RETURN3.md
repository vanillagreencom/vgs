# VGS-66 review findings N1–N4 — RETURN3

Two local commits on `vgs-66`. Nothing pushed, no PR, no threads touched.

- `af9c0d90` frontend(VGS-66): make the headless output transactional and provenance-gated (N1, N2, N4)
- `5af25479` frontend(VGS-66): losing the watch makes the session unknown, not idle (N3)

Files changed: `bin/vshell-helper`, `scripts/check-vshell-helper.py`,
`quickshell/vshell/Services/RemoteDesktopService.qml`,
`config/vshell/plugins/remoteDesktop/RemoteDesktopWidget.qml`,
`scripts/test-remote-desktop-state.js`,
`docs/architecture/remote-desktop.md` — all under
`/home/method/dev/.worktrees/vshell/vgs-66/`.

One note before the findings: the branch was rebased onto main since RETURN2, so
my three earlier commits carry new hashes (`d31d0684` → `3b2fefd7` etc.) and the
QML file count moved 582 → 584 (PR #84's `MeterCard.qml` / `MeterRow.qml`).
Nothing of mine was lost; I verified the three commits are present.

---

## N1 — a failed start leaves an orphaned output

**Changed.** `remote_desktop_start()` tracks a local `created` flag, set only on
the branch that actually ran `hyprctl output create`. If `systemctl start`
subsequently fails, it removes the output and clears the ownership record before
returning the failure.

The rollback is **scoped to what this call created**, which is the same
distinction N2 turns on — hence one commit for both. An output that was already
present when start ran leaves `created` false, so a failed start does not touch
it. Both halves are tested:

- `test_remote_desktop_failed_start_removes_the_output_it_created` asserts the
  exact hyprctl call sequence is `create` then `remove`, that the output is gone,
  and that the record went with it;
- `test_remote_desktop_failed_start_keeps_an_output_it_did_not_create` asserts
  **zero** hyprctl output calls and that the pre-existing output survives.

## N2 — stop removes an output it does not own

**Changed.** `remote_desktop_stop()` now removes the output only when
`_rd_output_is_ours()` is true; otherwise it says so through `manual` and leaves
it.

### Where ownership is recorded

`~/.local/state/vshell/remote-desktop-output.json`, beside the
notification-takeover undo record and for the reason you named: `start` and
`stop` are separate process invocations, so "did we create this?" cannot live in
memory, and without provenance undoing means guessing.

```json
{ "output": "HEADLESS-1", "createdByVgs": true, "instance": "<hyprland signature>", "at": "..." }
```

### Why it cannot go stale

**It is keyed on the Hyprland instance signature.** Headless outputs do not
survive a compositor restart, and the signature changes with every compositor
start — so a record from a previous instance *cannot possibly* describe the
output present now, and `_rd_output_is_ours()` discards it rather than trusting
it. A record with no signature to place it against is not ownership either
(`bool(instance) and ...`), so an unplaceable record can never authorise a
removal.

Both are tested:
`test_remote_desktop_stop_ignores_a_record_from_another_compositor_instance`
starts under instance A, flips the signature to B, and asserts ownership goes
false, the output survives stop, and no hyprctl output command is issued — plus
the empty-signature case.

### What happens if the output vanishes between start and stop

`stop` reads `_rd_output_present()` first:

| Reading | Behaviour |
|---------|-----------|
| `False` (removed by hand) | Nothing to remove, **not an error**, and the record is **dropped** — leaving it would authorise removing a *later* output that happens to carry the same name |
| `None` (hyprctl unanswerable) | Left alone, reported through `manual` |
| `True` + ours | Removed, record cleared |
| `True` + not ours | Left alone, and stop says why |

`test_remote_desktop_stop_drops_the_record_when_the_output_vanished` covers the
first row explicitly, including that the record file is gone afterwards.

### One more decision worth flagging

If the record **cannot be written** at start (read-only state dir, say), start
still succeeds and uses the output, but `stop` will not claim it. That is
deliberate and reported through `manual`: a leaked monitor is one click for the
user to remove, a deleted one cannot be undone, so the unrecordable case fails
toward leaving it. Tested by
`test_remote_desktop_start_reports_an_unrecordable_ownership_claim`.

### Residual limitation, stated not papered over

If the user removes `HEADLESS-1` and creates their own output of the same name
**within the same compositor instance**, the record still matches and stop would
remove theirs. Hyprland exposes no creator for an output, so nothing available
here can tell them apart. It is in the architecture doc.

## N3 — stale session details survive watch loss

**Changed.** The watch-stop handler now calls `_markSessionUnknown(reason)`,
which drops `sessionKnown`, sets `sessionError`, and clears `sessionCount`,
`sessionCodec`, `sessionBitrateBps`, `sessionColorDepth` and `sessionSince` —
values that were only current because something was refreshing them.

It then calls `refresh()` immediately. The status read is a **separate process
that does not depend on the watch**, so it may still answer authoritatively
rather than leaving the widget sitting in unknown until the backoff elapses.

`streaming` is deliberately **not** cleared, because clearing it would claim
"idle" on a dead watcher's say-so — the same rule that stops a single disconnect
from clearing it in L2. So the state is last-known-plus-unconfirmed, and it gets
its own rendering rather than being flattened into either neighbour.

### What the widget renders after watch loss

| Was | Now |
|-----|-----|
| pill `LIVE`, red, filled | pill **`LIVE?`**, red, **unfilled** (`streaming-unconfirmed`) |
| popout header "Streaming now" | "Streaming — unconfirmed" |
| "Somebody is streaming this machine" | "Somebody **may still be** streaming this machine" |
| codec · bitrate · depth subtitle | "nothing is confirming this session right now" |
| Session card with clients/codec/bitrate/since | **hidden** — the fields are cleared, so it would be blank rows; hiding says unknown more honestly |
| tooltip "Someone is streaming this machine — …" | "Someone **may still be** streaming this machine — \<reason\>" |
| — | the uncertainty banner already shown for `!sessionKnown` |

The colour stays `Theme.error`. Softening it to warning would trade a possible
live capture for a tidier bar; the `?` and the unfilled glyph carry the
uncertainty instead. `visualStateFor` tests `streaming` first as before, so an
unconfirmed capture can never fall through to `unknown`, `stale`, `listening`,
`off` or `unavailable` — asserted for all five.

## N4 — TOCTOU in `toggle`

**Both: the window is closed against other invocations, and the actions are
idempotent for the part that cannot be closed.**

- **Closed:** `start`, `stop` and `toggle` run under one `flock` on
  `~/.local/state/vshell/remote-desktop.lock`, and toggle's
  `_user_unit_state(...)["running"]` read is now **inside** that lock. No other
  helper invocation can decide from the same reading and act on it twice.
- **Idempotent:** the lock cannot stop the unit changing on its own — the daemon
  exiting, a client connecting. So `start` returns immediately when the unit is
  already running, and `stop` on an already-stopped unit is a `systemctl stop`
  that exits 0.

### Why the losing path touches no output

That was the part worth getting right given N1/N2. `start`'s early return
happens **before** any compositor call, so a lost race creates nothing — which is
also correct on the merits: a running host has already chosen its capture target
at startup, so a second virtual output would be a phantom monitor and change
nothing else. On the `stop` side the output half is gated on ownership
regardless of who won.

`test_remote_desktop_start_is_idempotent_when_the_host_is_already_running`
asserts zero hyprctl calls **and** zero systemctl calls, plus that the no-op is
reported rather than silently succeeding.

---

## Regression coverage

Seven new cases in `scripts/check-vshell-helper.py`, and the `_rd_lifecycle`
harness was reworked to run under a **real temp `HOME`**, so the ownership record
is genuinely written to and read from disk rather than stubbed. The record is
what decides whether a user's own output gets deleted; stubbing it would test the
wrong thing.

`scripts/test-remote-desktop-state.js` gained the N3 cases. One existing
assertion needed care: it read `_markStatusUnknown`'s literal body for
`sessionKnown = false`, which now reaches that flag by delegating to
`_markSessionUnknown`. I made it follow the delegation rather than weakening it —
so it still goes red if the delegate stops clearing.

### Mutation proof — seven mutations, all red, restored green

```
### N1 — failed start leaves the output it created
AssertionError: the output created for this start must be rolled back: expected False, got True
exit=1
### N2 — stop removes any present output (ownership gate removed)
AssertionError: an output VGS did not create must survive stop: expected True, got False
exit=1
### N2 — instance signature ignored
AssertionError: a record from a previous compositor instance is not ownership: expected False, got True
exit=1
### N4 — start not idempotent for a running host
AssertionError: no output is created for a host already running: expected [], got [['hyprctl', 'output', 'create', 'headless']]
exit=1
### N3 — watch loss leaves session state standing
AssertionError: the watch-stop handler must mark the session unknown, not leave the cached values standing
exit=1
### N3 — unconfirmed capture renders as plain LIVE
AssertionError: a dead watch must not let a plain LIVE stand on its last message
exit=1
### N3 — _markSessionUnknown clears streaming (claims idle)
AssertionError: exactly one site may clear `streaming`, and it is the authoritative status apply
exit=1
### RESTORED
helper ok
Remote desktop state checks passed.
```

The last one is worth noting: mutating `_markSessionUnknown` to clear
`streaming` was caught by the round-2 "exactly one site may clear streaming"
assertion, which I had not written with this case in mind. The invariant
generalised.

## Verified vs reasoned

**Verified:**
- all seven mutations above, each red, restored green;
- the seven helper cases against a real temp HOME — the record file is written,
  read back, matched on signature, and deleted, on disk;
- the full validation suite below;
- **the nested smoke ran again and passed** (see below);
- read-only: no `remote-desktop` state file exists under
  `~/.local/state/vshell/` on this machine, confirming nothing I ran executed a
  lifecycle command against the live session.

**Reasoned, not executed:**
- **no headless output was created or removed on this machine, and Sunshine was
  never started or stopped.** N1, N2 and N4 are all tested through the helper's
  own harness with `hyprctl` and `systemctl` faked. The real `hyprctl output
  create/remove` round trip, and what Hyprland does to an instance signature
  across a compositor restart, are reasoned from the dotfiles script and from
  Hyprland's documented behaviour — not observed here.
- the `flock` serialises correctly under genuine concurrency. It is the same
  pattern as `clipboard_state_lock()` in this helper, but I did not run two
  toggles in parallel.
- N3's rendering is unexercised visually; the state machine is tested, the pixels
  are not.
- `hyprctl` is not reachable from this agent shell (no
  `HYPRLAND_INSTANCE_SIGNATURE`), so `_rd_hypr_instance()` returning a real
  signature is reasoned from `_rd_hypr_env()`'s runtime-dir scan, which is
  unchanged from the original commit.

## Validation

```
### scripts/check-naming.sh
No legacy upstream naming residue found.
exit=0
### python3 scripts/lib/shell_scan.py
shell_scan selftest: ok
exit=0
### scripts/check-command-declarations.py
check-command-declarations: ok (67 probed commands, 71 declared, 23 excluded)
exit=0
### scripts/test-bundled-override.js
bundled-override policy checks passed
exit=0
### scripts/test-remote-desktop-state.js
Remote desktop state checks passed.
exit=0
### scripts/check-validation-inventory.py
check-validation-inventory: ok (36 executable checks, 39 documented commands)
exit=0
### scripts/check-package-assets.sh
theme catalog up to date (79 themes)
theme catalog: tree matches pinned ref v0.1.0
package asset split checks passed
exit=0
### scripts/gen-package-metadata.py
packaging optional dependencies verified (arch 49, debian 40, fedora 37, gentoo 33)
hard dependencies verified for every shipped channel: arch 11, debian 11, fedora 13, gentoo 9, void 10, nix 10
notification daemon conflicts verified: arch 3, debian 3, fedora 4, gentoo 2, void 3
exit=0
### git diff --check
exit=0
### python3 -m py_compile bin/vshell-helper
exit=0
### bash -n bin/vshell
exit=0
### scripts/check-workflows.sh
check-workflows: ok (4 workflows, run: blocks linted by shellcheck 0.11.0)
exit=0
### scripts/check-vshell-helper.py
VGS helper smoke tests passed.
exit=0
### scripts/qml-smoke.sh --require-static
qml-smoke: static parse check passed (584 QML files)
qml-smoke: runtime check not requested (pass --nested for the sandboxed shell run)
qml-smoke: ok
exit=0
```

### Nested smoke — ran, passed

```
$ WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 \
    scripts/qml-smoke.sh --nested --require-static --require-nested
qml-smoke: static parse check passed (584 QML files)
qml-smoke: starting nested compositor sandbox (runtime dir /run/user/1000/vs.3613836)
qml-smoke: running the shell inside the sandbox (timeout 40s)
qml-smoke: isolated runtime check passed (shell loaded, all 8 bundled plugins loaded, answered IPC in the sandbox)
qml-smoke: ok
exit=0
```

Same caveat as RETURN2, and it applies directly to N3: the sandbox loads bundled
plugins but **never places one in a bar**, so `RemoteDesktopWidget` is not
instantiated, no binding is evaluated, and `Ref` never raises
`RemoteDesktopService.refCount` — the watch never starts, so the watch-loss path
is not exercised there. It proves the QML compiles and loads in a real shell with
no runtime errors; it does not execute N3. That is the VGS-19 limitation the
state test exists to cover.

```
### scripts/check-validation-safety.sh
check-validation-safety: VGS Quickshell instances unchanged by validation
check-validation-safety: no VGS layer surfaces to compare (nothing of that kind exists on this system)
check-validation-safety: ok
exit=0
```

`smoke-surfaces.sh` not run. No Sunshine start/stop, no headless output created
or removed.

## Gaps

1. **No real compositor round trip for N1/N2.** Everything is proven against
   faked `hyprctl`/`systemctl`. Proving it for real means creating and removing a
   monitor on the user's live session, which the brief forbids and which I agree
   should not happen from an agent.
2. **The same-instance name-collision case is unclosable** (see N2, residual
   limitation). Documented rather than fixed, because Hyprland exposes no
   creator for an output. Worth filing if you want a different approach — e.g.
   giving the VGS-created output a distinctive name instead of the conventional
   `HEADLESS-1`, which would make ownership intrinsic rather than recorded. That
   is a behaviour change affecting the dotfiles script and the monitor rule in
   `config/monitors.lua`, so I did not take it unilaterally.
3. **The lock is not tested under concurrency.** Structural only.
4. **N3's `refresh()` on watch loss is not rate-limited beyond the existing
   coalescing.** A watch that flaps rapidly would call `refresh()` per flap;
   `_refreshPending` collapses those into one in-flight probe plus one
   follow-up, so it is bounded, but I did not measure it.
5. Carried from RETURN2 and still open: the **multi-client disconnect fixture**
   (`count = max(0, count - 1)`) has no test, because this host has only ever
   logged `active sessions: 1` and I would be inventing the log shape.
