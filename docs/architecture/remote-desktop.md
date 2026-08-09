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
- **The output half is Hyprland-only, and "unknown" is a question, not a no.**
  Niri has no equivalent of `hyprctl output create headless`, so there the host
  still starts and the reply says, through `manual`, that it will capture an
  existing monitor. Reporting is better than implying VGS manages an output it
  cannot.

  But `detect_compositor()` answers from the *calling process's* environment,
  and an ssh session has none of it — no Wayland socket owner, no instance
  signature — so it reports `unknown`. Treating that as "not Hyprland" skipped
  the virtual output on exactly the path a remote-desktop host is most likely to
  be started from. `_rd_manages_output()` therefore probes on `unknown`, using
  the same ssh-aware environment `_rd_output_present()` uses, and grades it:

  | Situation | Result |
  |---|---|
  | hyprctl not installed | definitely not Hyprland — start without an output, say so |
  | hyprctl present, no instance in the runtime dir | no Hyprland running — same |
  | an instance resolves and hyprctl answers | **this is Hyprland over ssh** — create the output |
  | an instance resolves but hyprctl will not answer | **refuse** — a Hyprland session is here and unreachable, so a real monitor cannot be ruled out |
- **`captureFallback` is an assertion, so it needs a known status.** It is
  cleared by `_markStatusUnknown()` along with the other axes: it claims "the
  host is capturing a real monitor right now", derived from output presence,
  and once that is unknown the claim is unsubstantiated. `streaming` is the
  deliberate exception to unknown-clears-it; this is not one, because a warning
  nobody can substantiate costs the user trust in every other warning.
- **`captureFallback`** in the status payload is the running form of the same
  problem: host up, Hyprland, no `HEADLESS-1`. The widget renders it as a
  warning, because nothing else in the system would ever mention it.

### Creating the output is transactional, and removing it needs provenance

The two halves are paired in both directions:

- **A created output is verified before the unit starts.** `hyprctl` exiting 0
  is not the output existing; if it is absent, Sunshine picks a real monitor at
  startup and streams the user's own screen with nothing to say so — the same
  silent fallback as the unanswerable-probe case, reached from the other side.
  `start` re-reads presence and refuses rather than starting blind, keeping
  "cannot tell" distinct from "absent". Nothing is rolled back on either
  refusal: there is no output to remove in one case, and removing what cannot be
  seen is the guess this record exists to avoid in the other.
- **A failed start removes the output it created.** Otherwise the user is left
  with a phantom monitor *and* no host — the exact state the disabled-by-default
  design exists to avoid, with no affordance to undo it. Only what that call
  created is rolled back; an output that was already there is left alone.
- **Stop removes the output only if VGS created it.** Removing any present
  `HEADLESS-1` would delete a virtual output the user set up for something else,
  as a side effect of stopping a service. That is not recoverable from the
  shell, so it needs provenance rather than a name match.

Ownership is recorded only **after** that verification, so what was verified as
created is exactly what is owned and exactly what `stop` may remove — one record
answers all three.

Provenance lives in `~/.local/state/vshell/remote-desktop-output.json`, beside
the notification-takeover undo record and for the same reason: `start` and
`stop` are separate process invocations, so "did we create this?" cannot live in
memory, and without it undoing means guessing.

**It cannot go stale, because it is keyed on the Hyprland instance signature.**
Headless outputs do not survive a compositor restart and the signature changes
with every start, so a record from a previous instance cannot possibly describe
the output present now — `_rd_output_is_ours()` discards it rather than trusting
it. A record with no signature to place it is not ownership either.

Three edge cases, all decided toward *not removing*:

| Case | Behaviour |
|------|-----------|
| Sunshine's state file is malformed | Only the paired-device list goes unknown, with the reason. Every shape is checked rather than assumed: a list, a scalar, or a `root` that is a string used to raise straight out of `status`, so one bad field took the host and session state down with it |
| The output was removed by hand between start and stop | Nothing to remove, no error — and the record is dropped, or it would authorise removing a *later* output of the same name |
| The record could not be written at start | The output is created and used, but `stop` will not claim it. Reported through `manual`. A leaked monitor is one click to remove; a deleted one cannot be undone |
| `hyprctl` cannot say whether the output is present at stop | Left alone, and said so |

The residual limitation, stated rather than papered over: if the user removes
`HEADLESS-1` and creates their own output of the same name **within the same
compositor instance**, the record still matches and stop would remove theirs.
Hyprland exposes no creator for an output, so nothing here can tell them apart.

### Races

`start`, `stop` and `toggle` run under one `flock` on
`~/.local/state/vshell/remote-desktop.lock`, and `toggle`'s state read is
*inside* that lock — so no other helper invocation can decide from the same
reading and act on it twice.

The lock cannot close the window against the unit changing on its own (the
daemon exiting, a client connecting), so both actions are also idempotent, and
the losing path of each touches no output:

- `start` on an already-running host returns immediately. It creates nothing: a
  running host has already chosen its capture target, so a second virtual output
  would be a phantom monitor and nothing else.
- `stop` on an already-stopped unit is a `systemctl stop` that exits 0, and the
  output half is gated on ownership regardless.

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
| session count | `sessionCount` | `sessionCountKnown` |

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
  authoritative read confirms it. It does **not** carry a count with it: a
  connect proves somebody is watching, not how many, so `sessionCountKnown`
  goes false and the popout reads "confirming…" until the authoritative read
  supplies a number. Rendering the stale `0` beside a live capture showed a
  streaming session with no clients listed, which reads as a fact rather than
  as the gap it is;
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
(from `named_devices` in that same state file — a name containing bytes that
are not valid UTF-8 is **withheld and counted** rather than shown with U+FFFD
substituted into it, because a mangled name is indistinguishable from a device
genuinely called that; only `name` is read out of it,
never the credential material beside it) under a heading that says paired, and
says outright that which one is connected is not something the host reports.

What the journal does carry, and the status payload does report: connect and
disconnect, Sunshine's own `active sessions` tally, the encoder, the streaming
bitrate and the colour depth.

The scan is bounded to the unit's current run via `ActiveEnterTimestamp`.
Without that bound a `CLIENT CONNECTED` from a previous run — with no matching
disconnect, because the daemon was killed — reads as a live session forever.

**There is no fallback window, deliberately** — the same rule as the whitespace
base in AGENTS.md. An earlier version fell back to `--boot` when the timestamp
could not be established, reasoning that a running unit always has one; that
reasoning does not survive the query itself failing or systemd phrasing the
value differently. The read then replays unbounded history and the widget shows
**LIVE with nobody connected**.

That is the worse direction of the same error the readable/active split guards.
Hiding a real capture is bad; inventing one trains the user to ignore the only
indicator that says somebody is watching their screen. So no anchor means no
read: the session is reported unknown, which is neither a replay nor an idle
claim.

Likewise `_rd_unit_state()` separates "the unit is not installed" from
"`systemctl show` did not answer". The shared `_user_unit_state()` reports both
as `exists: False`, and a transient systemctl failure must not make the widget
announce that Sunshine is not installed. An unanswered query produces
`state: "unknown"` with `unitKnown: false`, which the shell routes to the same
unknown rendering as everything else here, and the lifecycle commands refuse to
act on rather than treating as "stopped".

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

**If the watch dies**, session state becomes *unknown*, not unchanged.
`_markSessionUnknown()` drops `sessionKnown` and clears the cached session
detail — those values were only current because something was refreshing them —
and the service immediately calls `refresh()`, because the status read is a
separate process that does not depend on the watch and may still answer
authoritatively.

The same rule applies at the *assignment* site. A status reply can be valid
while its session block is not: the helper returns `readable: false` with
`active` left at its default `false`, and taking that default at face value
cleared a live capture on the strength of a failed journal read.
`sessionApplyDecision()` is the guard — `active` is applied only from a block
that says it could be read, and an unreadable one moves the session to unknown
instead.

The reassuring direction is the one worse to get wrong, so it has its own state
too: a host that is up with an unreadable journal renders `listening-unconfirmed`
(`On?`, warning) rather than a plain `On`, which would claim nobody is watching.

`streaming` is **not** cleared: that would claim "idle" on a dead watcher's
say-so, and only the authoritative session count may say a capture ended.

### The split has to reach the pixels

`stateColorTokenFor()` returns a colour token *name* per state, so the state
table is assertable without a Theme instance, and `stateColor` is derived from
it rather than from a second switch that could drift.

The bar pill's glyph takes that colour for the states that mean something is
happening or unknown, and keeps the bar's uniform `Theme.widgetIconColor` for
`off` and `listening`, where nothing is wrong and a bar of differently coloured
glyphs is just noise. That exception matters: in `icon` pill mode there is no
text at all, so `cast_connected` vs `cast` — a glyph shape, at bar size, in the
same colour — was the *only* difference between "someone is watching my screen"
and "idle". Both the horizontal and the vertical pill take it. So the
widget gets a fourth session rendering, `streaming-unconfirmed` — still red,
still reading `LIVE?`, with the uncertainty explicit. A plain `LIVE` would claim
certainty nothing has; an idle pill would hide a capture that may be running.

`RemoteDesktopService.watchLive` goes false and stays
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
- **Every lifecycle failure reaches the user.** `start`/`stop`/`toggle` report
  through one surface, `_reportLifecycleFailure()`, keyed on `running` rather
  than `exited` for the same reason the busy flag is: a command that cannot be
  spawned never exits, and an `exited`-only report would stay silent on exactly
  the failure the user is least able to diagnose — a toggle that springs back
  with no state change and no reason. The helper's own JSON verdict may arrive
  after `exited` and is allowed to replace a generic message with the real one;
  the shared toast category means that updates in place rather than stacking.
- **The unanswered-grace timer belongs to one probe.** It is shared, so a tick
  armed by probe A could fire while probe B was in flight, find
  `_statusAnswered` false because B had only just started, and mark a healthy B
  unanswered. Each probe start takes a new `_statusProbeGeneration` and stops
  any armed tick; the timer records `armedFor` and ignores a tick a newer probe
  has superseded.
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
| `status [--json]` | Host state, virtual output, live session, web UI URL, paired devices. Exit `0` running, `1` stopped, `2` not installed, `3` the unit state could not be read |
| `start` / `stop` / `toggle [--json]` | The paired lifecycle above |
| `ui [--json]` | Opens the web UI at the tailnet address — the only route a client has; `localhost` would be the wrong thing to hand over |
| `watch` | Streams normalised event tokens until killed |

## Not built

The pairing PIN flow. Submitting a PIN is a Web API call, and it is
HTTP-Basic-gated by the same credentials the section above declines to hold, so
it would reintroduce the exact cost that decision avoided. Pairing goes through
the web UI, which the popout links to.
