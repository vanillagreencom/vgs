# Runtime memory

Covers: quickshell/vshell, scripts/sample-shell-memory.sh

The shell's resident size grows for the life of a session. This file records where that memory sits, how to measure it, and what a measurement can and cannot attribute. `scripts/sample-shell-memory.sh` is the sampler; it reads `/proc` and never signals, restarts or drives the shell.

## Vocabulary

- Anonymous memory: pages with no file behind them. The native C++ heap lives here.
- JavaScript heap: the QML engine's garbage-collected heap. It is a `memfd:JSGCHeap:QtQml` mapping, so `/proc/<pid>/smaps` separates it from anonymous memory by name.
- Retained: freed by the program but not yet returned to the kernel by the allocator. Retained pages count toward resident size.
- Transparent huge page: a 2 MiB page the kernel substitutes for 512 small ones. A huge page is resident in full even where the program touched one 4 KiB region of it.

## Where the memory sits

Class shares are read by matching the mapping name in `/proc/<pid>/smaps`. The sampler writes one column per class.

| Class | Matched by | Grows |
|---|---|---|
| Anonymous | no mapping name | yes |
| JavaScript heap | `JSGCHeap` | no, it oscillates |
| Compiled QML | `JITCode`, `JSVMStack` | negligible |
| GPU driver | `nvidia`, `renderD`, `/dri/` | no |
| Fonts and other files | every other name, including Qt's remaining memfd mappings and the bracketed kernel ones | no |

## Boundaries

- Quickshell links jemalloc, not the system allocator. `ldd /usr/bin/quickshell` names it. VGS sets no `MALLOC_CONF`, so jemalloc runs on its build defaults and VGS owns none of its tuning.
- jemalloc purges retained pages lazily and only on activity in the arena that holds them. Resident size therefore reports live data plus retained data, and falls in steps rather than smoothly.
- The kernel's transparent huge pages are enabled system-wide, so a retained region that is 2 MiB aligned and large enough is backed by huge pages and counts toward resident size in full. Part of retained memory is amplified this way, not all of it: the table below puts roughly half of anonymous memory in huge pages.
- Resident size is not a leak measurement. The high-water mark in `/proc/<pid>/status` (`VmHWM`) is the number a session actually reached; the current value can be far below it.

## Invariants

- Growth is in anonymous memory. Anonymous memory rises in every sample. The JavaScript heap holds one value for long stretches, moves by a couple of megabytes, and comes back, so it oscillates rather than trends. A QML object count or a JavaScript heap snapshot therefore measures none of the growth, and the native heap owns all of it.
- Growth is on the main QML thread and the Wayland event threads. The scene-graph render threads are the CPU cost and not the growth, so a frame-rate or repaint change addresses neither.
- The mapping count stays flat while memory grows. New bytes land inside extents jemalloc already holds, so a count of mappings is not a growth signal.
- File descriptors and thread count stay flat. Neither is a growth signal.
- A growth rate needs a window of at least 600 s. Per-minute deltas swing between negative and several megabytes, so a shorter window reports sampling noise. `--report` refuses to state a rate below that window.

## Measured state

One unbroken session on the owner's machine, read at 76 h of uptime, on the installed Quickshell 0.3.1 package, with three monitors and 43 threads. The sampler re-derives every row; the high-water mark is its `hwm_kb` column, read from `/proc/<pid>/status`, and never the peak among logged samples, which starts when the operator starts sampling. These describe one machine, not a contract.

| Reading | Value |
|---|---|
| Resident size | 1,466 MiB |
| High-water mark (`VmHWM`) | 2,226 MiB |
| Anonymous | 1,163 MiB |
| In transparent huge pages | 652 MiB |
| JavaScript heap | 27 MiB |
| GPU driver mappings | 147 MiB |
| Swap | 0 |

Growth with the desktop untouched, from 36 minute-by-minute samples over 35 minutes, in which anonymous memory rose 50.7 MiB. Each of the 26 ten-minute windows inside that run was measured separately; resident size tracked anonymous memory to within 1 MiB throughout:

| Ten-minute windows | Rate |
|---|---|
| Slowest | 66 MiB/h |
| Median | 88 MiB/h |
| Fastest | 118 MiB/h |

Per-minute deltas ran from -1.1 MiB to +5.2 MiB with a median of +1.3 MiB, and 2 of the 35 were negative. This is a trend and not a constant.

The rate does not extrapolate. At even its slowest, 76 hours would reach far past the high-water mark of 2,226 MiB. Resident size instead peaked below that and fell back, which is what jemalloc's lazy purge produces. Growth over a session is a sawtooth, not a line.

Class attribution over a 20-minute window of eleven samples: anonymous memory grew 30.7 MiB and rose at every one of the ten steps, with no reversal. The JavaScript heap ended 0.9 MiB up, having held one exact value for eight samples, moved 2.4 MiB, then come most of the way back; font mappings did the same and returned to their starting value. GPU mappings did not move by one kilobyte. Compiled QML moved 36 KiB across the whole window.

Continuous cost with no user interaction: three scene-graph render threads at about 1.1% of one core each, plus the main thread at 0.9%. Fifteen render threads exist and three are busy, matching the monitor count. Which window each thread serves is not readable from `/proc`.

Thread attribution over a 7-minute window in which anonymous memory grew 8.8 MiB, counting the minor page faults that first touch a new page:

| Thread | Minor faults | CPU ticks |
|---|---|---|
| Main QML thread | 2,783 | 384 |
| Wayland event threads (two) | 1,696 | 162 |
| Worker pool threads | 71 | 1 |
| All fifteen render threads | 21 | 1,443 |

The render threads spend the most CPU and touch almost no new memory. The main QML thread and the two Wayland event threads touch nearly all of it. Rendering is therefore the shell's continuous CPU cost and not its memory growth.

## Sampling

```
scripts/sample-shell-memory.sh --hours 26        # log a session
scripts/sample-shell-memory.sh --report FILE     # print the baseline
```

The sampler asks the instance registry `bin/vshell instances list` owns which process is the running shell, and refuses on any answer but exactly one. That listing is scoped to one shell entrypoint, so `--shell-path` addresses a shell launched from a different checkout than the one the sampler runs from.

Every sample row carries the sampled process and its start time, so one session is told from the next that reuses its process id. Sampling refuses to append to a log whose last row names a different session, rather than extending someone else's series. `--report` reads only the newest session in a log and says how many rows and sessions it left out, and it refuses every mark and rate for a session whose uptime does not run forward.

`--report` prints the process high-water mark beside the peak among logged samples, which is lower whenever sampling started after the peak. It prints one `mark=` line for each of 1 h, 8 h and 24 h of uptime and for the last sample. A mark the session never reached is `status=not-reached`. A mark it passed with no sample close enough to answer it is `status=no-sample-within`, so a mark is never filled from a sample hours away. Between each consecutive pair of marks that both exist it prints a `rate=` line naming the two uptimes it spans, and where that span is under 600 s it prints `status=span-under-floor` and no rate. Filling all three marks needs a session that starts while the sampler runs.

## What sampling cannot attribute

`/proc` says which memory class grows. It does not say which C++ type allocated it. Naming the owning allocation site needs a heap profiler in the process, which means either a jemalloc profiling build or an interposing allocator, and either one requires starting the shell under it. On the live desktop that is a restart, so no read-only method reaches it.

## Candidates

Each entry below is a place where VGS code retains memory without a bound. Every one runs on the main QML thread, which the thread attribution above names as a growth site, but none is yet tied by measurement to a share of that rate. The paths are relative to `quickshell/vshell/`.

Nothing in VGS code accounts for the Wayland event threads' share. Those threads run Qt's own Wayland client and no VGS code, so that share is either Quickshell's surface handling or Qt's, and reaching it needs the in-process profiler this file says is out of read-only range.

- `Common/Proc.qml`: `_procDebouncers` deletes an entry only when the caller passed no id. A named id keeps its `Timer` object and its last callback closure for the life of the session. `Services/NiriService.qml` mints a new id from a counter on every output apply, so every call adds one permanent entry. `Services/IconThemeService.qml` keys on the icon name, so every first-time icon resolve adds one.
- `Services/IconThemeService.qml`: `_cache` holds one entry per distinct icon name resolved and is cleared only when the icon theme changes. Notification icons come from arbitrary applications, so the key set is open.
- `Modules/ControlCenter/Models/WidgetModel.qml`: `getPluginWidgets()` instantiates every plugin widget to read one property, then destroys it. `Modules/ControlCenter/ControlCenterPopout.qml` calls it from the `availableWidgets` binding, which the running shell reports as a binding loop, so the instantiate-and-destroy cycle repeats while Control Center edit mode is open.
- `Modules/ControlCenter/Components/DetailHost.qml` and `Modules/Settings/WindowRulesTab.qml`: each open connects a fresh closure to a long-lived object and never disconnects. The handler count grows with the number of opens, and every accumulated handler runs on each later signal.
- `Services/NotificationService.qml`: count-based history eviction drops the entry without deleting the notification's cached image, so the image cache directory grows with lifetime notification volume. This is disk, not memory.
- `Services/NotepadStorageService.qml`: `createEmptyFile` leaves its holder object parented to the singleton with no `destroy()`.

## Decisions

None. The allocator choice belongs to the Quickshell package, not to VGS.
