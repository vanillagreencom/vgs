# Bluetooth agent

Covers: shell/Core/BluetoothAgent.qml, shell/Core/BluetoothAgentModel.js, scripts/test-bluetooth-agent.js, scripts/smoke/rows/bluetooth-agent.sh, scripts/smoke/fixtures/plugins/acme.pairing/**

The `bluetoothAgent` capability lends BlueZ's default pairing agent to one plugin at a time: [D085](../decisions/D085-bluetooth-agent-core-lent-over-bluetoothctl.md). The core runs one `bluetoothctl --agent KeyboardDisplay` child while a lease is held and answers its prompts with what the holder decides. `BluetoothAgentModel.js` makes every decision, and `BluetoothAgent.qml` runs its effects on the child and one timer. The members are in [`.agents/skills/vgs-plugin/references/api.md` § The shell object](../../.agents/skills/vgs-plugin/references/api.md#the-shell-object). Every source line below is BlueZ 5.87's.

## The child

- `bluetoothctl` registers the agent with the capability its `--agent` argument names as soon as `AgentManager1` appears (`client/main.c:496-505`). Sending `agent KeyboardDisplay` on stdin instead races that registration (`client/agent.c:395-430`). With no command argument the shell stays interactive (`src/shared/shell.c:1415`) and reads stdin through readline even from a pipe.
- The core waits for `Agent registered`, writes `default-agent`, and waits for `Default agent request successful`. Each wait lasts `ACK_TIMEOUT_MS`, 5000 ms. A later unsolicited `Agent registered`, after bluetoothd came back, sends `default-agent` again. `Agent released` or an unsolicited `Agent unregistered` makes the lease pending, with no timeout, until then.
- The child is resolved on the shell's PATH and is an optional core requirement, `config/requirements.json`.
- The model writes only after the child printed, so after it started. Stdout is read raw, through a `SplitParser` with an empty marker, since a prompt ends with no newline ([runtime-qml.md](runtime-qml.md)).

## States

| State | Child | Leaves on |
|---|---|---|
| `off` | none | the first lease: `starting` |
| `starting` | launched, waiting for `Agent registered` | registration: `defaulting`; a failure or the timeout: `closing` |
| `defaulting` | wrote `default-agent` | the acknowledgement: `ready`; a failure or the timeout: `closing` |
| `ready` | BlueZ's default agent | the last release: `releasing`; BlueZ releasing the agent: `starting` |
| `releasing` | wrote `agent off` | `Agent unregistered`, `No agent is registered`, a failure or 2000 ms: `closing` |
| `closing` | stdin closed | the exit; after 2000 ms the child is killed: `stopping` |
| `stopping` | killed | the exit |
| `failed` | none | the release of the last refused lease: `off`; a new lease: `starting` |

The child's exit starts it again when a lease was begun meanwhile, leaves `failed` while a refused lease is held, and `off` otherwise. Nothing restarts it on its own.

## Leases

- `begin(reason)` takes a counted lease. `reason` is 1 to 80 characters with no control character; another value throws `refused: bluetoothAgent reason=<json>`. The first open lease starts the child and later leases join it, since the holder's panel and pane are two instances. A lease reads `pending` when `begin` returns, `ready` after both acknowledgements, and a lease begun while ready resolves through `Qt.callLater`, never inside `begin`.
- A lease is released by `release()` or with its instance. The last release declines an open prompt, writes `agent off`, closes stdin once BlueZ answers, and kills the child 2000 ms after that.
- A refusal goes to every open lease and ends the child: `refused: agent=busy reason=register-failed error=<name>`, `reason=default-failed error=<name>` (`error=none` for `No agent is registered`), `reason=ended code=<n>` (`code=none` for a child that never started) or `reason=timeout`. BlueZ cannot tell the core whether another agent holds the default, so `busy` names only what the core observed.

## The default stack

`AgentManager1` has RegisterAgent, UnregisterAgent and RequestDefaultAgent, and nothing that reads the default. `src/agent.c` keeps the default agents as a stack: `agent_create` makes a new agent the default only when none is queued (l.278-281), `request_default` and `add_default_agent` move the caller to the head and never refuse (l.1006-1029, l.139-153), and `remove_default_agent`, run when an agent unregisters or its connection drops, makes the next queued agent the default again (l.156-172). A lease therefore takes the default, and its release gives it back to the agent that held it before, such as Omarchy's `bt-agent`.

## Requests

| bluetoothctl prints | Entry | Answer written |
|---|---|---|
| `Request confirmation`, then `[agent] Confirm passkey <code> (yes/no): ` | `confirm` with `code` | `yes` for true, `no` for false |
| `Request PIN code`, then `[agent] Enter PIN code: ` | `pin` | the PIN; `PIN_DECLINE` for false |
| `Request passkey`, then `[agent] Enter passkey (number in 0-999999): ` | `passkey-entry` | the number in decimal; `no` for false |
| `Request authorization`, then `[agent] Accept pairing (yes/no): ` | `authorize` | `yes` or `no` |
| `Authorize service`, then `[agent] Authorize service <uuid> (yes/no): ` | `authorize` with `service` | `yes` or `no` |
| `[agent] Passkey: <code>`, once per typed key | `passkey-display` with `code` and `entered`, one entry per code | nothing; any answer dismisses it |
| `[agent] PIN code: <pin>` | `passkey-display` with `code` | nothing; any answer dismisses it |
| `Request canceled` | the open entry becomes `cancel`, same id | nothing; any answer dismisses it |

- An entry is `{ id, kind, code, service, entered }`; ids rise per shell. bluetoothctl prints no device for any request (`client/agent.c:118-261`), so an entry names none and the holder pairs one device at a time.
- The request line creates the entry, once the prompt that follows it is drawn. A prompt drawn again after another message is the same prompt. `entered` counts the digits printed in bold gray, read before the colours are stripped.
- bluetoothctl's answer words are `client/agent.c:52-91`'s: `no` rejects a yes/no or passkey prompt, and any other word cancels. A PIN prompt takes the whole line as the PIN, so false writes `PIN_DECLINE`, 17 zeros, which BlueZ refuses as longer than 16 characters and fails the request (`src/agent.c:491-499`).
- `answer` refuses a value of the wrong type as `refused: request=<id> reason=value want=boolean|pin|passkey` and an id with no entry as `refused: request=<id> reason=unknown`. A PIN is 1 to 16 printable ASCII characters, with no leading `#`, which bluetoothctl reads as a comment, and no leading or trailing space. A line break or any control character is refused: while a prompt is open the next line written is its answer, and a line break would let a holder type bluetoothctl commands.
- No command is written while a prompt is open. Release, and BlueZ releasing the agent, decline it first. After BlueZ released the agent bluetoothctl keeps the prompt open (`client/agent.c` `agent_release` drops the request before `agent_release_prompt` looks for it), so the decline closes it.
- A `Request ...` or `Authorize ...` line the table does not know, or an `[agent] ...` prompt that is not the one its request line announced, is answered `no` at once, logged as `bluetoothAgent: refused: prompt=unknown text=<the text, 80 characters at most>` and never listed. If that prompt reads its line as a PIN, `no` fails at BlueZ's pairing step rather than at once. No answer value and no code is logged.
- Output that grows past 8192 characters with no line end is dropped, logged once per child.
- bluetoothctl prints a device's name as it is, so a name that holds a line break can print a line the table reads. The answer to such a line reaches bluetoothctl, which holds no prompt for it, as an unknown command.

## Invariants

1. A lease resolves only after both acknowledgements, release writes `agent off` after declining any open prompt, an answer holds no line break or control character, a redraw lists no second request, and each request kind, refusal and unknown prompt maps as the tables above state. Enforced by `scripts/test-bluetooth-agent.js`, which replays bluetoothctl's raw output whole and split every 1, 4 and 13 characters, with a control per rule.
2. `bluetoothAgent` is exclusive. Enforced by `scripts/test-plugin-logic.js` and the smoke row.
3. In the nested sandbox, over the bluetoothctl stand-in ([validation-smoke-devices.md](validation-smoke-devices.md)), a fixture lease reads pending then ready, the child runs as `bluetoothctl --agent KeyboardDisplay` and reads `default-agent`, a planted confirm prompt is one request answered `yes`, release writes `agent off` and closes stdin, disabling a holder ends the child and its hold, a second holder builds only once the first lets go, and a refused default role refuses the lease and leaves no child. Enforced by `scripts/smoke/rows/bluetooth-agent.sh`, whose last transcript is the control.

The transcripts are written from BlueZ 5.87's source; no check runs the host's `bluetoothctl`, which would reach the host's BlueZ.
