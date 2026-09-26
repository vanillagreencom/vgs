# D012: The core owns every session-wide object and lends it per instance with disposers

[← Decision Index](INDEX.md)

**Date**: 2026-09-23

**Status**: Active

**Research**: —

**Context**: Plugins need global shortcuts, IPC targets, notifications, the session lock and the polkit agent. Each of these is one per session: Hyprland binds a shortcut by `appid:name`, D-Bus has one `org.freedesktop.Notifications` owner, the compositor accepts one session lock, and polkit takes one agent per session. A plugin that created its own would collide with another plugin or with the user's daemon, and nothing would release it when the plugin is disabled.

**Decision**: The core creates each of these objects in `shell/Core/Capabilities.qml` and hands a plugin access through a capability. Providers are made per instance at build time. Every registration returns a disposer that the instance's build record runs when the instance is destroyed. The notification server and the polkit agent exist only while a plugin holds their capability. The lock and the polkit agent are separate capabilities, each lent to one plugin at a time, so a lock screen and a polkit dialog can be two plugins. `scripts/check-plugin-boundary.py` refuses a plugin that instantiates one of these types itself.

**Rationale**:

- One owner per object removes the collision class and gives disable a complete release.
- Creating the D-Bus roles on demand keeps a shell with no notification or polkit plugin out of the user's way.
- Splitting lock from polkit matches how the two surfaces are written; one `session` capability would force one plugin to own both.

**Revisit When**: Quickshell releases the notification D-Bus name when its server object is destroyed, or a plugin needs a lent object shared between two plugins at once.

**Verification**: The capability rows in `scripts/qml-smoke.sh` read each delivery and each release back; `scripts/test-plugin-logic.js` pins the exclusive-lending refusal; `scripts/test-check-plugin-boundary.py` plants the `core-type` violation.

**References**: [D003](D003-everything-is-a-plugin.md), [D010](D010-facade-scope-not-sandbox.md)
