# Remote desktop host (Sunshine)

VGS can host a Moonlight stream through Sunshine. The host is **not** part of an
ordinary session: its user unit ships `disabled`, nothing autostarts it, and the
virtual output it captures exists only while it runs. A local-only session
therefore has no phantom monitor and nothing listening on the network.

That makes it a manual, stateful thing, and before VGS-66 the only interface was
a CLI — fine over ssh, invisible at the desk.

## The three pieces

| Layer | Owner | What it does |
|-------|-------|--------------|
| Helper | `bin/vshell-helper` (`vshell remote-desktop`) | Owns the lifecycle, reads status, and normalises the host's log into events |
| Shell service | `Services/RemoteDesktopService.qml` | Holds live state, driven by the helper's event watch |
| Widget | `config/vshell/plugins/remoteDesktop/` | Bar pill + popout: start/stop, session, web UI, paired devices |

## The lifecycle is one operation, and it lives in the helper

Sunshine picks its capture target **at startup**. Start the unit without the
headless output already present and it falls back to the first real monitor —
the user's own screen is streamed instead of the virtual one, with no error in
the journal and nothing on screen to notice.

So `vshell remote-desktop start` creates the output and starts the unit, in that
order, and `stop` reverses it. No VGS surface may call `systemctl start` on the
unit: doing so is not a different route to the same result, it is the silent
failure.

Three details that follow from that:

- **"The output is missing" and "nobody could say" are different answers.**
  `_rd_output_present()` returns `None` when hyprctl cannot be asked, and `start`
  **refuses** on `None` rather than proceeding. Treating an unanswerable probe as
  "absent, create one" would be survivable; treating it as "present, go ahead" is
  the failure above, and collapsing the two into a boolean invites exactly that.
- **The output half is Hyprland-only.** Niri has no equivalent of
  `hyprctl output create headless`, so on anything else the host still starts and
  the reply says, through `manual`, that it will capture an existing monitor.
  Reporting is better than implying VGS manages an output it cannot.
- **`captureFallback`** in the status payload is the running form of the same
  problem: host up, Hyprland, no `HEADLESS-1`. The widget renders it as a
  warning, because nothing else in the system would ever mention it.

There is a personal `remote-desktop` script in `~/dotfiles` that predates this
and does the same two steps. It is not a dependency: dotfiles are a per-machine
overlay and a bundled VGS plugin cannot rely on one. The behaviour is portable,
so it belongs here — per AGENTS.md § Mission.

## Listening is not streaming

The pill has three live states, never two:

| State | Meaning |
|-------|---------|
| off | the host is down |
| listening (`On`) | the host is up and nobody is connected |
| streaming (`LIVE`, red, filled) | a client is connected right now |

Collapsing the last two into one "on" would hide a live capture of the user's
screen behind an indicator identical to an idle one. The streaming state reuses
the capture language `config/vshell/plugins/screenRecord/` already established
(`Theme.error`, filled glyph, a word not just an icon), so "something is being
recorded off this machine" looks the same wherever it appears.

Two further states cover not knowing: `unknown` (no usable answer yet, or the
last probe could not run) and `stale` (the event watch is down, so what is on
screen may be out of date). Both say so rather than presenting a guess as
current.

### Three knowledge axes, reset together

*Nobody is watching* and *nobody knows* must never render alike, and that
applies to every axis of the answer, not just the session:

| Axis | Value | Known? |
|------|-------|--------|
| host | `installed`, `running` | `statusKnown` |
| session | `streaming`, `sessionCount` | `sessionKnown` |
| virtual output | `outputPresent` | `outputKnown` |

`RemoteDesktopService._markStatusUnknown()` drops all three at once. Leaving one
standing renders half an answer as a whole one — and `installed` in particular
**defaults to false**, so a widget that tested it before `statusKnown` displayed
"Sunshine is not installed" for every instant before the first reply and again
after any failed probe. A default is not an answer.

### What can turn LIVE off

Exactly one thing: an authoritative `status --json` reply whose
`session.active` is false. Specifically:

- a `connected` event sets the indicator **immediately** — a connect is
  unambiguous, and this is the one fact worth showing a beat before the
  authoritative read confirms it;
- a `disconnected` event **does not clear it**. With more than one client
  connected it ends *one* session, not the capture, so clearing on the first
  disconnect would hide a live capture until the next resync. It only schedules
  the resync, and the session count decides;
- losing the answer entirely does not clear it either. `_markStatusUnknown()`
  leaves `streaming` set, and the widget tests `streaming` **before** every
  uncertainty state, so a capture that may still be live fails loud instead of
  being downgraded to a question mark. The uncertainty is reported beside it.

## Why the journal, not the Web API

Sunshine's Web UI has an API that would give the connected client's **name** and
its **requested resolution**. It is HTTP-Basic-gated behind the credentials in
`~/.config/sunshine/sunshine_state.json`, so using it means reading and holding a
second credential inside the shell purely to answer "is somebody watching my
screen". The journal already carries the events, at no such cost.

What that costs, stated rather than papered over: **the journal does not name the
connected client, and does not carry the requested resolution** — neither is
logged at Sunshine's `info` level. The popout therefore lists *paired* devices
(from `named_devices` in that same state file — only `name` is read out of it,
never the credential material beside it) under a heading that says paired, and
says outright that which one is connected is not something the host reports.

What the journal does carry, and the status payload does report: connect and
disconnect, Sunshine's own `active sessions` tally, the encoder, the streaming
bitrate and the colour depth.

The scan is bounded to the unit's current run via `ActiveEnterTimestamp`.
Without that bound a `CLIENT CONNECTED` from a previous run — with no matching
disconnect, because the daemon was killed — reads as a live session forever.

## Event-driven, and honest when it stops being

VGS-63 was a widget that fetched status once and sat on the answer for a whole
session. This one is built the other way round:

- `vshell remote-desktop watch` follows the unit's journal and prints one
  normalised token per interesting line — `connected`, `disconnected`,
  `lifecycle`, `session`. Sunshine's log format is parsed in exactly **one**
  place; a widget string-matching `CLIENT CONNECTED` would be a second copy of
  that knowledge, free to drift.
- Every token schedules a debounced `status --json` resync, which is the
  authority. `connected`/`disconnected` additionally flip the indicator
  immediately, because that is the one fact worth showing a beat early.
- systemd's own `Started`/`Stopped` records land in the same unit journal, so the
  host lifecycle needs no second watcher.
- The watch is ref-counted (`Common/Ref`): it runs only while something is
  displaying the state.

**If the watch dies**, `RemoteDesktopService.watchLive` goes false and stays
false until a restart actually succeeds. Restarts back off 2s → 60s, and each
successful start does a full resync to cover what it missed while down. There is
no polling fallback that would quietly paper over a dead watch: the widget
renders the `stale` state instead, which is the difference between this and
VGS-63.

The backoff is reset by a watch that **survived** 60s (`watchStable`), never by
one that merely started. Resetting on entry defeats the backoff for a watcher
that fails immediately — it would run for milliseconds, reset to 2s, exit, and
schedule another 2s retry, so the cap would never be reached and the backoff
would be decorative.

### Nothing is dropped, and nothing hangs

Two smaller rules, both of the same family:

- **A refresh requested while a probe is in flight is coalesced, not dropped.**
  The journal read behind `status --json` can take seconds while the event
  debounce is 400 ms, so an event arriving mid-probe would otherwise be lost
  outright — and there is deliberately no polling fallback to recover it. Any
  number of requests during one probe collapse into a single follow-up, launched
  once the probe has settled.
- **A status command that cannot be spawned marks the state unknown.** Per
  `.github/instructions/quickshell-qml.instructions.md`, a `Process` that fails
  to start emits no `exited` at all, so the probe is keyed on `running` plus a
  500 ms unanswered grace, exactly as `NotificationService.qml`'s ownership probe
  is. Without it a missing binary leaves the default state — "not installed" —
  standing forever.

`scripts/test-remote-desktop-state.js` pins the widget's state ordering
(extracted verbatim from its BEGIN/END STATE DECISION markers) and all of the
service invariants above. Bundled plugins get no runtime coverage from
`qml-smoke.sh --nested`: the sandbox loads them but never places one in a bar,
so no binding is ever evaluated (VGS-19).

## Command surface

| Command | Effect |
|---------|--------|
| `status [--json]` | Host state, virtual output, live session, web UI URL, paired devices. Exit `0` running, `1` stopped, `2` not installed |
| `start` / `stop` / `toggle [--json]` | The paired lifecycle above |
| `ui [--json]` | Opens the web UI at the tailnet address — the only route a client has; `localhost` would be the wrong thing to hand over |
| `watch` | Streams normalised event tokens until killed |

## Not built

The pairing PIN flow. Submitting a PIN is a Web API call, and it is
HTTP-Basic-gated by the same credentials the section above declines to hold, so
it would reintroduce the exact cost that decision avoided. Pairing goes through
the web UI, which the popout links to.
