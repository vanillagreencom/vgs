# Status actions and secrets

Covers: shell/Core/SecretWriter.qml

The one-click setup steps a plugin's status entries offer on its Settings page, and the libsecret items the core stores and clears for it. The entries, their values and their rows are [status.md](status.md)'s; the rule that a setup step is automatic or one click is [design-system.md § Setup steps](design-system.md#setup-steps).

## Actions and secrets

- **When.** The value's writer decides when its entry's action applies: a `presence` while `absent`, a `state` while it carries `action: true`. `PluginLogic.statusActionOffered` is the one rule, and an unreported entry offers nothing.
- **Act.** The `manager` capability's `act(id, key)` answers `PluginLogic.statusActionRequest`: `unknown: <id>`, or `refused: action=<key> reason=` `undeclared`, `disabled` or `not-offered`; otherwise the core opens the plugin's own TUI through `TuiRunner.runFor`, judged as the plugin's `shell.tui.run` is and answering `ok` for a busy key it focuses, or raises the requirement notice for the commands through `Notices.acted`, which no offer's rest holds back ([requirement-notice.md](requirement-notice.md)).
- **Secrets.** A manifest's `secrets`, `{ service, label }`, needs capability `secrets` and a `presenceList` entry to list its items; `PluginLogic.secretsError` judges it. An item with a `secret` is offered `connect` while `absent` and `disconnect` while `present`, `locked` or `unsafe`, `PluginLogic.SECRET_ACCESS`, and nothing while `unavailable`. The `manager` capability's `storeSecret(id, key, account, secret, done)` and `clearSecret(id, key, account, done)` answer `PluginLogic.secretRequest`: `refused: secret=<account> reason=` `undeclared`, `disabled`, `unlisted` for an account no published item of `key` names, `not-offered` for a verb its access does not offer, or `value` for a secret that is empty, longer than 4096 characters or holds a control character; `busy` while another write runs.
- **The writer.** `SecretWriter`, in `Capabilities`, runs one write at a time: `secret-tool store --label=<label and account> service <service> account <account>`, the label the `secrets` label, a space and the account, the secret written to its stdin and stdin closed, since secret-tool keeps every byte of a stdin that is no terminal, or `secret-tool clear service <service> account <account>`. `done` receives `{ ok, reason }` and is dropped with the asking instance. Each ended write logs `secrets: <verb>=<id>/<account> ok` or `failed <reason>` and raises the plugin's `shell.secrets.revision`, which its instances read to probe the store again. No secret enters an argv, a log line, a reply or a status value.

## Invariants

1. An action runs only while its value offers it, and only the plugin's own TUI or requirement commands; a secret is written only for an account the plugin lists, by the verb its presence offers, and reaches secret-tool on stdin alone. Enforced by `scripts/test-plugin-status.js`, each rule with a control, one of them a copy that puts the secret on the argv; in the nested sandbox by `scripts/smoke/rows/settings.sh`, which presses the status fixture's actions, and the automations, agent-warden, devtools, themes and notifications rows, which press each plugin's step and read a refusal back as the control, the notifications row reading the stand-in secret-tool's argv and stdin.

## Decisions

[D059](../decisions/D059-no-manual-commands.md), [D037](../decisions/D037-plugin-status.md), [D033](../decisions/D033-floating-tuis-are-core.md), [D035](../decisions/D035-manifest-requirements.md).
