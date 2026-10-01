# Monitor previews and their guard

Covers: bin/vgsh-monitor-guard, bin/lib/monitor-preview.js, scripts/test-vgsh-monitor-guard.sh, scripts/fixtures/monitor-guard, scripts/smoke/rows/monitor-preview.sh

How the `monitors` capability applies rules for a few seconds without saving them, and how a detached guard restores the outputs when nobody keeps them. The rules, the document and the rest of the capability are [hyprland-monitors.md](hyprland-monitors.md); the Hyprland facts are [runtime-hyprland-monitors.md](runtime-hyprland-monitors.md). [D080](../decisions/D080-hyprland-options-rendered-from-data.md) records the choice.

## The transaction

`bin/vgsh-monitor-guard` runs every step. It closes every descriptor above 2 it inherited without close-on-exec, then execs `bin/lib/monitor-preview.js`, which does the I/O. `MonitorLogic.js` makes every decision: the plan, the capture, the record's judge, the restore lines, the read back, the guard's and adopt's actions, and the reply the shell reads.

`preview <seconds> <request>`, the request `{ "rules": [...], "saved": [...] }`, runs these steps in this order under the transaction lock:

1. **Capture.** Refuse `preview=busy` while a record exists. Read `hyprctl -j monitors all` and judge the rules as `write` does (`MonitorLogic.previewPlan`). Take the state of each listed output a rule names: off, or its mode, position, scale, transform and mirror, and adaptive sync where the rule sets `vrr`. A rule for an output Hyprland does not list is kept for Keep and not applied.
2. **Record.** Write `$XDG_RUNTIME_DIR/vgs/monitors-preview.json` by rename, mode 0600: `version`, a random `token`, the `deadline` in epoch seconds, the Hyprland `signature` and the `captured` states.
3. **Arm.** Start `bin/vgsh-monitor-guard <token>` in a session of its own, stdin `/dev/null`, its output in the guard's log, and wait up to 5 s until it holds the guard lock with its pid as the lock file's only line. A guard that does not arm removes the record and refuses `guard=unarmed`.
4. **Apply.** Send each rule's `hl.monitor` line through `hyprctl --instance <signature> eval`. A reply other than `ok` restores the captured state at once, removes the record and refuses `preview=apply-failed`.
5. **Verify.** Read the outputs every 100 ms for up to 5 s until `MonitorLogic.overridden` names none. An output that still reads otherwise fell back: restore at once, remove the record and refuse `preview=fallback output=<id>`.

It prints `ok token=<hex> deadline=<epoch>`. `confirm <token>` removes the record. `revert <token>` restores the captured state, reads it back and removes the record. `adopt` arms a guard for a record of this instance whose guard is gone, and leaves a record whose guard runs or that another instance wrote. Every hyprctl call names the instance with `--instance`.

## The guard

The guard takes the guard lock, waiting while an earlier guard holds it. It reads the record each second and exits once the record is gone or holds another token. At the deadline it takes the transaction lock and reads the record again. A confirm or a revert that took the lock first wins, and the guard restores nothing. Otherwise it restores each captured output still listed through explicit `hl.monitor` lines, reads them back, removes the record and logs `guard=restored`. An unplugged output is skipped and logged. The guard never reloads to restore: a reload leaves an output no file rule names as it is, and on first use no rule names any. It leaves a record another Hyprland instance wrote, as `guard=foreign`.

The restore writes every captured field: `disabled`, `mode`, `position`, `scale`, `transform`, and `mirror`, `""` for none. It writes `vrr` only where the preview set it, as 1 when adaptive sync ran and 0 when it did not: `monitors -j` reads whether adaptive sync runs now, so a captured rule setting of 2, fullscreen only, comes back as 0. A preview that sets `bitdepth` or `cm` is refused `rule=<i> <field>=<value> want=absent-in-preview`, since no capture reads them back.

## Files

| Path under `$XDG_RUNTIME_DIR/vgs` | Holds |
|---|---|
| `monitors-preview.json` | The record. A symlink, a non-file or another user's file is refused, never read. |
| `monitors-preview.lock` | The transaction lock: every read-modify-write of the record holds it. |
| `monitors-guard.lock` | The guard lock; its only line is the pid of the guard holding it. |
| `monitors-guard.log` | One keyed line per guard event. |

The directory is made 0700 when absent and refused when it is a symlink or another user's. Under the test-run marker, `VGS_MONITOR_PREVIEW_FAULT=<step>` makes a preview SIGKILL itself right after `capture`, `record`, `arm`, `apply` or `verify`; without the marker the helper does not read it.

## The capability

`MonitorState.qml` runs the helper through one Quickshell `Process`, one run at a time. `shell.qml` runs `adopt` once at the start of the runner's shell.

| Member | What it does |
|---|---|
| `preview(rules, seconds)` | Judges the rules as `write` does, `seconds` a whole number from 2 to 60, and answers at once: `ok` once the helper runs, `write`'s refusals, `refused: preview=busy phase=<phase>` or `verb=<verb>`, `refused: seconds=<value> want=2..60`, the judge's refusal, or `rule=<i> <field>=<value> want=absent-in-preview`. |
| `confirm(token)` | Keep: the helper removes the record, then the rules go through `write`. A confirm the guard's restore beat fails `preview=gone`, and nothing is written. |
| `revert(token)` | Restores the captured state now. |
| `previewState` | `{ phase, token, deadline, failure }`: `idle`, `starting`, `previewing` until Keep, a revert or the deadline, `confirming`, `reverting`, or `failed` with the helper's keyed refusal. Two seconds after the deadline the phase returns to `idle` and the outputs are read again. |

## Invariants

1. The record is written and the guard holds its lock before any rule is applied. Enforced by `scripts/test-vgsh-monitor-guard.sh`, whose control arms after applying, and by `scripts/smoke/rows/monitor-preview.sh`, whose copy of the tree that arms after applying leaves scale 2 when killed between the two.
2. A guard restores the captured state explicitly and reads it back; it never reapplies saved rules. Enforced by `scripts/test-vgsh-monitor-guard.sh` on first use with no `monitors.json`, whose control restores through `hyprctl reload`.
3. A record confirmed or reverted, before the deadline or while the guard waits on the transaction lock at it, is left alone. Enforced by `scripts/test-vgsh-monitor-guard.sh`, whose control restores the record read before the lock.
4. A guard and adopt leave another instance's record, an unplugged output is skipped, and every hyprctl call names the record's instance. Enforced by `scripts/test-vgsh-monitor-guard.sh` with a control for each rule.
5. The guard leads a session of its own and holds no descriptor its caller had open, such as the runner's instance lock ([D053](../decisions/D053-runner-holds-the-instance-lock.md)). Enforced by `scripts/test-vgsh-monitor-guard.sh`, with a control on a wrapper that keeps descriptors and one on a guard in its caller's session.
6. On the nested output the deadline restores scale 1, Keep holds scale 2 through a reload, and the guard restores with the shell stopped by SIGSTOP, with the runner stopped, and after a kill right after each step. Enforced by `scripts/smoke/rows/monitor-preview.sh`.
