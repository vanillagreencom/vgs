# Cloud sync

Covers: backend/internal/services/cloudsync/, quickshell/vshell/Services/

The backend owns rclone processes, sync configuration and file watchers. QML consumes backend state and does not call rclone directly.

Paths below are under `backend/internal/services/cloudsync/`.

## Invariants

- A folder requires an explicit mode. Two-way sync requires an explicit baseline choice. `cloudsync_test.go` covers normalization and refusal without a baseline.
- Sync deletion uses a backup directory outside the synced tree. Retention pruning remains destructive. `buildSyncParams` in `jobs.go` and the trash tests define these limits.
- Conflict resolution preserves the rejected version in trash. `conflicts.go` and its tests cover resolution and keep-both behavior.
- Folder removal leaves files intact. Account removal must account for dependent folders. See `pairs.go` and `remotes.go`.
- Local and remote roots must not overlap other pairs; home and filesystem roots are refused. The folder and remote-validation tests in `cloudsync_test.go` cover these constraints.
- Configured remote names must resolve to accounts, not inline connection strings. `pairs.go` owns validation before scheduling.
- Control credentials and OAuth client secrets stay out of command arguments. Review process construction in `rcd.go` and `remotes.go`.
- Each sync has a separate stats group. Progress-loop ownership changes under the same lock as the empty-job check. See `jobs.go` and its tests.
- Missing daemon or job state ends a run as interrupted. Shutdown refuses new work and waits for owned background operations. See `jobs.go`, `rcd.go` and `cloudsync.go`.
- Watch failures reach folder state and permit scheduled fallback. `watch.go` owns this behavior; watcher tests cover event filtering and debounce.
