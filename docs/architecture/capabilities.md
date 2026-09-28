# Capabilities

Covers: shell/Core/Capabilities.qml, shell/Core/ShortcutRegistry.qml, shell/Core/IpcRegistry.qml, shell/Core/NotificationHub.qml, shell/Core/SessionLock.qml, shell/Core/Lifetime.js

How the core lends a plugin the APIs its manifest names, holds them for one instance and releases them. The manifest and the kinds are [plugins.md](plugins.md).

A capability is a core API named in the manifest's `capabilities` and delivered as `shell.<name>`. `PluginLogic.js` owns the name list and `Capabilities.qml` holds one provider per name; an unknown name refuses the manifest, and a name without a provider is logged at start. An instance's `shell` holds exactly `manifest`, `settings` and the capabilities it named; the smoke reads the key list back from a fixture naming most capabilities and from one naming none.

- The core makes each provider for one instance when it builds the instance. A settings change hands over a new `shell` holding the same providers.
- Every registration a provider makes returns a disposer, and the instance's build record owns it through one lifetime, `shell/Core/Lifetime.js`. Calling a disposer early releases its registration at once and drops it from the record, so a plugin that registers and releases repeatedly (a bar changing its built-in widgets) holds nothing for what it released. Destroying the instance drains what is still pending, newest first, and goes on after one that throws, so disabling a plugin releases every shortcut, IPC target, subscriber and hold it made. `scripts/test-lifetime.js` pins the helper; the smoke asserts each release after disabling its fixture, from the core's lending record and from the compositor or bus the capability reaches, and reads the pending count of a bar back through its built-in cycles.
- `lock` and `polkit` are exclusive: while one plugin holds one, another plugin naming it is not built, and it builds once the holder lets go. `PluginLogic.lendRefusal` decides it. `Registry.buildRefusal`, which `slotKey` reads, follows a copy of the holders taken after each change settles; `reconcileBar` reads the live record. `scripts/test-plugin-logic.js` and the smoke pin it.
- A build that fails after its capabilities were made (an entry point without `shell`, a background without `screen`, a widget without the `BarWidget` properties) drains the same lifetime, leaves no build record and is reported to the host as a failed build.
- Every instance is destroyed under the host key it was built under, so a host whose key changes while its screen goes away still releases everything.
- The notification server and the polkit agent exist only while a plugin holds their capability, so a shell with no such plugin claims neither role. The smoke asserts both objects are gone once the holder is disabled. Whether the process keeps the notification D-Bus name after the server is destroyed is Quickshell's, and [D012](../decisions/D012-core-owns-lent-objects.md) names it as the revisit condition.
- `toasts` and `theme` have contracts of their own: [design-system.md § Toasts](design-system.md#toasts) and [theme-capability.md](theme-capability.md).

Each capability's members are listed in [`.agents/skills/vgs-plugin/references/api.md` § The shell object](../../.agents/skills/vgs-plugin/references/api.md#the-shell-object). Three carry rules of their own: `compositor` offers one function per dispatcher in `Dispatch.PLUGIN_DISPATCHERS`, and `shell/Core/Dispatch.js` refuses an argument that could break out of the session's syntax; `configure` writes only a key the manifest's `schema` declares, with a value of its type, to the configuration entry `PluginLogic.settingTargetOf` names for the calling instance's kind; `lock` keeps a locked session locked when its holder is unloaded.

A capability lands with its name, its provider and a fixture consumer with its smoke rows in the same change.

`Capabilities` maps providers and accounts for holds. Each resource owner keeps its state, registration and release together; a stateless provider needs no separate component.
