# D003: System tray transport stays Quickshell's native `SystemTray`

[← Decision Index](INDEX.md)

**Date**: 2026-08-04
**Status**: Active
**Research**: —
**Applies to**: `quickshell/vshell/Modules/Bar/Widgets/SystemTrayBar.qml`, StatusNotifierItem/DBusMenu handling
**Decided by**: **an agent, not a human.** No reviewer was available in the run
that produced this (VGS-48). The reasoning below is complete enough to argue
with; the owner should confirm or overturn it rather than treat it as settled
by authority.

## Summary

`SystemTrayBar.qml` carried an untracked TODO proposing that the tray be
replaced with "either a native dbus client (like plugins use) or just a VGS
cli". Neither option is taken. The tray keeps Quickshell's in-process
`Quickshell.Services.SystemTray` host as the StatusNotifierItem (SNI) client
the shell reads all tray state from.

The TODO also mislabels its own subject. The tray's *transport* is already
native: items, icons, tooltips and menus all come from Quickshell's
StatusNotifierHost, and VGS renders menus itself from each item's `menu`
(DBusMenu) handle. Exactly one call escapes that: `callContextMenuFallback`,
used when an item exports **no** DBusMenu (`hasMenu === false`) and the SNI
spec's `ContextMenu(x, y)` method is the only way to ask the application to
show its own menu. Quickshell 0.3.0 does not expose that method, so VGS shells
out. So the question is not "what transport should the tray use" but "who
should make one call that Quickshell cannot make for us" — and the honest
answer is that the missing piece belongs upstream.

## Context

### What exists today

- `Quickshell.Services.SystemTray` runs inside the shell process and is the
  StatusNotifierHost. `SystemTray.items.values` drives the whole widget
  (`SystemTrayBar.qml`'s `allTrayItems`), and `VGSIPC.qml`'s `tray` handler
  (`list`/`activate`/`status`) reads the same collection.
- Menus for items that export a DBusMenu are built by VGS from `item.menu`,
  not by `display()`.
- `callContextMenuFallback(trayItemId, globalX, globalY)` is reached from the
  three right-click paths in `SystemTrayBar.qml` that are guarded by
  `!trayItem.hasMenu` (`rg -n callContextMenuFallback` finds the definition and
  all three). It runs `Quickshell.execDetached(["bash", "-c", …])` on
  a 13-line script that: reads `RegisteredStatusNotifierItems` off
  `org.kde.StatusNotifierWatcher` with `dbus-send`, splits the result with
  shell parameter expansion, runs another `dbus-send` per registered item to
  read its `Id` through `grep -oP`, and calls
  `org.kde.StatusNotifierItem.ContextMenu` on the **first** item whose `Id`
  matches.

### What is actually wrong with it

The TODO asserts a problem without naming one. There are four, and only the
last is about transport:

1. **It matches on a non-unique key.** SNI `Id` is application-unique, not
   item-unique. This repo already knows that: `getTrayItemKey()`
   (`SystemTrayBar.qml`) and the `tray` IPC handler both compose
   `id::tooltipTitle` precisely because `id` alone collides. The fallback matches `Id` and takes
   the first hit, so with two items from the same application the wrong one is
   asked to open its menu.
2. **It re-derives state the shell already holds.** The watcher registry is
   walked again, from a subprocess, while Quickshell's host already tracks
   every registered item. To be precise about the rule this does *not* break:
   AGENTS.md § Backend rules forbids a second *watcher/daemon/poller*, and a
   one-shot query fired on a right-click is none of those — it is redundant,
   not a policy violation. It matters here only because the redundancy is what
   forces the lookup to be keyed on `Id`, which is defect 1.
3. **It fails silently.** `execDetached` has no exit status and no stderr
   capture. A missing `dbus-send`, a `grep` without PCRE, or no `Id` match all
   produce a right-click that does nothing and says nothing — the same class of
   defect as VGS-11's no-op clicks.
4. **It cannot be fixed in place, by anyone.** Quickshell 0.3.0's
   `SystemTrayItem` exposes `activate()`, `secondaryActivate()`, `scroll()`,
   `display()` and `hasMenu`/`onlyMenu`/`menu` — no `ContextMenu`, and **no
   bus name or object path**. So nothing in-process can make the call, and
   nothing out-of-process can be told which item to make it on except by the
   ambiguous `Id`. Every out-of-process option inherits defect 1.

## Decision

**No transport change.** Quickshell's `SystemTray` remains the tray's only
transport. The `ContextMenu` fallback stays as it is, now documented as a
known-lossy workaround for an upstream gap rather than as an open question in
a code comment.

The gap is pursued where it can actually be closed: ask Quickshell for
`SystemTrayItem.contextMenu(x, y)`, or failing that for the item's `service`
and `objectPath`. Either one dissolves the problem — the first removes the
subprocess entirely, the second makes an out-of-process call unambiguous and
therefore worth having.

## Rationale

All three columns keep the redundant registry walk, because none of them can
learn the item's bus name from Quickshell. The differences are elsewhere:

| Criterion | Chosen (no change, fix upstream) | CLI route | Backend method |
|-----------|----------------------------------|-----------|----------------|
| Fixes the ambiguous-`Id` root cause | Yes, once upstream lands | No | No |
| Redundant registry walk | Kept, in QML's subprocess | Kept, moved into the helper | Kept, moved into the daemon |
| Per-right-click process spawn | One `bash` | One Python helper instead (heavier start) | None — a socket call |
| New surface to maintain and later delete | None | A `vshell` verb | A method + capability + inventory entry + QML gate |
| Direction of travel for tray IPC | Unchanged | Inverted (see below) | New |
| Work now | Comment + this record | Moderate | Larger |

The backend column is the technically tidiest of the three — no spawn, real
argv, godbus instead of `dbus-send`. It is still rejected below, on surface
cost and on the fact that it does not fix the defect that matters.

The direction point is concrete: `vshell ipc call tray activate|list|status`
already runs **CLI → shell** (the `tray` `IpcHandler` in `VGSIPC.qml`).
Routing a tray action shell → CLI would make the shell shell out to a tool
whose existing tray verbs
call back into the shell, for a call the shell is already the right process to
make.

## Alternatives Considered

| Alternative | Why rejected |
|-------------|--------------|
| **Native D-Bus client in QML "like plugins use"** (the TODO's first option) | The premise is false in both halves. None of the seven bundled plugins under `config/vshell/plugins/` uses D-Bus at all, and Quickshell 0.3.0 exposes no general-purpose session-bus client to QML — only typed services (`SystemTray`, `DBusMenu`, notifications, MPRIS). Taking this option means writing a C++ Quickshell plugin, which is strictly more work than the upstream request that would benefit every Quickshell user. |
| **`vshell tray context-menu <id> <x> <y>` in `bin/vshell-helper`** (the TODO's second option) | Genuinely improves two things — the quadruple-escaped bash disappears from a QML string literal, and the code lands under `py_compile` + `scripts/check-vshell-helper.py` — but it moves the registry walk rather than removing it, keeps the first-`Id`-wins misfire, swaps the `bash` spawn for a heavier Python one, and adds a CLI verb that exists only to be deleted when upstream lands. Rejected on that last point alone: this is a workaround, and a workaround should not grow a public surface. **Kept as the fallback plan** if it has to live longer than expected. |
| **`tray.contextMenu` method on the Go backend** | The daemon already exists and already owns D-Bus-facing system services, so this adds no process — the objection is not "a second daemon". It is that the D-Bus surface it would add is the opposite of the one the backend has deliberately built: `backend/internal/services/dbusbridge/dbusbridge.go` allowlists exactly one system-bus signal (`login1 PrepareForSleep`) and rejects everything else, so this means a session-bus connection plus an SNI registry walk, a method, a capability, an inventory entry and a QML gate with a fallback — permanent, documented API for one rarely-hit call that would still guess between same-`Id` items and would still be deleted when upstream lands. |
| **Delete the fallback outright** | Simplest, and defensible: right-click would silently do nothing for menu-less items instead of possibly hitting the wrong one. Rejected because the common case (one item per application) works today, and a regression for those users buys only tidiness. |

## Consequences

- Right-click on an item that exports no DBusMenu keeps working for the common
  case, and keeps being able to hit the wrong item when one application
  registers several. That is now a written-down, accepted limitation instead of
  an undocumented surprise.
- No new capability, CLI verb or backend method is introduced, and
  nothing new has to be deprecated when upstream closes the gap.
- The TODO above `callContextMenuFallback` is replaced by a `REVISIT(D003)` pointer,
  so the intention is visible to planning rather than only to whoever opens
  that file.

## Verification

This decision changes no runtime behaviour, so it is verified by the absence of
change plus the usual static suite:

```bash
scripts/check-naming.sh
scripts/qml-smoke.sh --nested --require-static
git diff --check
```

## Revisit When

- Quickshell exposes `SystemTrayItem.contextMenu(x, y)` — then delete
  `callContextMenuFallback` and call it directly. This is the outcome to aim
  for.
- Quickshell exposes an item's `service`/`objectPath` — then an out-of-process
  call becomes unambiguous, and the CLI route above becomes worth taking.
- A duplicate-`Id` misfire is reported in the wild — then move the script to
  `bin/vshell-helper` as a stopgap and match on `id::tooltipTitle` (the key the
  rest of the widget already uses) instead of `Id`.
- The fallback needs any further logic. Any growth at all belongs in the
  helper, not in a bash string embedded in QML.

## References

- Issue: VGS-48
- `quickshell/vshell/Modules/Bar/Widgets/SystemTrayBar.qml`
- `quickshell/vshell/VGSIPC.qml` (`tray` IPC handler)
- `backend/internal/services/dbusbridge/dbusbridge.go` (the allowlisted D-Bus bridge)
- `docs/architecture/backend-daemon.md`, `docs/architecture/shell-architecture.md`
- Quickshell 0.3.0 `SystemTrayItem` API: <https://quickshell.org/docs/v0.3.0/types/Quickshell.Services.SystemTray/SystemTrayItem>
