# Plugin status

Covers: shell/Core/PluginStatus.qml, shell/plugins/vgs.settings/StatusRow.qml, shell/plugins/vgs.settings/StatusLine.qml, scripts/smoke/rows/status.sh, scripts/smoke/fixtures/plugins/acme.status/**, scripts/test-plugin-status.js

The runtime values a plugin publishes for its own instances and for its Settings page: a pending count, whether a check runs, whether a credential is stored. A plugin declares each value in its manifest, one instance writes it through the `status` capability, the core holds one record per plugin, and every instance of the plugin and the Settings window read that record. [D037](../decisions/D037-plugin-status.md) records the choice and refines [D032](../decisions/D032-settings-plugin-and-manifest-settings-convention.md); [D046](../decisions/D046-slack-tokens-per-workspace-and-one-card-per-message.md) adds the `presenceList` type, and [D061](../decisions/D061-no-manual-commands.md) the actions and secrets that make a setup step one click.

## Declared

The manifest's `status` key maps a status key to `{ type, label, group?, hint?, action?, command?, hidden? }`. `PluginLogic.validateManifest` judges it; `scripts/test-plugin-logic.js` pins each refusal by its text.

- A key matches `PluginLogic.STATUS_KEY_PATTERN`, a plain identifier such as `slackTokens`.
- `type` is one of `PluginLogic.STATUS_TYPES`, the table below. `label` and `group` are printable lines of at most 60 characters, `hint` of at most 200, `command` of at most 300. `hidden` keeps a typed entry off the Settings page.
- `action` is the entry's one-click setup step, on a `presence` or `state` entry alone: `{ label, tui }`, one of the manifest's own `tui` scripts, `{ label, install }`, a list of its own requirement commands, each once, or `{ label, system }`, a step of its own `systemSteps` ([tui-system.md](tui-system.md)). `PluginLogic.statusActionError` judges it.
- `command` is text, and needs an `action`: the page shows it only behind that action's Show command disclosure, a `CommandDisclosure`, and never runs it.
- A `data` entry carries no `group`, `hint`, `action`, `command` or `hidden`, because the page never draws it.
- `status` needs capability `status`, and capability `status` needs at least one entry.

| Type | Value | Tone on the page |
|---|---|---|
| `presence` | `present`, `absent`, `locked`, `unavailable` or `unsafe` | `success`, `warning`, `info`, `neutral`, `danger`, from `PluginLogic.STATUS_PRESENCE_TONES` |
| `presenceList` | a list of at most `PluginLogic.STATUS_LIST_MAX`, 32, items `{ label, value, hint?, secret?, command? }`, below | none of its own; each item the tone of its `value`, as a `presence` |
| `state` | `{ tone, text, action? }`: `tone` one of `ok`, `info`, `warning`, `danger`, a printable `text` of at most 200 characters, and `action`, a boolean, only for an entry that declares one | `success`, `info`, `warning`, `danger`, from `PluginLogic.STATUS_STATE_TONES` |
| `text` | a printable line of at most 200 characters | none |
| `count` | a whole number from 0 | none |
| `time` | whole milliseconds since the Unix epoch, as `Date.now()` answers | none; drawn as the local short date and time |
| `data` | plain JSON: null, booleans, finite numbers, strings, arrays and plain objects | never drawn |
| `choices` | a list of at most `PluginLogic.STATUS_LIST_MAX` items `{ label, value }` | a setting's Select, never a Status row |

A `presence` value answers whether a credential is stored without its value: stored and readable, not stored, stored in a locked collection a background probe must not unlock, a store that cannot be asked, or stored where another user can read it. D037 gives each value's meaning and tone.

A `presenceList` value is one `presence` per thing the manifest cannot list ahead, such as one credential per account the plugin finds. Each item carries only `STATUS_LIST_ITEM_KEYS`: a `label`, a printable line of at most 60 characters; a `value`, a `presence` value; and, when present, a `hint` of at most 200, a `secret`, the account of the manifest's `secrets` the item is the presence of, matching `PluginLogic.SECRET_ACCOUNT_PATTERN`, and a `command` of at most 300, which needs the `secret`. `PluginLogic.statusValueFits` judges each item, and `statusWrite` refuses a `secret` from a manifest without `secrets` and a state's `action` for an entry without one, as `type`.

## Actions and secrets

An entry's `action`, its `command` and a manifest's `secrets`, the one-click setup steps the Settings page draws: [status-actions.md](status-actions.md).

## Setting choices

A string schema entry's `optionsFrom` names a `choices` status key of the same plugin, including a hidden entry. `PluginLogic.schemaError` refuses another type, a malformed key, an undeclared key or a key of another status type. Static `options` remains enum-only. [D057](../decisions/D057-setting-options-from-status.md) refines D032 and D037.

- Each choice holds only `label` and `value`. Both are non-empty printable lines. A label fits `STATUS_LABEL_MAX`, and a value fits `STATUS_TEXT_MAX`. Values are distinct; labels may repeat. An empty list is valid. `PluginLogic.statusValueFits` judges the list under the existing status byte ceiling.
- `Registry.managerRows.settingChoices` holds one Select model per string with `optionsFrom`, built by `PluginLogic.settingChoices`. It copies the accepted offers, adds an empty-string first-offered entry, and adds the configured id marked unavailable when it is not offered. Unreported or disabled status supplies no offers. The models never reach the status record or configuration by reference.
- Empty string means the first offered value. The plugin consuming the setting resolves it from its own status; with no offer it has no selected value. The core delivers the configured string unchanged. It never stores the first offer.
- A status update, a renamed label, reordered offers, an empty list, disable or source replacement changes no setting. A configured id no longer offered stays visible and stored. The string setting judge still accepts it.
- `SettingField` draws the existing `qs.Ui` Select. `Select.activated` applies the selected id only on a user choice, never on a model or binding change. The editor restores its index binding after the choice, so a refused save shows the configured value again.

`scripts/test-plugin-logic.js` and `scripts/test-plugin-status.js` pin these rules with must-fail controls. `scripts/smoke/rows/settings.sh` reads the drawn model, saved id, unavailable value and no-write refreshes from `acme.status`. `scripts/smoke/rows/status.sh` reads the list from every instance and verifies reader isolation.

## Published

- `shell.status.set(key, value)` answers `ok` or one keyed line, `refused: status=<key> reason=<reason>`: `undeclared` for a key the manifest does not declare, `type` for a value that does not fit its type, `size` for values whose JSON would pass `PluginLogic.STATUS_MAX_BYTES`, 64 KiB, and `retired` for a write from an instance whose plugin is disabled or whose source revision was replaced. A refused write changes nothing. `PluginLogic.statusWrite` judges the first three.
- `shell.status.act(key)` runs the plugin's own action of entry `key`: [status-actions.md](status-actions.md).
- `shell.status.values` is the plugin's published values, and an empty object before the first write. Each read answers a deep-frozen copy of its own, which neither the writer nor another reader can reach: the engine lets a frozen array be written in place ([runtime-qml.md](runtime-qml.md)), so a reader that changes an array changes only its copy. `shell.status.revision` is the serial of the last write, 0 before one. Both are bindable: a binding that reads them re-evaluates on every write.
- `PluginStatus.qml` holds one record per plugin id. The record lives while the plugin is enabled at the source revision that wrote it. Disabling the plugin, or a rescan that gives it a new revision, drops it, and the rebuilt service publishes again from nothing. Nothing is written to disk.
- The lending record, `vgsh ipc call shell lent`, lists each record under `status` with its keys, its revision and its size in bytes.

## Convention

- The service writes. Bar widgets, flyouts and the Settings page read.
- One writer per key: a value that two instances write has two answers.
- A credential's value never enters status. Its presence does, from a probe that does not read it.
- A value that must survive a restart lives in the plugin's own state file, and the service publishes it again at start.

## Shown

- `Registry.managerRows` gives each plugin `status`, `PluginLogic.statusRows` over `Registry.activeManifestOf`, the manifest without the entries of an owner-only extra that is off ([D075](../decisions/D075-consumer-features-need-no-developer-setup.md)); the manager's action and secret steps judge that view too, so they refuse such an entry as `undeclared`: one row per entry that is not `data`, `choices` or `hidden`, in manifest order, `{ key, type, label, group, hint, command, action, report, value, tone }`, `report` `reported` or `unreported` and `action` null or `{ label, offered }`. A reported `presenceList` row's `value` is its items, each `{ label, value, hint, command, tone, secret, access }` with `hint`, `command` and `secret` "" when the item omits them, `tone` its presence's and `access` `connect`, `disconnect` or ""; the row's own `tone` is "". Beside `status`, each plugin's manager row carries `secretLabel`, the manifest's `secrets` label or "", which a Connect's field asks for.
- The Settings page draws a Status section above the settings form: one `StatusRow` per row, entries without a `group` first under `Status`, then each group in the order its first entry appears. A row draws `StatusLine`s: the label beside the value, a `Badge` in the row's tone for `presence` and `state` and a line of text otherwise, the hint under it, the action's button while offered, and the command behind Show command. A `presenceList` row draws its label and hint, "None detected" while the list is empty, then one line per item: the item's label beside a `Badge` of its presence, its hint, Connect or Disconnect by its access, and its command behind Show command. Connect opens one masked `TextField` on the line, whose Save or Enter hands what was typed to `storeSecret` and closes it. A refused or failed step reads under its line until a later step there succeeds. An unreported row, and every row of a disabled plugin, reads "Not reported". No row edits a value: its only input is a Connect's field.

## Invariants

1. Every instance of a plugin reads one record: the service, a bar widget on each of two screens and a summoned panel read one revision and one set of values. Enforced by `scripts/smoke/rows/status.sh`.
2. Only a declared key with a value of its type, inside the ceiling, is published; the published values do not change in place. Enforced by `scripts/test-plugin-status.js`, each rule with a control, and by `scripts/smoke/rows/status.sh`, which reads each refusal by its text.
3. A disabled plugin holds no record, a new source revision drops it, and a retired instance's write cannot bring it back. Enforced by `scripts/smoke/rows/status.sh`, from the lending record.
4. The Status section draws no `data`, `choices` or hidden entry and no row edits a value; a command draws only behind Show command. Enforced by `scripts/test-plugin-status.js`, by `scripts/test-plugin-logic.js`, which refuses a `command` without an `action`, and by `scripts/smoke/rows/settings.sh`.
5. A `presenceList` item holds only its keys, a label and a presence, and its row carries each item's tone and its secret's access. Enforced by `scripts/test-plugin-status.js`, each rule with a control.

## Decisions

[D037](../decisions/D037-plugin-status.md), [D061](../decisions/D061-no-manual-commands.md), [D046](../decisions/D046-slack-tokens-per-workspace-and-one-card-per-message.md), [D032](../decisions/D032-settings-plugin-and-manifest-settings-convention.md), [D012](../decisions/D012-core-owns-lent-objects.md).
