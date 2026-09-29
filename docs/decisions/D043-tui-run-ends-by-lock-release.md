# D043: TUI run ends by lock release

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active (wait lock → [D045](D045-tui-wait-holds-a-per-run-lock.md))

**Research**: VGS-576: offscreen qml6 FolderListModel lost-change probe

**Refines**: [D033](D033-floating-tuis-are-core.md)

**Context**: [D033](D033-floating-tuis-are-core.md) made the presenter write a running record before the command and an ended record after it. The core read those records through one `FolderListModel`. Qt 6.11.2 can lose the directory change that adds the ended record: `src/labs/folderlistmodel/fileinfothread.cpp` `FileInfoThread::dirChanged()` calls `condition.wakeAll()` without setting `needUpdate`, so a wake between the scan thread's unlock and its next wait is lost. VGS-576 records an offscreen qml6 probe: a FolderListModel listed a directory while a script wrote, renamed and removed the presenter's record sequence 500 times, with the probe pinned by taskset to one core under load. The probe missed 1 run in 500, and the listing stayed stale for the full 2 s wait. When that lost change is a run's ended record, the core keeps the key busy and never calls the run's `done`.

**Decision**: The core treats the presenter's key lock release as the per-run completion signal. `vgsh-tui wait --record <key> --run <run>` validates the key and run, opens `<stem>.lock`, blocks in `flock` until the presenter releases it, and then prints the run's ended record. If the ended record is absent but the running record is present, `wait` writes the same null-code ended record as `reap` and prints it. `shell/Core/TuiRecords.qml` starts one wait process for each launched run whose launcher exits 0, and for each running record it reads after a shell restart. The FolderListModel listing remains the fast path. A wait result joins the same bounded record set as listed files, and a done callback is delivered once.

**Rationale**:

- The presenter already holds the lock for the exact lifetime the core needs to observe.
- `flock` blocks in the kernel, so the core adds no timer and no CPU work while no run is live.
- A shell restart can still learn a run that was already live, because the running record names the key and run and the lock file survives as the path to wait on.
- The ended record stays the one data shape. Callers and `shell.tui.state` do not get a second completion channel.
- `scripts/test-vgsh-tui.sh` measured 0 ms on cachy x86_64 on 2026-09-29, from the shell's reap of the presenter to its reap of wait. A value of 0 means under 1 ms at the measurement resolution. The test pins a 1000 ms ceiling.

## Where VGS differs from Omarchy

Omarchy's `omarchy-update` ends by running `omarchy-update-status`, which tells the shell's update indicator over IPC to refresh (basecamp/omarchy `e332dc97`, `bin/omarchy-update-status`). VGS does not make a TUI script call back into the shell. An IPC push can be lost during a shell restart, and it makes the script name its caller. VGS waits on a lock the presenter already holds and reads one record the core owns.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| A bounded reconcile timer while a run is live | It polls, adds latency up to the interval, and still makes the directory listing the thing that must eventually notice the file. |
| Presenter pushes an IPC call at its end, like Omarchy's update status helper | A shell restart can drop the call, and the script must know which shell feature opened it. |
| Replace `FolderListModel` with one Quickshell `FileView` watch for a run's ended path | It still needs a fallback for a presenter that dies with only a running record, and FileView does not watch a file whose directory is absent when the view is built ([runtime-qml.md](../architecture/runtime-qml.md)). The lock covers both normal ends and dead presenters. |
| Add an inotify helper process for the directory | It adds another watcher whose only job is to work around a Qt watcher defect. The lock already carries the needed lifetime. |

**Revisit When**: Qt fixes `FileInfoThread::dirChanged()` so the directory watcher cannot lose a wake, and VGS confirms the fix under the same offscreen lost-change probe.

**Verification**: `scripts/test-vgsh-tui.sh` proves `wait` blocks while the presenter holds the lock, exits within the measured ceiling after release, prints the ended record, ends a dead presenter's running record, refuses a gone run, and has controls for skipping the lock and skipping the dead-run end. `scripts/test-tui-logic.js` pins which runs need waits and which wait stdout the core accepts, with controls. `scripts/qml-tests/tst_tui_records.qml` drives a stand-in `FolderListModel` that drops the ended-record change and a stand-in `Process` that finishes the wait by hand; the run's `done` fires once, the key stops being running, and no wait process remains.

**References**: [D033](D033-floating-tuis-are-core.md), [runtime-qml.md](../architecture/runtime-qml.md), [tui-capability.md](../architecture/tui-capability.md)
