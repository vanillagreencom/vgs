# D058: No manual commands: a setup step is automatic or one click, and a command only a "Show command" disclosure

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: [VGS-613](https://linear.app/vanillagreen/issue/VGS-613)

**Refines**: [D037](D037-plugin-status.md)

**Context**: Installing VGS or a plugin told the user to run commands by hand: `secret-tool store … account slack:<team>` for Slack photos, `loginctl enable-linger` for automations while logged out, `vsys warden install` and a `curl … | bash` for Agent Warden, `vgsh theme browser-policy install` for Chromium theming, `vgsh pkg run install mise`, and `vgsh plugin enable <id>` for bar widgets. Each sat in a README, a Settings status row's `command` or a hint. The owner's direction: a user installing a plugin should run no command; at worst they press a button that runs it for them. Pasting a token into a shell command also puts it in the shell's history.

**Decision**: One standing rule, and the mechanism that makes it hold.

- **The rule.** A user-facing setup step is automatic, or one click in the user interface: a Settings row, a notice or a dialog button. A step that needs a privilege or asks a question in a terminal runs in a core floating TUI ([D033](D033-floating-tuis-are-core.md)) or through the requirement notice ([D035](D035-manifest-requirements.md)), which that button starts. A secret is typed into a masked field and VGS stores it in libsecret; it never goes into a command the user runs. A copyable command appears only as a secondary "Show command" disclosure beside the button that runs its step.
- **Status actions.** A `presence` or `state` status entry may declare `action: { label, tui | install }`: `tui` names one of the plugin's own `tui` scripts, `install` a list of its own requirement commands. The plugin, the one writer of the value, says when it applies: a `presence` while `absent`, a `state` while its value carries `action: true`. The Settings page draws the action as a button, and the `manager` capability's `act(id, key)` runs it: the core opens the plugin's own TUI, as the plugin's `shell.tui.run` would, or raises the requirement notice for those commands. A status `command` needs an `action`, and a `presenceList` item's `command` needs its `secret`, so no command stands alone; the page shows it behind Show command, in `qs.Ui`'s `CommandDisclosure`.
- **Secrets.** A manifest's `secrets: { service, label }`, with capability `secrets`, declares the libsecret items VGS stores for the plugin. A `presenceList` item names its account as `secret`. The Settings page offers Connect while the item is `absent`, which opens a masked `TextField`, and Disconnect while something is stored. The `manager` capability's `storeSecret` and `clearSecret` hand the request to the core's one writer, `SecretWriter`, which runs `secret-tool store` with the account on its argv and the secret on stdin, then closes stdin, or `secret-tool clear`. `PluginLogic.secretRequest` writes only an account the plugin itself lists, and only the verb its presence offers. The plugin reads `shell.secrets.revision`, which each ended write raises, and probes its store again.
- **Enforcement.** `scripts/check-user-commands.py` fails where a plugin's Markdown, its manifest's user-facing strings or a drawn string of shipped QML or JavaScript tells the user to run a command, outside a `<details>` block whose summary is Show command. `PluginLogic.statusError` refuses a status `command` without an `action`.

**Rationale**:

- The core already owns every route a setup step needs: floating TUIs for questions and passwords, the requirement notice for packages, and status rows on the Settings page. The action names one of them as data, so a plugin adds a button with no interface code, and the core never runs a command string from a manifest.
- The plugin decides when its step applies, because it owns the value that says so: a warden not set up, lingering off, a token absent. The core decides only whether the button's request is one the value offers, and refuses the rest, so the button cannot run a step the page did not show.
- A secret typed into the shell never touches an argv, a log line or a status value. One core writer serves every plugin that declares a credential; a plugin reimplementing its own `secret-tool` call is a second copy of the same verb.
- Keeping the command behind Show command serves the user who wants it, such as someone scripting a setup or on a system with no package for the step, without making it the path.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| A generic `run` action whose argv the manifest declares | The shell would run plugin-supplied commands outside a terminal, with no place to show a question, a password prompt or an error. A TUI script already carries the argv, and the terminal shows its output. |
| Buttons in each plugin's own panel only | Each plugin would build its own button, and a plugin without a panel, such as Automations, would have none. The Settings page draws every plugin the same way from the manifest. |
| A floating TUI with a masked `gum input --password` for the Slack token | This is a terminal the user did not need, for a step with no question. A masked field on the page is the step itself. |
| The token handed to the plugin's own IPC handler, which stores it | Every plugin with a credential would write its own `secret-tool` call. An IPC function that takes a secret can also be called from a shell, which puts the secret on an argv. |
| A tone rule: offer the action while the row's tone is not success | The tones mean different things across plugins: a warden that stopped checking is a warning that Set up does not fix. The writer knows which states its step fixes. |

## Omarchy comparison

Omarchy (basecamp/omarchy `quattro`, `shell/plugins/panels/network/Panel.qml`) enters a Wi-Fi passphrase in a row-embedded masked `TextField` (`password: true`) and hands it to `nmcli` over stdin, "never argv". VGS takes the same field and the same stdin rule for libsecret. Omarchy's menu runs setup steps as `omarchy-*` commands from menu entries in a floating terminal; VGS keeps that terminal for steps that ask, and names the step as manifest data rather than an action string.

**Revisit When**: A setup step needs input the masked field and a TUI cannot take, such as a file picker or an OAuth browser round trip; or a second secret store beside libsecret is needed.

**Verification**: `scripts/test-plugin-status.js` and `scripts/test-plugin-logic.js` pin every action and secret rule with a control; `scripts/check-user-commands.py` and `scripts/test-check-user-commands.py` hold the text rule with a control per rule; `scripts/smoke/rows/settings.sh` presses the fixture's actions, and the Automations, Agent Warden, Dev Tools, Notifications and Themes rows press each plugin's step in the nested sandbox, each with a refusal as its control.

**References**: [D033](D033-floating-tuis-are-core.md), [D035](D035-manifest-requirements.md), [D037](D037-plugin-status.md), [D046](D046-slack-tokens-per-workspace-and-one-card-per-message.md), [D029](D029-chromium-policy-writer.md), [status.md](../architecture/status.md), [settings-window.md](../architecture/settings-window.md).
