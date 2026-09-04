# Shipped configuration

Read [../../docs/architecture/plugins.md](../../docs/architecture/plugins.md) before changing plugin loading or dependency declarations.

- Keep bundled plugin imports within `qs.Common`, `qs.Widgets`, `qs.Services` and `qs.Modules.Plugins`; feature directories are private.
- Private commands belong behind a user setting, not a shipped dependency probe.
