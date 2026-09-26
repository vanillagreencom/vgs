# D011: The manifest and the plugin API are v2's own; no other shell's plugins are supported

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: [D004](D004-manifest-schema-borrowed-from-another-shell.md) borrowed another shell's manifest schema so that a plugin written for either shell would validate in both. A review of the implementation showed the shared names had already drifted in meaning (the spacing function scaled differently, the font tokens were named differently), that widget-centric fields were the wrong home for the settings of a service or a panel, and that no plugin from the other shell had ever been loaded. The owner decided the other shell is inspiration only: nothing in this repository names it or promises to run its plugins.

**Decision**: `manifest.json` is v2's own schema, judged once by `shell/Core/PluginLogic.js`: `entryPoints` keyed by kind name, `capabilities` and `settings` at the top level for every kind, `defaultSection` for a bar widget, and every unknown key refused. `qs.Commons`, `qs.Ui` and the `shell` object carry v2's own names with v2's own semantics. A user who wants a plugin from another shell asks the vgs-plugin skill to write a v2 plugin from it; no translation layer, compatibility fixture or shared namespace exists.

**Rationale**:

- One schema with one judge has no second format to drift from and no reserved namespace to work around.
- Kind-independent `settings` gives a service, a panel and a widget the same settings path and the same reconciliation.
- A compatibility promise that nothing tests is a claim, not a contract; removing it removes the class of finding.

**Revisit When**: A plugin marketplace with a stable, versioned schema exists that v2 would gain more from joining than from owning its own.

**Verification**: `scripts/test-plugin-logic.js` pins the unknown-key refusal and every field rule; `scripts/check-manifests.js` validates every bundled manifest.

**References**: [D004](D004-manifest-schema-borrowed-from-another-shell.md), [D009](D009-one-manifest-judge-under-node.md)
