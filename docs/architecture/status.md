# Plugin status

Covers: shell/Core/PluginStatus.qml, shell/plugins/vgs.settings/StatusRow.qml, shell/plugins/vgs.settings/StatusLine.qml, shell/plugins/vgs.notifications/token-status.sh, scripts/smoke/rows/status.sh, scripts/smoke/fixtures/plugins/acme.status/**, scripts/test-plugin-status.js, scripts/test-notifications-token-status.sh

The runtime values a plugin publishes for its own instances and for its Settings page: a pending count, whether a check runs, whether a credential is stored. A plugin declares each value in its manifest, one instance writes it through the `status` capability, the core holds one record per plugin, and every instance of the plugin and the Settings window read that record. [D037](../decisions/D037-plugin-status.md) records the choice and refines [D032](../decisions/D032-settings-plugin-and-manifest-settings-convention.md); [D046](../decisions/D046-slack-tokens-per-workspace-and-one-card-per-message.md) adds the `presenceList` type.

## Declared

The manifest's `status` key maps a status key to `{ type, label, group?, hint?, command?, hidden? }`. `PluginLogic.validateManifest` judges it; `scripts/test-plugin-logic.js` pins each refusal by its text.

- A key matches `PluginLogic.STATUS_KEY_PATTERN`, a plain identifier such as `slackTokens`.
- `type` is one of `PluginLogic.STATUS_TYPES`, the table below. `label` and `group` are printable lines of at most 60 characters, `hint` of at most 200, `command` of at most 300. `hidden` keeps a typed entry off the Settings page.
- `command` is text. The page shows it in a `CodeLine` with a Copy button and never runs it.
- A `data` entry carries no `group`, `hint`, `command` or `hidden`, because the page never draws it.
- `status` needs capability `status`, and capability `status` needs at least one entry.

| Type | Value | Tone on the page |
|---|---|---|
| `presence` | `present`, `absent`, `locked`, `unavailable` or `unsafe` | `success`, `warning`, `info`, `neutral`, `danger`, from `PluginLogic.STATUS_PRESENCE_TONES` |
| `presenceList` | a list of at most `PluginLogic.STATUS_LIST_MAX`, 32, items `{ label, value, hint?, command? }`, below | none of its own; each item the tone of its `value`, as a `presence` |
| `state` | `{ tone, text }`: `tone` one of `ok`, `info`, `warning`, `danger`, and a printable `text` of at most 200 characters | `success`, `info`, `warning`, `danger`, from `PluginLogic.STATUS_STATE_TONES` |
| `text` | a printable line of at most 200 characters | none |
| `count` | a whole number from 0 | none |
| `time` | whole milliseconds since the Unix epoch, as `Date.now()` answers | none; drawn as the local short date and time |
| `data` | plain JSON: null, booleans, finite numbers, strings, arrays and plain objects | never drawn |

A `presence` value answers whether a credential is stored without its value: stored and readable, not stored, stored in a locked collection a background probe must not unlock, a store that cannot be asked, or stored where another user can read it. D037 gives each value's meaning and tone.

A `presenceList` value is one `presence` per thing the manifest cannot list ahead, such as one credential per account the plugin finds. Each item carries only `STATUS_LIST_ITEM_KEYS`: a `label`, a printable line of at most 60 characters; a `value`, a `presence` value; and, when present, a `hint` of at most 200 and a `command` of at most 300, printable lines as a declaration's are. `PluginLogic.statusValueFits` judges each item.

## Published

- `shell.status.set(key, value)` answers `ok` or one keyed line, `refused: status=<key> reason=<reason>`: `undeclared` for a key the manifest does not declare, `type` for a value that does not fit its type, `size` for values whose JSON would pass `PluginLogic.STATUS_MAX_BYTES`, 64 KiB, and `retired` for a write from an instance whose plugin is disabled or whose source revision was replaced. A refused write changes nothing. `PluginLogic.statusWrite` judges the first three.
- `shell.status.values` is the plugin's published values, and an empty object before the first write. Each read answers a deep-frozen copy of its own, which neither the writer nor another reader can reach: the engine lets a frozen array be written in place ([runtime-qml.md](runtime-qml.md)), so a reader that changes an array changes only its copy. `shell.status.revision` is the serial of the last write, 0 before one. Both are bindable: a binding that reads them re-evaluates on every write.
- `PluginStatus.qml` holds one record per plugin id. The record lives while the plugin is enabled at the source revision that wrote it. Disabling the plugin, or a rescan that gives it a new revision, drops it, and the rebuilt service publishes again from nothing. Nothing is written to disk.
- The lending record, `vgsh ipc call shell lent`, lists each record under `status` with its keys, its revision and its size in bytes.

## Convention

- The service writes. Bar widgets, flyouts and the Settings page read.
- One writer per key: a value that two instances write has two answers.
- A credential's value never enters status. Its presence does, from a probe that does not read it.
- A value that must survive a restart lives in the plugin's own state file, and the service publishes it again at start.

## Shown

- `Registry.managerRows` gives each plugin `status`, `PluginLogic.statusRows`: one row per entry that is not `data` and not `hidden`, in manifest order, `{ key, type, label, group, hint, command, report, value, tone }`, `report` `reported` or `unreported`. A reported `presenceList` row's `value` is its items, each `{ label, value, hint, command, tone }` with `hint` and `command` "" when the item omits them and `tone` its presence's; the row's own `tone` is "".
- The Settings page draws a Status section above the settings form: one `StatusRow` per row, entries without a `group` first under `Status`, then each group in the order its first entry appears. A row draws `StatusLine`s: the label beside the value, a `Badge` in the row's tone for `presence` and `state` and a line of text otherwise, the hint under it, and the command in a `CodeLine`. A `presenceList` row draws its label and hint, "None detected" while the list is empty, then one line per item: the item's label beside a `Badge` of its presence, its hint and its command. An unreported row, and every row of a disabled plugin, reads "Not reported". No row takes an edit.

## The Slack token rows

`vgs.notifications` declares `slackTokens`, a `presenceList` in group `Slack`, whose hint says how to make a token. `token-status.sh [<team id>...]` asks for each listed workspace's account, `slack:<team id>`, then the single-workspace account `slack`, and prints one `slack-token: account=<account> <state>` line each, `present`, `absent`, `locked` or `unavailable`, from `secret-tool search` without `--unlock`, whose stdout, the only place it prints a token, goes to `/dev/null`; it reads the items' attributes and errors from stderr. `SlackPhotos.qml` runs it once Slack's workspace list is read, when the list names other workspaces and after each run of the photo helper; `NotificationLogic.slackTokenStates` reads it, and a probe that fails is logged and read as every account `unavailable`. The service publishes `NotificationLogic.slackTokenRows`: one item per listed workspace, labelled with its name and domain, carrying its own account's state and the `secret-tool store` command for that account, which names the team id alone; a workspace whose own token is absent while the photo cache says the single-workspace token serves it carries that token's state and says so; then the single-workspace token's item when no workspace is listed or it is stored.

## Invariants

1. Every instance of a plugin reads one record: the service, a bar widget on each of two screens and a summoned panel read one revision and one set of values. Enforced by `scripts/smoke/rows/status.sh`.
2. Only a declared key with a value of its type, inside the ceiling, is published; the published values do not change in place. Enforced by `scripts/test-plugin-status.js`, each rule with a control, and by `scripts/smoke/rows/status.sh`, which reads each refusal by its text.
3. A disabled plugin holds no record, a new source revision drops it, and a retired instance's write cannot bring it back. Enforced by `scripts/smoke/rows/status.sh`, from the lending record.
4. The Settings page draws no `data` or hidden entry and no row takes an edit. Enforced by `scripts/test-plugin-status.js` and `scripts/smoke/rows/settings.sh`.
5. The Slack token probe never reads a token and never prints one. Enforced by `scripts/test-notifications-token-status.sh`, with a control that reads the search's stdout and one that prints the token, and by `scripts/smoke/rows/notifications.sh`, which reads the rows after each set of states of the stub store and finds a token in no record, row or log line.
6. A `presenceList` item holds only its keys, a label and a presence, and its row carries each item's tone. Enforced by `scripts/test-plugin-status.js`, each rule with a control.

## Decisions

[D037](../decisions/D037-plugin-status.md), [D046](../decisions/D046-slack-tokens-per-workspace-and-one-card-per-message.md), [D032](../decisions/D032-settings-plugin-and-manifest-settings-convention.md), [D012](../decisions/D012-core-owns-lent-objects.md).
