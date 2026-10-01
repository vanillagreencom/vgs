# D085: The Bluetooth agent is a core-lent exclusive capability over bluetoothctl, held per lease

[← Decision Index](INDEX.md)

**Date**: 2026-10-01

**Status**: Active

**Research**: [docs/plans/v2-system-plan.md](../plans/v2-system-plan.md) §§ 2.6, 3.2

**Refines**: [D012](D012-core-owns-lent-objects.md)

**Context**: Pairing a device that asks for a confirmation, a PIN or a passkey needs a BlueZ agent, and Quickshell 0.3.1 registers none: `quickshell-bluetooth.qmltypes` has no agent type. The default agent is a session-wide role, and [D012](D012-core-owns-lent-objects.md) gives such roles to the core, as the polkit agent is ([D062](D062-native-lock-and-polkit-plugins.md)). A plugin may not run its own long-lived agent process.

**Decision**: The core lends capability `bluetoothAgent`, exclusive like `lock` and `polkit`.

- A holder takes a counted lease with `begin(reason)`. The first open lease starts one `bluetoothctl --agent KeyboardDisplay` child; the lease resolves only after BlueZ acknowledged the registration and then the `default-agent` request. The last release declines any open prompt, writes `agent off`, closes stdin and ends the child, and destroying the holder releases its leases.
- The capability lends the open prompts as `requests`, `{ id, kind, code, service, entered }`, and `answer(id, value)` writes the reply. An answer never holds a line break or control character. An unknown prompt is rejected at once and logged.
- The lease takes BlueZ's default and gives it back on release. BlueZ 5.87 keeps default agents as a stack (`src/agent.c`): `agent_create` makes a new agent the default only when none is queued (l.278-281), `request_default` and `add_default_agent` move the caller to the head and never refuse (l.1006-1029, l.139-153), and `remove_default_agent`, run when an agent unregisters or its connection drops, makes the next queued agent the default again (l.156-172). `AgentManager1` has no member that reads the default.
- `refused: agent=busy` answers only what the core observes: a registration or default-agent failure bluetoothctl prints, or a child that ends or stays silent past the acknowledgement timeout.
- An entry names no device: bluetoothctl 5.87 reads the device for every agent request and prints none (`client/agent.c:118-261`). The holder pairs one device at a time and names it itself.

[bluetooth-agent.md](../architecture/bluetooth-agent.md) holds the contract.

**Rationale**:

- bluetoothctl is BlueZ's own client, packaged on each distribution `config/requirements.json` names. Quickshell 0.3.1 offers no agent type and no way to export a D-Bus object from QML.
- `--agent KeyboardDisplay` registers as bluetoothctl starts (`client/main.c:496-505`), so no stdin command races the registration it makes on its own (`client/agent.c:395-430`). KeyboardDisplay lets BlueZ pick every pairing method, each shown to the user.
- A lease keeps the agent alive only while a holder pairs or waits for an inbound request, so a shell with no holder claims no Bluetooth role. The stack gives the default back on release instead of taking it from another agent for good.
- Exclusivity gives one plugin the prompts; the counted lease lets that plugin's panel and pane share them.

## Where VGS differs from Omarchy

| Omarchy | VGS | Why |
|---|---|---|
| A user unit, `bt-agent.service`, runs `bt-agent -c NoInputNoOutput` at login and accepts every request (`default/systemd/user/bt-agent.service:9-23`). | The core runs `bluetoothctl --agent KeyboardDisplay` while a holder holds a lease, and the holder shows every prompt. | VGS installs no user unit by default, and a pairing the user did not see is not accepted. |

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| A plugin runs its own agent | The default agent is session-wide; two plugins would contend for it ([D012](D012-core-owns-lent-objects.md)). |
| Refuse a lease when another agent holds the default | BlueZ offers no read of the default, and its stack restores the earlier agent on release. |
| `bt-agent -c NoInputNoOutput`, as Omarchy runs it | NoInputNoOutput accepts every pairing without asking the user. |
| Send `agent KeyboardDisplay` on stdin | It races bluetoothctl's own registration and fails with `Agent is already registered` or `Failed to register agent object`. |

**Revisit When**: Quickshell ships a BlueZ agent type, BlueZ changes its default-agent stack or gains a read of the default, or bluetoothctl changes its prompt text.

**Verification**: `scripts/test-bluetooth-agent.js` replays bluetoothctl's raw output through the model, with a control per rule. `scripts/test-plugin-logic.js` pins the exclusivity. `scripts/smoke/rows/bluetooth-agent.sh` drives a fixture holder over the bluetoothctl stand-in in the nested sandbox.

**References**: [D012](D012-core-owns-lent-objects.md), [D062](D062-native-lock-and-polkit-plugins.md), [D075](D075-consumer-features-need-no-developer-setup.md), [bluetooth-agent.md](../architecture/bluetooth-agent.md)
