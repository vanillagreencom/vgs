# Remote desktop host (Sunshine)

VGS can host a Moonlight stream through Sunshine. The host is **not** part of an
ordinary session: its user unit ships `disabled`, nothing autostarts it, and the
virtual output it captures exists only while it runs. A local-only session
therefore has no phantom monitor and nothing listening on the network.

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
unit: that is not a different route to the same result, it is the silent
failure.

Three details that follow from that:

- **"The output is missing" and "nobody could say" are different answers.**
  `_rd_output_present()` returns `None` when hyprctl cannot be asked, and
  `start` **refuses** on `None` — treating an unanswerable probe as "present,
  go ahead" is the silent fallback above.
- **The output half is Hyprland-only, and "unknown" is a question, not a no.**
  Niri has no equivalent of `hyprctl output create headless`, so there the host
  still starts and the reply says, through `manual`, that it will capture an
  existing monitor. But `detect_compositor()` answers from the *calling
  process's* environment, and an ssh session has none of it, so it reports
  `unknown` — and ssh is exactly the path a remote-desktop host is most likely
  to be started from. `_rd_manages_output()` therefore probes on `unknown`,
  using the same ssh-aware environment `_rd_output_present()` uses, and grades
  it:

  | Situation | Result |
  |---|---|
  | hyprctl not installed | definitely not Hyprland — start without an output, say so |
  | hyprctl present, no instance in the runtime dir | no Hyprland running — same |
  | an instance resolves and hyprctl answers | **this is Hyprland over ssh** — create the output |
  | an instance resolves but hyprctl will not answer | **refuse** — a Hyprland session is here and unreachable, so a real monitor cannot be ruled out |
- **`captureFallback` is an assertion, so it needs a known status.** It claims
  "the host is capturing a real monitor right now" (host up, Hyprland, no
  `HEADLESS-1`), so `_markStatusUnknown()` clears it with the other axes — a
  warning nobody can substantiate costs trust in every other warning.
  `streaming` is the deliberate exception to unknown-clears-it; this is not
  one. The widget renders it as a warning, because nothing else in the system
  would ever mention it.

### Creating the output is transactional, and removing it needs provenance

The two halves are paired in both directions:

- **A created output is verified before the unit starts.** `hyprctl` exiting 0
  is not the output existing; `start` re-reads presence and refuses rather than
  starting blind, keeping "cannot tell" distinct from "absent". Nothing is
  rolled back on either refusal.
- **A failed start removes the output it created** — otherwise the user is left
  with a phantom monitor *and* no host. Only what that call created is rolled
  back; an output that was already there is left alone.
- **Stop removes the output only if VGS created it.** Removing any present
  `HEADLESS-1` could delete a virtual output the user set up for something
  else, which is not recoverable from the shell — so it needs provenance, not
  a name match.

Ownership is recorded only **after** that verification, so what was verified as
created is exactly what is owned and exactly what `stop` may remove — one record
answers all three.

Provenance lives in `~/.local/state/vshell/remote-desktop-output.json`, beside
the notification-takeover undo record and for the same reason: `start` and
`stop` are separate process invocations, so "did we create this?" cannot live in
memory.

**It cannot go stale, because it is keyed on the Hyprland instance signature.**
Headless outputs do not survive a compositor restart and the signature changes
with every start, so a record from a previous instance cannot describe the
output present now — `_rd_output_is_ours()` discards it. A record with no
signature to place it is not ownership either.

Three edge cases, all decided toward *not removing*:

| Case | Behaviour |
|------|-----------|
| Sunshine's state file is malformed | Only the paired-device list goes unknown, with the reason. Every shape is checked rather than assumed — a list, a scalar, a string `root` — so one bad field cannot take the host and session state down with it |
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

The lock cannot close the window against the unit changing on its own, so both
actions are also idempotent, and the losing path of each touches no output:
`start` on an already-running host returns immediately and creates nothing (a
running host has already chosen its capture target); `stop` on an
already-stopped unit is a `systemctl stop` that exits 0, with the output half
gated on ownership regardless.

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
(`Theme.error`, filled glyph, a word not just an icon).

Two further states cover not knowing: `unknown` (no usable answer yet, or the
last probe could not run) and `stale` (the event watch is down, so what is on
screen may be out of date). Both say so rather than presenting a guess as
current.

### Knowledge axes, reset together

*Nobody is watching* and *nobody knows* must never render alike, on any axis of
the answer. The table below is the list, deliberately not a count:

| Axis | Value | Known? |
|------|-------|--------|
| host | `installed`, `running` | `statusKnown` |
| session | `streaming` | `sessionKnown` |
| session count | `sessionCount` | `sessionCountKnown` |
| virtual output | `outputPresent` | `outputKnown` |
| paired devices | `pairedClients` | `pairedClientsKnown` |

`RemoteDesktopService._markStatusUnknown()` drops every one of them together.
Leaving one standing renders half an answer as a whole one — and `installed` in
particular **defaults to false**, so testing it before `statusKnown` displays
"Sunshine is not installed" for every instant before the first reply. A default
is not an answer.

The **session count** is finer-grained than the session it belongs to, because
watch events move it without settling it. Any event that can change how many
clients there are — a connect, a disconnect, or a host lifecycle transition —
marks it unknown until the authoritative read supplies a number; an encoder or
bitrate change within the current set of clients does not.
`countInvalidatingEvent()` is that rule, deliberately symmetric across connect
and disconnect.

### What can turn LIVE off

Exactly one thing: an authoritative `status --json` reply whose
`session.active` is false. Specifically:

- a `connected` event sets the indicator **immediately** — a connect is
  unambiguous, and this is the one fact worth showing a beat before the
  authoritative read confirms it. It does **not** carry a count with it:
  `sessionCountKnown` goes false and the popout reads "confirming…" until the
  authoritative read supplies a number, because a stale `0` beside a live
  capture reads as a fact rather than the gap it is;
- a `disconnected` event **does not clear it**. With more than one client
  connected it ends *one* session, not the capture. It only schedules the
  resync, and the session count decides;
- losing the answer entirely does not clear it either. `_markStatusUnknown()`
  leaves `streaming` set, and the widget tests `streaming` **before** every
  uncertainty state, so a capture that may still be live fails loud instead of
  being downgraded to a question mark. The uncertainty is reported beside it.

## Why the journal, not the Web API

Sunshine's Web UI has an API that would give the connected client's **name**
and its **requested resolution** — but it is HTTP-Basic-gated behind the
credentials in `~/.config/sunshine/sunshine_state.json`, so using it means
holding a second credential inside the shell purely to answer "is somebody
watching my screen". The journal already carries the events, at no such cost.

What that costs, stated rather than papered over: **the journal does not name
the connected client, and does not carry the requested resolution** — neither
is logged at Sunshine's `info` level. The popout therefore lists *paired*
devices from `named_devices` in that same state file, under a heading that says
paired, and says outright that which one is connected is not something the host
reports. Only `name` is read out of the file, never the credential material
beside it. A name containing bytes that are not valid UTF-8 is **withheld and
counted** rather than shown with U+FFFD substituted into it — a mangled name is
indistinguishable from a device genuinely called that. The detection does not
infer: every rendering of a real U+FFFD (literal UTF-8 or JSON escape) is
swapped for a private-use marker **before** the lenient decode, so afterwards a
U+FFFD can only be an undecodable byte and a marker can only be what the file
really contained; the marker is chosen from a candidate list only after
checking the file does not already contain it, and if none is safe, no name is
guessed at.

What the journal does carry, and the status payload does report: connect and
disconnect, Sunshine's own `active sessions` tally, the encoder, the streaming
bitrate and the colour depth.

The scan is bounded to the unit's current run via `ActiveEnterTimestamp` —
without that bound a `CLIENT CONNECTED` from a previous run, with no matching
disconnect because the daemon was killed, reads as a live session forever.

**There is no fallback window, deliberately.** An anchor that cannot be
established means no read: the session is reported unknown, never replayed
from unbounded history. A replay shows **LIVE with nobody connected**, and
inventing a capture trains the user to ignore the only indicator that says
somebody is watching their screen.

Likewise `_rd_unit_state()` separates "the unit is not installed" from
"`systemctl show` did not answer" (the shared `_user_unit_state()` reports both
as `exists: False`). An unanswered query produces `state: "unknown"` with
`unitKnown: false`, which the shell routes to the unknown rendering and the
lifecycle commands refuse to act on rather than treating as "stopped".

## Event-driven, and honest when it stops being

The subsystem is event-driven end to end — VGS-63 was a widget that fetched
status once and sat on the answer for a whole session, and this one is built
the other way round:

- `vshell remote-desktop watch` follows the unit's journal and prints one
  normalised token per interesting line — `connected`, `disconnected`,
  `lifecycle`, `session`. Sunshine's log format is parsed in exactly **one**
  place; a widget string-matching `CLIENT CONNECTED` would be a second copy of
  that knowledge, free to drift.
- Every token schedules a debounced `status --json` resync, which is the
  authority. `connected`/`disconnected` additionally flip the indicator
  immediately.
- systemd's own `Started`/`Stopped` records land in the same unit journal, so
  the host lifecycle needs no second watcher.
- The watch is ref-counted (`Common/Ref`): it runs only while something is
  displaying the state.

**If the watch dies**, session state becomes *unknown*, not unchanged.
`_markSessionUnknown()` drops `sessionKnown` and clears the cached session
detail — those values were only current because something was refreshing them —
and the service immediately calls `refresh()`, because the status read is a
separate process that does not depend on the watch.

The same rule applies at the *assignment* site. A status reply can be valid
while its session block is not: the helper returns `readable: false` with
`active` left at its default `false`, and taking that default at face value
would clear a live capture on the strength of a failed journal read.
`sessionApplyDecision()` is the guard — `active` is applied only from a block
that says it could be read; an unreadable one moves the session to unknown.

The reassuring direction is the one worse to get wrong, so it has its own state
too: a host that is up with an unreadable journal renders
`listening-unconfirmed` (`On?`, warning) rather than a plain `On`, which would
claim nobody is watching.

`streaming` is **not** cleared: that would claim "idle" on a dead watcher's
say-so, and only the authoritative session count may say a capture ended.

### The split has to reach the pixels

`stateColorTokenFor()` returns a colour token *name* per state, so the state
table is assertable without a Theme instance, and `stateColor` is derived from
it rather than from a second switch that could drift.

The bar pill's glyph takes that colour for the states that mean something is
happening or unknown, and keeps the bar's uniform `Theme.widgetIconColor` for
`off` and `listening`, where a differently coloured glyph is just noise. The
colour matters most in `icon` pill mode, where there is no text: without it,
`cast_connected` vs `cast` — a glyph shape at bar size — would be the only
difference between "someone is watching my screen" and "idle". Both the
horizontal and the vertical pill take it. There is also a fourth session
rendering, `streaming-unconfirmed` — still red, reading `LIVE?` — because a
plain `LIVE` would claim certainty nothing has and an idle pill would hide a
capture that may be running.

`RemoteDesktopService.watchLive` goes false and stays false until a restart
actually succeeds. Restarts back off 2s → 60s, and each successful start does a
full resync to cover what it missed while down. There is no polling fallback
that would quietly paper over a dead watch: the widget renders `stale` instead.
The backoff is reset by a watch that **survived** 60s (`watchStable`), never by
one that merely started — resetting on entry would make the cap unreachable for
a watcher that fails within milliseconds.

### Nothing is dropped, and nothing hangs

Rules of the same family:

- **A refresh requested while a probe is in flight is coalesced, not dropped.**
  The journal read behind `status --json` can take seconds while the event
  debounce is 400 ms, so an event arriving mid-probe would otherwise be lost
  outright. Any number of requests during one probe collapse into a single
  follow-up, launched once the probe has settled.
- **A lifecycle verdict waits for the collector.** `running` going false is not
  evidence of failure — the process usually stops a moment *before* its output
  is collected. `onExited` records the code and reports nothing; a 500 ms grace
  timer decides, and a zero exit reports nothing at all.
- **The verdict belongs to the action that launched it.** `busy` is held until
  the verdict resolves, and each action takes a `_lifecycleGeneration` the
  timer records — so no caller (toggle, IPC, another service) can have a
  failure reported under another action's name. A superseded verdict is
  dropped and leaves `busy` to the action that now owns it.
- **Every lifecycle failure reaches the user.** `start`/`stop`/`toggle` report
  through one surface, `_reportLifecycleFailure()`, keyed on `running` rather
  than `exited` — a command that cannot be spawned never exits, and that is
  exactly the failure the user is least able to diagnose. The helper's own
  JSON verdict may arrive after `exited` and replaces the generic message; the
  shared toast category means it updates in place rather than stacking.
  `ToastService` exempts that update from its error throttle only when the
  content actually changes — a correction is new information, a repeat is what
  the throttle is for.
- **The unanswered-grace timer belongs to one probe.** Each probe start takes a
  new `_statusProbeGeneration` and stops any armed tick; the timer records
  `armedFor` and ignores a superseded tick, so a tick armed by one probe can
  never mark a healthy newer probe unanswered.
- **A status command that cannot be spawned marks the state unknown.** Per
  `.github/instructions/quickshell-qml.instructions.md`, a `Process` that fails
  to start emits no `exited` at all, so the probe is keyed on `running` plus a
  500 ms unanswered grace, exactly as `NotificationService.qml`'s ownership
  probe is. Without it a missing binary leaves the default — "not installed" —
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

The pairing PIN flow. Submitting a PIN is a Web API call gated by the same
credentials the journal decision declines to hold. Pairing goes through the web
UI, which the popout links to.
