# Decisions

Covers: docs/decisions/

One line per decision record that shapes the architecture; the full log with dates, rationale and status is [INDEX.md](../decisions/INDEX.md).

- [D001](../decisions/D001-hyprland-only.md): Hyprland only.
- [D002](../decisions/D002-quickshell-0-3-1-baseline.md): Quickshell 0.3.1 is the baseline.
- [D003](../decisions/D003-everything-is-a-plugin.md): everything outside the core is a plugin; the manager is core; the core names no plugin.
- [D005](../decisions/D005-kinds-are-surfaces-no-dependencies.md): kinds are surfaces; plugins declare no dependencies.
- [D006](../decisions/D006-two-configuration-layers.md): two configuration layers merged by entry id.
- [D007](../decisions/D007-install-runs-no-plugin-code.md): install runs no plugin code and lands the plugin disabled.
- [D008](../decisions/D008-validation-row-per-change.md): every change carries its validation row; the nested sandbox is the only shell start.
- [D009](../decisions/D009-one-manifest-judge-under-node.md): one manifest judge shared by shell and scripts.
- [D010](../decisions/D010-facade-scope-not-sandbox.md): a static check plus a scoped API object, not a process sandbox.
- [D011](../decisions/D011-native-manifest-no-cross-shell-compatibility.md): the manifest and the plugin API are v2's own; no other shell's plugins are supported.
- [D012](../decisions/D012-core-owns-lent-objects.md): the core owns every session-wide object and lends it per instance with disposers.
- [D013](../decisions/D013-built-in-widgets-are-the-bar-plugins.md): a built-in widget is part of the plugin that draws it, registered with origin `plugin`, never a kind.
- [D014](../decisions/D014-source-revisions-are-published-snapshots.md): a plugin's source revision is a published snapshot; a rescan rebuilds only the plugins whose files changed.
- [D015](../decisions/D015-tokens-are-a-judged-table.md): tokens are one JavaScript table judged by pure functions and published as frozen objects.
- [D016](../decisions/D016-bundled-variable-font.md): two bundled variable fonts, sans and mono; a theme names families and ships no font file.
- [D017](../decisions/D017-templates-and-path-icons.md): controls extend `QtQuick.Templates`; icons are Lucide path data drawn with `QtQuick.Shapes`.
- [D019](../decisions/D019-theme-packages-carry-plugin-trust.md): theme packages are directories with plugin trust; terminal slots are package files.
- [D021](../decisions/D021-theme-apply-writes-beside-each-destination.md): a theme apply stages every write beside its destination and writes the shell document last.
- [D023](../decisions/D023-plugin-owned-appearance.md): a plugin may own its look, taking the theme's mode, accent and motion scale alone.
- [D026](../decisions/D026-passive-layers-are-a-capability.md): a passive layer is a capability that draws a plugin's component on every screen, not a kind.
- [D028](../decisions/D028-one-generated-hyprland-layer.md): the shell writes one Hyprland Lua layer from the theme and plugin manifest data, loaded by one line in `hyprland.lua`.
- [D030](../decisions/D030-managed-copies-for-watched-theme-directories.md): managed copies serve watched theme directories.
- [D031](../decisions/D031-installed-themes-render-code-targets.md): an installed theme's curated file is dropped on a target whose files run code.
- [D035](../decisions/D035-manifest-requirements.md): a manifest declares the external commands a plugin runs and their packages; the scan probes them and the manager reports each one's state; a requirement never names a plugin.
- [D039](../decisions/D039-per-screen-wallpaper-map.md): wallpaper is per screen through an additive `screens` map in `backgrounds.json`; a theme apply clears it.
