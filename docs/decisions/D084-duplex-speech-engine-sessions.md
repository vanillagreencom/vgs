# D084: The duplex speech engine owns one GPT-Live session per conversation

[← Decision Index](INDEX.md)

**Date**: 2026-10-01
**Status**: Active
**Research**: [Jarvis plan § Speech engines](../plans/v2-jarvis-plan.md#35-speech-engines-playback-accounting-latency), [§ 2.2 speech providers](../plans/v2-jarvis-plan-research.md#22-speech-providers)
**Refines**: none

**Context**: GPT-Live is a full-duplex voice model on one WebSocket. It owns turn-taking and speech, needs a continuous input stream to advance its session timeline, sends output audio without timing or a done event, and has no truncate event. Delegation is client or Responses mode, chosen at startup; client mode is also the default when the field is omitted. Session's reducer was built around a chained turn: collect, brain, play.

**Decision**: The duplex engine is one backend module behind Session's speech port and Audio's sink and source.

- Session names the engine kind in the snapshot. A duplex conversation opens one speech session before its first capture, collects no utterance, and closes the session when the conversation ends. The reducer holds one reply admission; replies play when playback is idle, the conversation is active and no talk key is held. A reply takes the same [half-duplex admission](../architecture/jarvis-audio-duplex.md#admission-and-resume) as a chained one: capture closes before playback starts.
- The engine connects only through `net.js`, with an origin-bound key looked up at first need. Every input frame passes the release gate. While no capture feeds the session it sends paced silence.
- Interruption drops the queued reply and discards output until user speech after that point on the session timeline is transcribed. The server's interruption handling stands.
- After 60 s idle the engine reports it, Session ends the conversation, and the engine sends `session.close` with a bounded wait for `session.closed`.
- J36 configures client delegation and refuses every delegation as a keyed fault. J37 replaces the refusal with brain, gate and commentary.
- Any server error, unexpected close or refused frame is a keyed fault that ends the conversation. No other voice takes over.

**Rationale**:
- Session stays the one lifetime judge: stale speech callbacks are dropped and counted like every other port's.
- Discarding by session timeline needs no truncate event and no output timing, which the primary WebSocket does not send.
- A session cannot run without a delegation mode, so a loud refusal is the only way to neither delegate nor drop one silently.
- Paced silence keeps hold mode working: without input the voice model never hears the turn end.
- omarchy-voice's `live.py` proves the endpoint and event set; VGS takes its silence while gated and differs as [jarvis-live.md](../architecture/jarvis-live.md#omarchy-comparison) states.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Fit the duplex engine into the chained turn (collect, final, brain) | GPT-Live owns turn-taking; a final transcript never starts its reply. |
| Responses delegation | Results would reach the voice model without Jarvis's policy gate. |
| Ignore `session.delegation.created` until J37 | The model would wait on a delegation nobody answers. |
| Stop input when the talk key is released | The session timeline stops, and the model never answers. |
| Treat all output after an interruption as the old reply until a fixed delay | No delay separates the old reply from a new answer; the transcript does. |
| A vendor SDK | VGS ships no npm tree ([D079](D079-brains-wire-and-harness-adapters.md)). |

**Boundaries**: J36 lands the engine, the Session regions, the wire `transcript` message and the service's caption status. J37 adds delegation. The daemon selects the engine once voice and account selection and J16's indicator exist. J33, J35 and J38 to J41 own the chained engines and refine this record.

**Revisit When**: GPT-Live adds a truncate event, output timing on the primary WebSocket, or a session without delegation; or a second duplex provider needs a different session lifetime.

**Verification**: `scripts/test-jarvis-live.js` replays schema-pinned scripts from a loopback WebSocket server in the Jarvis test world through the real engine, reducer and runner, with a disposable mutant per rule. `scripts/test-jarvis-session.js` pins the duplex regions with their mutants. `scripts/test-jarvis-daemon.js` reads a caption on the daemon's stdout.

**References**: [Jarvis GPT-Live engine](../architecture/jarvis-live.md), [Jarvis session](../architecture/jarvis-session.md), [D073](D073-jarvis-release-and-origin-bound-keys.md).
