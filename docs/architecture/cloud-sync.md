# Cloud Sync architecture

Consumer-style cloud file sync (Google Drive / Insync class) built on rclone.
Read this before touching `backend/internal/services/cloudsync/`,
`Services/CloudSyncService.qml`, `Modals/CloudSync/`, or
`config/vshell/plugins/cloudSync/`.

## Why rclone

rclone is the only broadly-adopted engine that covers ~70 providers from one
binary, and `rclone rcd` exposes a JSON HTTP control API with exactly the
telemetry a consumer UI needs: `core/stats` returns a live `transferring[]`
array with per-file name, size, bytes, percentage, speed and ETA, scoped to a
stats *group* so each folder's progress is readable independently.

Rejected alternatives: Syncthing (peer-to-peer, no cloud providers), the
Nextcloud client (single provider), restic/kopia (backup, not sync),
RcloneView/FTPie (closed third-party GUIs).

**rclone does not watch the filesystem.** There is no `--watch` and no bisync
poll interval, so real-time sync is our own inotify watcher.

## Ownership

The Go backend is the single owner of everything long-lived. QML holds no sync
state and never talks to rclone.

```
cloudsync service ── supervises ─→ rclone rcd (127.0.0.1:<ephemeral>, Basic auth)
   owns: daemon lifecycle, accounts/OAuth, folder config, schedules,
         the inotify watcher, FUSE mounts, job history, conflict state
   broadcasts: "cloudsync" subscription (snapshot + throttled progress, ~2 Hz)
        ↓
CloudSyncService.qml  (ref-counted subscription, derived UI state, formatters)
   ├─→ Modals/CloudSync/*                    the app (FloatingWindow)
   └─→ config/vshell/plugins/cloudSync/*     bar pill + popout + CC tile
```

| File | Responsibility |
|------|----------------|
| `cloudsync.go` | `Register`, method handlers, state snapshot, broadcast throttling |
| `rcd.go` | rcd supervision: ephemeral port, random credentials, capped-backoff restart, crash-loop breaker, `core/quit` on close |
| `rc.go` | Typed rc client and response shapes |
| `remotes.go` | Provider catalog, account CRUD, quota, browser sign-in |
| `pairs.go` | Folder normalization and validation |
| `jobs.go` | Async job execution, stats-group polling, history |
| `schedule.go` | Per-folder timers with failure backoff |
| `watch.go` | Recursive inotify watcher with debounce |
| `mounts.go` | Stream-mode FUSE mounts |
| `conflicts.go` | Conflict detection and resolution |
| `state.go` | Persistence |

## rcd process model

One supervised child, started with `--rc-addr 127.0.0.1:<port>` where the port
is reserved by binding `:0` ourselves (so nothing depends on rclone's log
format) plus per-start random `--rc-user`/`--rc-pass`. Auth is mandatory even on
loopback: *rc access is equivalent to shell access as this user*. Credentials
are never logged, and rclone's stdout/stderr are left unattached because its
log can contain remote paths.

The child runs in its own process group so shutdown kills mount helpers with
it. More than 5 exits in 60s trips the crash-loop breaker; the service then
reports an error and waits for an explicit `cloudsync.restartDaemon`.

Jobs do not survive an rclone restart, so `onDaemonDown` marks every running
folder as interrupted rather than leaving it "syncing" forever.

## Sync modes

There is deliberately **no default mode** — the add-folder wizard makes the user
choose, because the four behave very differently.

| Mode | rclone call | Notes |
|------|-------------|-------|
| `twoway` | `sync/bisync` | Drive-like. The only mode that can conflict. Requires a baseline. |
| `backup` | `sync/sync` local → remote | |
| `restore` | `sync/sync` remote → local | |
| `stream` | `mount/mount` | On-demand FUSE, `--vfs-cache-mode full`, 1m poll for remote change notification. Needs fuse3. |

Each run is issued with `_async: true` and `_group: vgs-<folderID>`, and
progress is read back with `core/stats?group=…`, so folders never contaminate
each other's numbers. `core/stats-reset` clears the group before each run.

## Safety rails

Data loss is the failure mode that matters here, so:

- **Recycle bin.** Every destructive operation routes through a backup
  directory: `_config.BackupDir` for one-way modes, `backupDir1`/`backupDir2`
  for bisync. Local side is `~/.local/state/vshell/cloudsync/trash/<id>`; cloud
  side is `<remote>:<parent>/.vgs-trash/<id>`, deliberately *beside* the synced
  tree so it is never itself synced. Pruned on a retention timer.
- **Explicit baseline.** A two-way folder reports `needsResync` and refuses to
  run until the user picks which side wins. The backend never auto-`--resync`.
- **Resilience.** bisync runs with `--resilient --recover --max-lock 15m` so an
  interrupted run recovers itself instead of demanding manual intervention.
- **Conflicts are surfaced, not resolved.** Default `--conflict-resolve none`
  keeps both versions as `<name>.conflict1` (this computer) and
  `.conflict2` (cloud); the Conflicts view offers keep-local / keep-cloud /
  keep-both, and the loser goes to the recycle bin, never `unlink`.
- **Pair validation.** No syncing `$HOME` itself, no filesystem root, and no two
  folders whose local or remote trees overlap.
- **Removing a folder never deletes files** on either side.

## Accounts and sign-in

Accounts are rclone remotes in rclone's *own* config file (no `--config`
override), so anything set up here also works from the `rclone` CLI and existing
remotes appear automatically.

Credential providers use `config/create` with `opt.obscure`, driven by a form
generated from `config/providers` metadata — that is why every backend rclone
supports is configurable without a per-provider form.

OAuth providers use an `rclone authorize <type> --auth-no-open-browser`
subprocess: rclone runs the whole consent dance against a loopback callback and
prints the token, which becomes the `token` parameter of `config/create`. The
consent URL is published in state; **the shell opens it**, so the backend has no
browser dependency. Sessions are cancellable and time out after 5 minutes.

### Job and daemon lifecycle

The invariants that keep a folder from getting stuck:

- **The progress loop's exit is atomic.** `progressLoop` clears
  `progressRunning` in the *same* critical section as its "no jobs left" test.
  Split apart, a job inserted in the gap saw the flag still set and got no
  poller at all — the folder stayed `Syncing` for the life of the process and
  every later sync for it was refused as already running.
- **Jobs carry a daemon generation.** `daemonGeneration` increments on every
  rcd up/down. rclone restarts its job IDs from 1, so without it a job started
  against a dying daemon could be matched to an unrelated job on the next one.
  `startSync` refuses to record a job whose generation has moved.
- **`job/status` failures are bounded** (`statusPollLimit`). rclone expires
  finished jobs from its cache, so a job that can no longer be inspected is
  finished as interrupted rather than polled forever.
- **`startSync` refuses once `closed` is set**, so a timer that had already
  fired when `Close()` stopped it cannot launch a sync during shutdown.
- **`rcd` has one owner and one waiter.** A `starting` flag closes the window
  between "is one running?" and the assignment of `d.cmd` (which could
  otherwise spawn a second daemon and orphan the first), and `close()` awaits
  the existing `wait()` goroutine via a `done` channel — `os/exec` does not
  support concurrent waits, and the loser getting `ECHILD` made shutdown
  nondeterministic.
- **Background account probes run under a shutdown context** and are tracked by
  a WaitGroup, so `Close()` cancels and waits for them instead of leaving
  goroutines writing state and broadcasting after teardown.
- **Watch degradation reaches state.** The watcher calls back into the manager
  (`onDegraded`) when a mid-session `addWatch` fails or the read loop dies, so
  the promise above — degraded rather than silently doing nothing — holds
  without waiting for the user to edit an unrelated setting.

### Credentials never go in argv

`/proc/<pid>/cmdline` is world-readable on a default Linux mount, so anything
passed as a flag is published to every local user. Both the `rclone rcd`
control credentials and a user's own OAuth client secret are therefore passed
through the environment (`/proc/<pid>/environ` is `0400`), never as arguments:

- `rcd.go` sets `RCLONE_RC_USER` / `RCLONE_RC_PASS`. rc access is
  shell-equivalent — `config/dump` returns every account's token — so a flag
  would publish the password beside the port it protects.
- `remotes.go` sets `RCLONE_<BACKEND>_CLIENT_ID` / `_CLIENT_SECRET` for
  `rclone authorize`. **The backend-scoped prefix is required**: verified
  against rclone v1.74, the generic `RCLONE_CLIENT_ID` is silently ignored and
  rclone falls back to its built-in credentials, which would mint a token that
  does not match the `client_id` written into the config.

### Folder remotes are validated, including on load

`Folder.Remote` must pass `validateRemoteName` — it names a configured account,
never a raw rclone connection string. rclone accepts on-the-fly backends of the
form `:sftp,host=…:path`, so an unvalidated value would sync to a host that was
never configured and never appears in Accounts. Validation runs in
`normalizeFolder` (add and update) **and again in `store.load()`**, because the
config file is replayed at startup and its folders are scheduled and mounted
automatically — anything able to write that file would otherwise get silent
exfiltration at next login with no UI interaction.

### Account identity, health and lifecycle

An `Account` carries three things beyond rclone's raw config:

- **Identity.** `Provider` is the display name resolved once from
  `config/providers` and cached (`Manager.providers`); `Label` is a user-chosen
  display name. The rclone remote **name is immutable** — every `Folder` stores
  it — so renaming only ever touches the label. Labels are VGS state and live
  under `accounts` in `cloudsync.json`, never written into rclone's own config.
- **Health.** `Health`/`CheckedUnix`/`Error` are refreshed on every account
  change and every 30 minutes (`accountCheckInterval`), plus on demand via
  `cloudsync.checkRemote`. The probe is `operations/about`, which also yields
  the quota in the same call; only backends that cannot answer `about` fall back
  to listing the root. Listing is the expensive path — the root of a well-used
  Drive routinely outruns any sane timeout, and reporting that as a broken
  account is worse than not checking.
- **Repair.** `cloudsync.reconnectRemote` re-runs the browser sign-in for an
  account that already exists and writes the token with `config/update`, so the
  remote name (and every folder pointing at it) survives an expired token.
  Before this existed the only cure was disconnect + re-add, which meant
  rebuilding every folder.

`cloudsync.removeRemote` refuses to disconnect an account while folders still
reference it unless the caller passes `removeFolders: true`; those folders are
then torn down properly (job cancelled, unmounted, unwatched, timers stopped,
conflicts dropped). Files on both sides are untouched either way.

## Real-time watching

`watch.go` is a recursive inotify watcher over already-vendored
`golang.org/x/sys/unix` (no new Go dependency). It listens for
create/delete/move/`IN_CLOSE_WRITE` — deliberately *not* `IN_MODIFY`, since
syncing a half-written file is worse than syncing it a moment later — and
debounces 5s so a burst of writes produces one sync.

Real-time is **off by default** per folder (new folders default to a 15-minute
interval): large trees can exhaust `max_user_watches`, and continuous sync costs
battery and network. When `AddWatch` returns `ENOSPC` the folder is reported as
degraded in state and falls back to its schedule rather than silently doing
nothing.

## Paths

| Item | Path |
|------|------|
| Folder + settings config | `~/.config/vshell/cloudsync.json` |
| Run history | `~/.local/state/vshell/cloudsync/history.json` |
| bisync working dirs | `~/.local/state/vshell/cloudsync/bisync/<id>` |
| Local recycle bin | `~/.local/state/vshell/cloudsync/trash/<id>` |
| Streamed folder mounts | `~/CloudSync/<name>` (configurable) |
| Account credentials | rclone's own config file |

## Shell entry points

| Surface | Wiring |
|---------|--------|
| App window | `VGS.qml` LazyLoader → `PopoutService.cloudSyncModal`, same lazy-load-then-act shape as Settings |
| IPC | `cloudsync` target: `open` / `openWith <section>` / `close` / `toggle` / `syncNow` / `pauseAll` / `resumeAll` |
| Launcher | `AppSearchService.builtInPlugins.vgs_cloudsync`, dispatched by `executeCoreApp` — the same mechanism as Settings/Notepad/System Monitor. VGS apps are built-ins, not `.desktop` files; shipping one would double-list the app in VGS's own launcher. |
| Bar | bundled `cloudSync` plugin (pill + popout + control-center tile) |

Both the launcher entry and the bar widget are hidden when the `cloudsync`
capability is absent (`requiresCapability` / `_visibilityOverrideValue`), so a
machine without rclone never shows an entry that only leads to an install hint.

## Gating

Capability `cloudsync` is advertised only when the `rclone` binary is present;
without it the bar widget hides itself and the app shows an install hint.
`canMount` gates stream mode on fuse3. Dependencies are declared as `cloud-sync`
and `cloud-sync-stream` in `config/vshell/dependencies.json`.

## Validation

```bash
python3 scripts/check-backend-inventory.py
go -C backend build ./... && go -C backend vet ./... && go -C backend test -race ./...
scripts/check-naming.sh
scripts/qml-smoke.sh
```

End-to-end against a scratch daemon (never the live session socket):

```bash
VGS_BACKEND_SOCKET=/run/user/$UID/cs.sock vshell backend serve &
vshell-backend request cloudsync.listProviders
vshell-backend request cloudsync.getState
```
