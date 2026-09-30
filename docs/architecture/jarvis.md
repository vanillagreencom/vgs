# Jarvis

Covers: shell/Core/SessionLock.qml, scripts/smoke/fixtures/plugins/acme.session/, scripts/smoke/rows/session.sh, docs/plans/v2-jarvis-plan.md, shell/Hosts/LayerHost.qml

The [Jarvis plan](../plans/v2-jarvis-plan.md) defines the voice assistant's scope. This document records its implemented core boundary. No Jarvis service or daemon ships yet.

## Session observation

A privacy-sensitive service declares capability `session` and binds to `shell.session.locked`. The [capability contract](capabilities.md) defines that state and its tests. It grants no lock authority and introduces no dependency on a lock plugin: [D056](../decisions/D056-read-only-session-state.md).

The service must treat a missing lock state as unknown, not unlocked. The future daemon's initial lock-state message and its capture shutdown belong to the plan's process model. The core capability does not enforce capture or action policy.

## Setting options

The starred strings in [the plan's settings section](../plans/v2-jarvis-plan.md#310-settings-status-and-files) use `optionsFrom`: voice, language, microphone, speaker, brain, model and coding agent. The service that owns discovery publishes each offer list through its plugin's declared `choices` status. A label names the choice to the user; its stable id is the setting.

[status.md § Setting choices](status.md#setting-choices) defines the generic shape, bounds, empty-string first-offered convention and retained unavailable ids. [D057](../decisions/D057-setting-options-from-status.md) records the core choice and its Omarchy comparison. The future Jarvis consumer resolves empty string from its own first offer and treats no offers as no selection. Discovery failure must not silently change the configured provider or device.

The generic fixture `acme.status`, not a Jarvis skeleton, proves the Settings Select in `scripts/smoke/rows/settings.sh`. It uses synthetic offers and writes only the sandbox's configuration. No microphone, speaker, provider account or network is needed.

## Passive input

The core supports the [passive layer input contract](layers.md), refined by [D058](../decisions/D058-layer-input-union.md). The bubble's layout and capture indicator remain plugin work in the [plan's Bubble and orb section](../plans/v2-jarvis-plan.md#43-bubble-and-orb).
