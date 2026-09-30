# D075: Consumer features need no developer setup; a feature that does is an owner-only extra

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: [VGS-683](https://linear.app/vanillagreen/issue/VGS-683)

**Refines**: [D032](D032-settings-plugin-and-manifest-settings-convention.md), [D035](D035-manifest-requirements.md), [D037](D037-plugin-status.md), [D061](D061-no-manual-commands.md)

**Context**: Slack sender photos need a Slack user token per workspace. To get one, a user must create a Slack app at api.slack.com, add scopes and install it to each workspace. The Settings page showed a Slack tokens row with Connect buttons, and the requirements listed `secret-tool` and `curl` for it, to every user. [D061](D061-no-manual-commands.md) made storing the token one click, but it did not remove the developer setup before that click. Slack has no token-free source for user photos ([D046](D046-slack-tokens-per-workspace-and-one-card-per-message.md)). A published Slack app with OAuth needs a client secret on a server, and VGS has no server. The owner's ruling: a feature most users cannot use without that setup does not ship as a consumer feature. It can stay as an owner-only extra.

**Decision**: One standing rule, and a manifest key that makes it hold.

- **The rule.** A consumer feature works with no developer setup: no app to register, no API key or token to create, no developer console. A feature that needs such setup is an extra. It is off by default, the Settings page never shows it or anything it needs, and it is documented only under "Extras (not supported)" in its plugin's README.
- **The `extras` key.** A manifest's `extras` maps each extra to its switch, a setting whose default is `false` and which has no `schema` entry, so the Settings page draws no field for it. Each extra lists the status entries and the optional requirement commands that serve only it. `PluginLogic.extrasError` judges the key.
- **One view of the manifest.** `PluginLogic.activeManifest` is the manifest as the plugin's settings apply it: an extra that is off loses its status entries and its requirement commands. The Settings page's status and requirement rows, the manager's action and secret steps, the requirement notice and `vgsh plugin requirements`, `vgsh doctor` and the offer after `vgsh plugin add` all read this view. So with the extra off, no row, button, Connect field or requirement line of it appears, and the core refuses a secret write for its accounts. A status write still judges the whole manifest.
- **The plugin runs nothing of an extra that is off.** The switch reaches the plugin as an ordinary setting. The owner turns the extra on in `~/.config/vgs/shell.json`.
- **Existing users keep their photos.** A one-time migration ([D076](D076-one-time-migrations.md)) sets `"slackPhotos": true` for a user whose photo cache or keyring shows a Slack token, unless their row already names the extra.

**Rationale**:

- An extra keeps a working feature for the owner without asking every other user to set up a developer account. The consumer path stays the same for everyone.
- The switch is an ordinary setting, so it reaches the plugin, the configuration judge and `vgsh plugin settings` with no new path. Leaving out the `schema` entry already keeps it off the Settings page.
- One filtered view, computed in one place, serves every reader that shows or acts on a status entry or a requirement. A second filter in each reader would be a second copy of one decision.
- Listing an extra's requirements in the manifest keeps [D035](D035-manifest-requirements.md): every command a plugin runs is declared. The view only hides the commands of an extra that is off.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Delete Slack photos | The owner uses them daily, and the code works. An extra keeps them at no cost to other users. |
| A published Slack app with OAuth for one-click Connect | OAuth needs the client secret on a server. VGS has no backend, and shipping the secret in the package makes it public. |
| A `hidden` setting with no `extras` key, and each reader filtering status and requirements by name | Each reader would need its own list of what belongs to the extra. The manifest is where a plugin declares what it uses. |
| A generic `when` field on each status entry and requirement | It spreads one extra over several places in the manifest, and a reader cannot see which entries belong to one feature. One `extras` entry names everything an extra owns. |
| An "Extras" group on the Settings page | Every user would see a switch for a feature they cannot set up. The owner's ruling keeps it off the consumer page. |

## Omarchy comparison

Omarchy (basecamp/omarchy `quattro`, `shell/plugins/notifications/`, read at 8b4eae6) ships no token-based sender photos and no plugin settings schema: its notifications draw what the notification carries. Omarchy's answer to a feature that needs developer setup is to not ship it. VGS takes the same consumer surface and keeps the owner's working feature behind a switch that no consumer sees, because deleting it would lose a feature the owner uses.

**Revisit When**: Slack offers a token-free source for user photos, VGS gets a backend that can hold an OAuth client secret, or an extra gains enough users to become a consumer feature with a one-click setup.

**Verification**: `scripts/test-plugin-extras.js` pins every `extras` rule and the filtered view, each with a control; `scripts/test-vgsh-requirements.sh` reads the requirement reports with the extra off and on, each with a control; `scripts/test-notifications-logic.js`, `scripts/test-notifications-slack-photos.js` and `scripts/test-notifications-slack-emoji.js` pin that the Slack helper reads no token and calls no Slack API with the extra off, each with a control; in the nested sandbox `scripts/smoke/rows/notifications.sh` reads no keyring or Slack call, no token row and none of the extra's commands with the extra off, and the same readers find them with the extra on as its control.

**References**: [D032](D032-settings-plugin-and-manifest-settings-convention.md), [D035](D035-manifest-requirements.md), [D037](D037-plugin-status.md), [D046](D046-slack-tokens-per-workspace-and-one-card-per-message.md), [D061](D061-no-manual-commands.md), [plugin-manifest.md](../architecture/plugin-manifest.md), [status.md](../architecture/status.md).
