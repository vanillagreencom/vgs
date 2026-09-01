# Backend daemon architecture

Short reference for the VGS backend daemon. Method/capability source of
truth: `docs/architecture/backend-methods.json`; upstream lineage:
`backend/ATTRIBUTION.md`.

## Purpose and boundary

The backend is a VGS-owned, same-user local daemon that provides the system
integration layer QML is a poor fit for: NetworkManager, logind, DBus, BlueZ,
CUPS, MIME/default-app routing, gamma, WLR output, caps-lock, clipboard
(native: the backend owns the single `wl-paste --watch` process, the history
state file, and the image store — QML must not run its own watcher),
brightness (helper-bridged), wallpaper rotation scheduling, Tailscale (status,
actions, and the single watcher on tailscaled's ipn bus — QML never watches or
polls tailscaled itself, it only re-asks the backend), system updates
(counts and terminal supervision only; the commands are `vshell update run`,
see `dev-tools.md`),
freedesktop settings, and location.

What the backend does **not** own:

- Theme engine, wallpaper/palette generation and application, blueprints,
  app-target generation — these stay in `bin/vshell-helper` /
  `VGSThemeService` / `vshell theme`. The backend owns only the rotation
  *scheduler* (timers/state); no matugen, no `themes.*`, no `theme.auto`.
- Display power (DPMS) — `IdleService` remains the single owner. The backend may
  report session/sleep signals but must never turn displays on or off.
- The native VGS lock screen and the `dcal`/VGS Calendar socket (a separate
  socket, not this daemon).

## Process model

```
bin/vshell run (bash)  ->  execs the VGS Go runner (long-lived parent)
  runner: create + listen on socket, export VGS_SOCKET
  runner: spawn `vshell-backend serve` child on the inherited listener FD
          (VGS_BACKEND_LISTEN_FD), then spawn `qs -c vshell` as a child
  runner: supervise backend (restart w/ capped backoff + crash-loop breaker:
          5 exits in 60s tears the socket down and the shell runs degraded);
          the runner keeps the listener open, so connects made while the
          backend restarts queue in the accept backlog and the socket path
          never disappears — QML just reconnects and resubscribes
  runner: on any exit (normal/panic/SIGTERM/INT/HUP) tear down socket/PID/session
```

A panic in a backend service kills only the `serve` child, never Quickshell:
both children carry PR_SET_PDEATHSIG so an uncleanly-dying runner cannot leak
either process under systemd restart.

The runner is the parent (upstream's model inverted from the current
`exec qs`): a bash script that `exec`s Quickshell cannot reap the backend or
unlink the socket afterward. The Go binary provides
`run|serve|request|doctor|methods` (`serve` is the daemon-only mode the
supervisor spawns); `vshell open` is bash-side dispatch in `bin/vshell` that
sends `browser.open`/`apppicker.open` through `request`. `bin/vshell` stays the
entrypoint and continues routing `theme`/`fonts`/`clipboard`/`brightness`/… to
the Python helper. The symlinked dev setup gets a fresh binary via
`bin/vshell`'s build-if-stale into `~/.cache/vshell/` (no prebuilt binary
committed).

## Runtime paths (all VGS-owned)

| Item | Path |
|------|------|
| Socket | `$XDG_RUNTIME_DIR/vshell-<pid>.sock` (0600) |
| PID | `$XDG_RUNTIME_DIR/vshell-<pid>.pid` |
| Session | `$XDG_RUNTIME_DIR/vshell-<pid>.session` |
| Env to QML | `VGS_SOCKET` (never the upstream socket env name) |

No upstream command names, socket names, PID files, config files, desktop IDs,
or environment variables are exposed.

## Protocol

Line-delimited JSON, upstream-compatible framing for ported methods:

- Request: `{"id": 1, "method": "network.getState", "params": {}}`
- Response: `{"id": 1, "result": ...}` or `{"id": 1, "error": "..."}`
- Subscription events: `{"result": {"service": "...", "data": ...}}`

Server info advertises both `apiVersion` (upstream-compatible, kept truthful —
never bumped past what is implemented) and `vgsApiVersion` (VGS protocol
revisions), plus `capabilities` and `methods`. QML gates features on
`capabilities`/`methods` presence, not raw version ordinals — see
`backend-methods.json`. The `subscribe` handler must tolerate unknown/unimplemented service
names so the client's full subscription list works while services land
incrementally.

## Security / threat model

Trust boundary: same-user local infrastructure, not a public RPC server. Still:

- **Runtime dir required.** Fail closed if `$XDG_RUNTIME_DIR` is unset — never
  fall back to a world-writable temp dir (would expose generic `dbus`,
  AccountsService writes, CUPS actions to any local user).
- **Socket hardening.** Create at `0600`; reject connections whose peer
  credentials (SO_PEERCRED) are not the same UID.
- **Least privilege.** Prefer typed routes over generic power. `dbus.*` is
  subscribe-only (hard-restricted to logind `PrepareForSleep`); no
  `dbus.call`/`dbus.setProperty` methods are registered at all.
- **`vshell open`** classifies url/file/custom targets, validates scheme/path/
  MIME/category/desktop-id, passes structured JSON to the backend, and launches
  only `.desktop` entries or explicitly selected commands through the same
  sanitized path as `SessionService` — never string-concatenated into a shell.
- **Plugin registry** installs validate IDs, paths, archives, metadata, and
  target dirs; plugin paths stay VGS-owned.
- **Privileged ops** use the platform mechanism the service already requires
  (Polkit/CUPS helpers), never hidden passwordless escalation.
- **Logging** never emits credentials, VPN secrets, Wi-Fi PSKs, clipboard
  contents, or file payloads; rejected calls and privilege failures are logged.

## Reliability

Bake in from Phase 1: backend supervision with capped backoff + crash-loop
breaker; idempotent stale-socket cleanup on start; single teardown routine on
every exit path; single-owner discipline per capability (no two watchers);
in-flight request flush on client disconnect; `vshell backend doctor` health
check (connect + getServerInfo: socket path, versions, capabilities, methods).
A dead backend degrades UI to unavailable and never strands displays.
Context-bounded one-shot commands that read tool output are built with
`backend/internal/execbound`, whose `cmd.WaitDelay` keeps a descendant holding
the child's pipes from wedging the request past its context deadline. execbound
owns the terminal classification, so no call site reads `ctx.Err()` itself: a
clean exit read through held pipes is a success carrying `Result.Salvaged` (one
Warn, naming the tool, on the service's own logger so
`VGS_BACKEND_LOG_LEVEL` governs it), and an exit status the child reached on its own outranks
an expired deadline — the `*exec.ExitError` still reaches code keying on an exit
code or `ee.Stderr`. Only a child killed by signal classifies as `ErrTimeout`.
Every adopter runs `DefaultWaitDelay`; brightnessbridge takes
it through an injectable field only its tests vary, and why the ddcutil chain
never reaches the bound is in `display-brightness.md`. Long-lived watchers own
their own lifecycle. `scripts/check-execbound-adoption.py` keeps new one-shot
`os/exec` output reads out of backend services and records direct
`exec.Command` or `exec.CommandContext` builders whose lifecycle intentionally
stays outside execbound. The guard rejects any `Output` or `CombinedOutput`
selector in backend services unless the read stays directly chained from
`execbound.Command`, with any `WithLogger` call kept in that chain.
`CommandWithDelay` is reserved for the allowlisted brightnessbridge path that
tests the ddcutil pipe-hold bound. Direct raw `exec.Command` and
`exec.CommandContext` builders pass only when named in the allowlist.

## Feature flags / env

| Env | Effect |
|-----|--------|
| `VGS_BACKEND_DISABLE=network,cups,…` | Disable named capabilities (comma list). |
| `VGS_BACKEND_LOG_LEVEL=debug\|info\|warn\|error` | Backend log verbosity. |
| `VGS_BACKEND_SOCKET=<path>` | Override socket path (debugging only). |
| `VGS_SOCKET` | Set by the runner; consumed by `VGSBackendService`. |

## Attribution

The backend is adapted from an upstream Go shell core, with all package/module
names, socket/env/desktop identifiers, and theme code removed or renamed to VGS.
The specific upstream repository, commit, license lineage, and the excluded
upstream surface (matugen, `themes`, `theme.auto`, multi-compositor control)
are recorded in `backend/ATTRIBUTION.md` and enforced by
`scripts/check-backend-inventory.py`.

## Validation

```bash
scripts/validate go
```
