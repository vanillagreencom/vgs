# Cloud sync

Covers: backend/internal/services/cloudsync/

Consumer-style cloud file sync built on rclone, which is the one broadly adopted engine covering many providers from a single binary and exposing a control API with per-file progress telemetry. Data loss is the failure mode that matters here, so every destructive path is reversible and every ambiguity resolves toward doing nothing.

## Boundaries

- The Go backend is the single owner of everything long-lived: the supervised rclone control daemon, accounts and sign-in, folder configuration, schedules, the filesystem watcher, mounts, job history and conflict state. QML holds no sync state and never talks to rclone.
- rclone does not watch the filesystem, so real-time sync is a watcher VGS owns. It listens for creation, deletion, movement and close-after-write, deliberately not for every modification, since syncing a half-written file is worse than syncing it a moment later.
- Accounts are ordinary rclone remotes in rclone's own configuration, so anything set up here also works from the rclone command line and existing remotes appear automatically. Display labels are VGS state and are never written into rclone's configuration.
- The backend has no browser dependency: sign-in publishes the consent URL in state and the shell opens it.

## Invariants

1. There is deliberately no default sync mode. The four behave differently enough that the wizard makes the user choose.
2. Every destructive operation routes through a backup directory. The cloud-side recycle bin sits beside the synced tree rather than inside it, so it is never itself synced, and both sides are pruned on a retention timer.
3. A two-way folder refuses to run until the user picks which side wins. The backend never establishes that baseline on its own.
4. Conflicts are surfaced, not resolved: both versions are kept, the view offers keep-local, keep-cloud or keep-both, and the loser goes to the recycle bin rather than being unlinked.
5. Removing a folder never deletes files on either side, and disconnecting an account that folders still reference is refused unless the caller asks for those folders to be torn down too.
6. No folder may sync the user's home directory itself or a filesystem root, and no two folders may have overlapping local or remote trees.
7. Credentials never appear in arguments. The process command line is world-readable on a default Linux mount while the environment is not, so the control credentials and a user's own client secret are passed through the environment. The backend-scoped variable prefix is required: the generic name is silently ignored and rclone falls back to its built-in credentials, minting a token that does not match the identifier written into the configuration.
8. A folder's remote names a configured account and never a raw connection string, because rclone accepts on-the-fly backends that would sync to a host that was never configured and never appears in the account list. Validation runs on add and update and again when the configuration is replayed at start-up, since those folders are scheduled and mounted automatically — anything able to write that file would otherwise get silent exfiltration at the next login with no interaction at all.
9. Each run is issued under its own stats group and the group is reset before it, so folders never contaminate each other's progress numbers.
10. The progress loop clears its running flag in the same critical section as its "no jobs left" test. Split apart, a job inserted in the gap sees the flag still set and gets no poller at all, and the folder stays syncing for the life of the process while every later sync for it is refused as already running.
11. Status polling is bounded, because rclone expires finished jobs from its cache: a job it stops being able to inspect is finished as interrupted rather than polled forever. A daemon that goes down marks every running folder interrupted rather than leaving it syncing.
12. The control daemon has one owner and one waiter. A starting flag closes the window between asking whether one is running and recording it, which would otherwise spawn a second daemon and orphan the first; shutdown awaits the existing wait rather than adding a concurrent one.
13. Shutdown is complete: sync refuses to start once closing has begun, and background probes run under a shutdown context tracked by a wait group, so nothing writes state or broadcasts after teardown.
14. Degradation reaches the state the UI reads. Where the watcher cannot add a watch or its read loop dies, the folder is reported degraded and falls back to its schedule rather than silently doing nothing. Real-time watching is off by default per folder, because large trees can exhaust the kernel's watch limit and continuous sync costs battery and network.
15. An account probe asks for account metadata, which also yields the quota in the same call; only a backend that cannot answer it falls back to listing the root. Listing is the expensive path — the root of a well-used account routinely outruns any sane timeout, and reporting that as a broken account is worse than not checking.
16. The remote name is immutable, because every folder stores it. Repairing an expired token re-runs sign-in and updates the token in place, so the name and every folder pointing at it survive.
