# Runtime memory

Covers: quickshell/vshell, scripts/sample-shell-memory.sh, scripts/attribute-heap-profile.py

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
- Page faults that first touch new memory are on the main QML thread and the Wayland event threads. The scene-graph render threads are the CPU cost and not the growth, so a frame-rate or repaint change addresses neither. A fault count is not retained memory: in the heap profile below, the continuing retained growth is on the Wayland event threads, beside one step on a GPU driver thread.
- The mapping count stays flat while memory grows. New bytes land inside extents jemalloc already holds, so a count of mappings is not a growth signal.
- File descriptors and thread count stay flat. Neither is a growth signal.
- A growth rate needs a window of at least 600 s. Per-minute deltas swing between negative and several megabytes, so a shorter window reports sampling noise. `--report` states one rate over the session span its log covers and one between each pair of marks, and reports `status=span-under-floor` in place of any rate whose span falls below that window.

## Measured state

One unbroken session on the owner's machine, read at 76 h of uptime, on the installed Quickshell 0.3.1 package, with three monitors and 43 threads. These describe one machine, not a contract. Only the high-water mark is expected to reproduce exactly, because it never decreases while the session runs; every other row moves as the session goes on. The sampler reads it from `/proc/<pid>/status` into its `hwm_kb` column and reports it separately from the peak among logged samples, which is lower whenever sampling started after the peak.

| Reading | Value |
|---|---|
| Resident size | 1,466 MiB |
| High-water mark (`VmHWM`) | 2,225 MiB |
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

The rate does not extrapolate. At even its slowest, 76 hours would reach far past the high-water mark of 2,225 MiB. Resident size instead peaked below that and fell back, which is what jemalloc's lazy purge produces. Growth over a session is a sawtooth, not a line.

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

### Heap profile

One session ran under jemalloc heap profiling, with Quickshell 0.3.1, Qt 6.11.2, libwayland 1.26.0 and the NVIDIA 610.57.04 driver. The owner used the desktop for the first 8 minutes. Agent terminals kept running for the whole session. The shell journal shows the screensaver running for about a second at 15 and 22 minutes of uptime, starting again at 26 minutes, and the session locking at 32 minutes, and no unlock before the session ended. The lock was held across Quickshell's configuration reloads at 34 minutes; the first reload ran at 8 minutes. Every figure from 32 minutes on was measured with the lock surfaces up. Byte figures are jemalloc's sampled estimates at one sample per 512 KiB allocated on average; the samples column is the count at the later dump.

Net growth between the dumps at 32 and 169 minutes of uptime:

| Thread | Net growth | Samples |
|---|---|---|
| Wayland event threads (two) | 234.6 MiB | 543 |
| `CPMMListener`, started by the NVIDIA EGL library | 255.4 MiB | 29 |
| Main QML thread | -6.4 MiB | 281 |
| All other threads | -3.5 MiB | 246 |

The `CPMMListener` growth is one step between the dumps at 35 and 42 minutes, after the reloads at 34 minutes. It holds 256 to 258 MiB in every later dump.

Every sampled Wayland event thread byte at 169 minutes sits in one call stack: `zalloc` in `wl_closure_init`, called from `wl_connection_demarshal`, under `wl_display_read_events` in `QtWaylandClient::EventThread::run()`. libwayland-client allocates that closure for each event it reads, puts it on the event queue of the receiving object, and frees it only when that queue is dispatched or released. The retained bytes are therefore events read from the compositor and not dispatched by the time of the dump. The profile does not name the queue that holds them, so it cannot tell which surface's events fill it.

A reload released it. The Wayland event threads held 40.0 MiB in the dump at 05:48:16 UTC, two seconds after a reload began, and 0 in the dump one second later. From 42 to 169 minutes of uptime, after the last reload, they rose in each of the twelve dump intervals, from 17.5 MiB to 271.6 MiB. Over that span they grew 254.1 MiB, 120 MiB/h, which is 93.8% of the process's net heap growth of 270.7 MiB. Up to the first reload they held at most 0.5 MiB, but that stretch is also the one the owner used the desktop in, so this run does not separate the two causes. Before the lock they grew too, in the same call stack: from 6.0 MiB at 11 minutes to 37.0 MiB at 32 minutes, 31.0 MiB at 90 MiB/h, with 74 samples at 32 minutes. The later of those dumps was written 75 ms before the journal confirmed the lock, and the screensaver ran from 26 minutes of that stretch, so the lock screen is not required for the growth.

`jeprof --inuse_space --focus=wl_display_read_events` reports 234.6 MiB between the dumps at 32 and 169 minutes and 254.6 MiB between those at 42 and 169 minutes. Between the thread snapshots at 30 minutes and 3 hours, the threads alive in both took 194,881 minor faults: 72.6% on the main QML thread, whose live heap shrank between the dumps, and 18.5% on the Wayland event threads, which hold the growth.

## Sampling

```
scripts/sample-shell-memory.sh --hours 26        # log a session
scripts/sample-shell-memory.sh --report FILE     # print the baseline
```

The sampler asks the instance registry `bin/vshell instances list` owns which process is the running shell, and refuses on any answer but exactly one. That listing is scoped to one shell entrypoint, so `--shell-path` addresses a shell launched from a different checkout than the one the sampler runs from.

Every sample row carries the sampled process and its start time, so one session is told from the next that reuses its process id. Sampling refuses to append to a log whose last row names a different session, rather than extending someone else's series. `--report` reads only the newest session in a log and says how many rows and sessions it left out, and it refuses every mark and rate for a session whose uptime does not run forward.

`--report` prints the process high-water mark beside the peak among logged samples, which is lower whenever sampling started after the peak. It prints one `mark=` line for each of 1 h, 8 h and 24 h of uptime and for the last sample. A mark the session never reached is `status=not-reached`. A mark it passed with no sample close enough to answer it is `status=no-sample-within`, so a mark is never filled from a sample hours away. It prints a `rate=window` line over the whole span the log covers, then one `rate=` line between each consecutive pair of marks that both exist. Every rate names the two uptimes it spans, and where a span is under 600 s the line carries `status=span-under-floor` instead of a rate. The window rate is what a log of a session the sampler joined late still reports, since such a log fills only the last mark and one mark forms no pair. Filling all three marks needs a session that starts while the sampler runs.

## What sampling cannot attribute

`/proc` says which memory class grows. It does not say which C++ type allocated it. That needs jemalloc's heap profiler, which only runs in a shell started with profiling in its environment. On the live desktop that start is a restart, so no read-only method reaches it.

`scripts/attribute-heap-profile.py BASE HEAD` reads two dumps from one profiled session. It prints each thread's net growth and share, then breaks one thread's growth down by call stack and by the library that made the allocation. `--thread` selects the thread by name, `WaylandEventThr` by default. It symbolizes through `eu-addr2line` against the dump's own mappings, so the packages on disk must be the ones that ran. The installed libraries are stripped: set `DEBUGINFOD_URLS` so local functions resolve, or they take the name of the nearest exported symbol and the frame row carries `resolution=symbol-table-only`.

The profiler's own bookkeeping is anonymous memory, so resident size in a profiled session is not the shell's growth rate. Attribution reads dump bytes only.

## Candidates

Each entry below is a place where VGS code retains memory without a bound. Every one runs on the main QML thread, which the fault counts above name as a page-fault site. The heap profile measured no net retained growth on that thread, and no entry is tied by measurement to a share of any rate. The paths are relative to `quickshell/vshell/`.

The Wayland event threads' growth is allocated outside VGS code: the heap profile puts it in libwayland-client event closures that Qt's Wayland event thread reads and nothing dispatches. VGS ships no native code in the shell process, so the code that creates that queue is Quickshell, Qt or a library they load. The profile does not say which surface's events fill it. It grew before the lock as well as under it, so the lock screen is not required, but another VGS surface is not ruled out as the trigger.

- `Services/IconThemeService.qml`: `_cache` holds one entry per distinct icon name resolved and is cleared only when the icon theme changes. Notification icons come from arbitrary applications, so the key set is open.
- `Services/NotepadStorageService.qml`: `createEmptyFile` leaves its holder object parented to the singleton with no `destroy()`.

## Decisions

None. The allocator choice belongs to the Quickshell package, not to VGS.
