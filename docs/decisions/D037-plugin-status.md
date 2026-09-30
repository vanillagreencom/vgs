# D037: Plugin status is a declared, published, per-plugin record every instance reads and Settings shows

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active (value types, Slack token row → [D046](D046-slack-tokens-per-workspace-and-one-card-per-message.md))

**Research**: [VGS-525](../plans/v2-platform-roadmap.md)

**Refines**: [D032](D032-settings-plugin-and-manifest-settings-convention.md)

**Refined by**: [D057](D057-setting-options-from-status.md): choices status feeds a string setting's editor. It remains runtime data, not configuration.

**Context**: A plugin's service owns live values: a pending-update count, whether a warden is checking, whether a credential is stored. The plugin's bar widgets, its flyout and its Settings page are separate instances, each built by the core with its own `shell` object, and nothing let one read what another holds. [D032](D032-settings-plugin-and-manifest-settings-convention.md) gave the Settings page editable schema fields only, and the notifications' Slack token, which [VGS-510](../../shell/plugins/vgs.notifications/README.md) keeps in libsecret, had no row saying whether it is stored or how to store it. Updates, Agent Warden and Dev Tools all need the same thing.

**Decision**: One core convention, the `status` key and capability.

- **Declared.** The manifest's `status` key declares each value as data: `{ "<key>": { "type", "label", "group"?, "hint"?, "command"?, "hidden"? } }`. `PluginLogic.validateManifest` judges it and `PluginLogic.STATUS_TYPES` lists the types; `status` needs capability `status` and the capability needs a declaration. `command` is one line the page shows with a Copy button and never runs.
- **Published.** `shell.status.set(key, value)` writes one declared key with a value of its type, answering `ok` or `refused: status=<key> reason=undeclared|type|size|retired`. `PluginLogic.statusWrite` judges it. `shell.status.values`, a deep-frozen copy for each read and bindable, and `shell.status.revision` reach every instance of the plugin.
- **Held.** `shell/Core/PluginStatus.qml` holds one record per plugin id, at most `PluginLogic.STATUS_MAX_BYTES` (64 KiB) of JSON, while the plugin is enabled at the source revision that wrote it. Disabling the plugin or a rescan that gives it a new revision drops the record, so the rebuilt service publishes again from nothing; a write through the provider of an instance the core is retiring is refused as `retired`, so it cannot bring a dropped record back. The lending record lists every record.
- **Shown.** Manager rows gain `status`, `PluginLogic.statusRows`: every entry but `data` and `hidden` ones, in manifest order, with its value and badge tone or `unreported`. `vgs.settings` draws a Status section above the settings form, one read-only `StatusRow` per entry, grouped as the schema's fields are, the command in a new `qs.Ui` `CodeLine` with a Copy button, and "Not reported" while the plugin is disabled or silent.
- **Convention.** The service writes; widgets, flyouts and Settings read; one writer per key. A credential's value never enters status, only its presence.

### The value types

| Type | Value | Settings draws |
|---|---|---|
| `presence` | one of `present`, `absent`, `locked`, `unavailable`, `unsafe` | a badge: `success`, `warning`, `info`, `neutral`, `danger` |
| `state` | `{ tone, text }`, `tone` one of `ok`, `info`, `warning`, `danger` | a badge with `text`: `success`, `info`, `warning`, `danger` |
| `text` | one printable line of at most 200 characters | the line |
| `count` | a whole number from 0 | the number |
| `time` | milliseconds since the Unix epoch | the local date and time |
| `data` | plain JSON | nothing; the plugin's own instances read it |

The `presence` set holds what a credential probe can answer without reading the credential: the store holds it and it is readable (`present`); the store does not hold it (`absent`); the store holds it in a locked collection, which a background probe must not unlock because that raises a prompt (`locked`); the store cannot be asked, its tool missing or its service unreachable (`unavailable`); it is stored where another user can read it (`unsafe`). The notifications' probe answers the first four. `unsafe` serves a credential kept in a file, such as a token a later plugin reads, whose mode the probe can see. Each value has one declared tone in `PluginLogic.STATUS_PRESENCE_TONES`: a stored, readable credential is a success; a missing one a warning, since the feature it serves is off; a locked one information, since unlocking the keyring at login makes it readable; an unanswerable probe neutral, since nothing is known; and an unsafe one a danger.

### Refinement of D032

The manifest is still the whole settings page. A page now shows read-only status rows declared in the manifest beside its editable schema fields. D032's revisit condition, a setting whose type the schema cannot hold, is not met: status is not a setting, is never written to `shell.json`, and no user edits it.

**Rationale**:

- The core already builds every instance and owns every lent object ([D012](D012-core-owns-lent-objects.md)); a record keyed by plugin id is one more lent object, released with the plugin, with nothing on disk and no watcher.
- Declaring the entries in the manifest keeps D032's rule that the manifest is the settings page: a third-party plugin gets its Status rows with no user-interface code, and a misspelt key fails the manifest.
- One writer per key and one record per plugin keep one owner per poller ([plugins.md § Budgets](../architecture/plugins.md#budgets)): the widgets on every screen and the flyout read the service's answer instead of running the probe themselves.
- Typed values let Settings draw every plugin the same way and let the judge refuse a value the page cannot draw; `data` carries what only the plugin's own instances understand.
- A presence type, not a value, is the only way a credential reaches status.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| A state file per plugin, which every instance watches | A disk write per change and a watcher per instance, against one owner per watcher; the file outlives the plugin, so a disabled plugin's stale values stay readable. |
| Each instance polls for itself | A widget on every screen and the flyout each run the same probe: N processes for one answer, and instances that disagree between polls. |
| Status as schema settings the service writes through `configure` | Runtime values in `shell.json`, a user-owned file, rewritten on every change and shown as editable fields; a credential's state would be a setting a user could "set". |
| Status in the manager's rows only, read by Settings | The plugin's own widgets, the first readers, could not reach it without the `manager` capability, which lends every plugin's rows. |
| A presence value set of `present`, `absent` and `unsafe` alone | A locked keyring and a missing `secret-tool` would read as `absent`, telling the user to store a token they already stored. |

## Omarchy comparison

Checked against basecamp/omarchy `main` at `e332dc9`: `shell/plugins/bar/widgets/SystemUpdate.qml`, `shell/plugins/bar/widgets/KeyboardLayout.qml`, `shell/plugins/panels/tailscale/Panel.qml` and `Service.qml`, `shell/services/PluginFirstPartyServiceApi.qml`, `shell/plugins/README.md`.

| Omarchy | VGS | Where VGS takes it, or why it differs |
|---|---|---|
| Each bar widget owns its `Process` and `Timer`: `SystemUpdate.qml` runs `omarchy-update-available` every six hours, once per widget instance. | The plugin's service owns the one probe and publishes the answer; every instance reads it. | VGS keeps one owner per poller ([plugins.md § Budgets](../architecture/plugins.md#budgets)): a bar on every screen would run Omarchy's check once per screen. |
| A panel instantiates its own `Service` (the Tailscale panel declares `Service {}` inside itself). | A panel reads the service's published record. | A second copy of a service is a second owner of its processes; the record lets the panel read without one. |
| First-party services reach the bar through a hand-written proxy per service (`PluginFirstPartyServiceApi.qml`), with fixed properties for idle, nightlight, notifications and media. | One typed, declared record per plugin, the same for a third-party plugin. | Taken: a narrow, read-only surface. VGS makes it data declared in the manifest instead of a proxy per service, so no core change is needed per plugin. |
| The settings show no plugin status. | The Settings page draws each declared entry read-only. | VGS adds it: the owner asked to see whether a credential is stored and how to store it. |
| No `secret-tool`, libsecret or keyring use in `main`. | The Slack token stays in libsecret, where the notifications' photo helper reads it, and status shows only whether it is stored. | libsecret keeps the token out of `shell.json`, argv, the repository and logs, and a probe can ask whether it is stored without reading it. |

**Revisit When**: A plugin needs to publish a value another plugin reads, a status value must survive a shell restart, or a plugin needs more than 64 KiB of published values.

**Verification**: `scripts/test-plugin-logic.js` pins each `status` manifest refusal; `scripts/test-plugin-status.js` pins `statusWrite`, the size ceiling, the frozen copy, `statusRows` and the tone tables, each rule with a control; `scripts/test-check-manifests.js` pins the manifest rule offline. `scripts/smoke/rows/status.sh` reads one revision and one set of values back from the fixture's service, a bar widget on each of two screens and a summoned panel, the refusals by text, the record dropped on disable and on a new revision, and a retired provider's write refused. `scripts/smoke/rows/settings.sh` reads the Status rows of `acme.status` and `vgs.notifications` back, labels, values, tones and commands, and that no row takes an edit. `scripts/test-notifications-token-status.sh` proves the Slack token probe never reads or prints the token, with a control that prints it; `scripts/smoke/rows/notifications.sh` flips the stub store absent, present and locked and reads the row each time. `scripts/qml-tests/tst_codeline.qml` holds `CodeLine`.

**References**: [D012](D012-core-owns-lent-objects.md), [D014](D014-source-revisions-are-published-snapshots.md), [D032](D032-settings-plugin-and-manifest-settings-convention.md), [status.md](../architecture/status.md), [docs/plans/v2-platform-roadmap.md § 5](../plans/v2-platform-roadmap.md)
