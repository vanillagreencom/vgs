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
- [D033](../decisions/D033-floating-tuis-are-core.md): floating TUIs are a core concept; a command reaches the terminal as an argv list, never a shell string.
- [D043](../decisions/D043-tui-run-ends-by-lock-release.md): a TUI run ends by the presenter's key lock release, not only by FolderListModel change delivery.
- [D045](../decisions/D045-tui-wait-holds-a-per-run-lock.md): a TUI wait blocks on its run's own lock, so a later run of the key cannot delay it; a run whose records a later run removed ends `gone`, which the shell logs only for a run it still awaits. Refines D043.
- [D044](../decisions/D044-application-windows-are-hyprland-toplevels.md): an application window is kind `window`, a Hyprland toplevel of class `org.vgs.shell` titled with its plugin's name, which an unaccepted Escape closes; Settings, Dev Tools and the Gallery are ones. Every other surface is a transient overlay, and a flyout closes on an outside click. Refines D032.
- [D047](../decisions/D047-services-build-after-the-first-bar-frame.md): services build once every bar of the first scan has presented a frame, at once with no bar, and at a 358 ms deadline for a bar that never presents; so at start a surface plugin wins an exclusive capability a service also names.
- [D036](../decisions/D036-time-boxed-passwordless-sudo-grant.md): a passwordless sudo grant is an opt-in core TUI, `vgsh sudo grant`: a `NOTAFTER` rule checked by `visudo`, removed at its deadline and at boot, written by a root half the owner installs once; on NixOS it writes nothing and prints the `security.sudo.extraRules` rule.
- [D035](../decisions/D035-manifest-requirements.md): a manifest declares the external commands a plugin runs and their packages; the scan probes them and the manager reports each one's state; a requirement never names a plugin; a core notice installs a missing one on the user's press, and the `doctor` capability raises it for the core's or an enabled plugin's commands.
- [D037](../decisions/D037-plugin-status.md): a plugin publishes manifest-declared runtime values through capability `status`; the core holds one record per plugin, read by every instance and drawn read-only by Settings. Refines D032.
- [D038](../decisions/D038-judged-theme-catalog.md): first-party themes are a judged catalog in `themes/catalog/`, installed as ordinary packages; it carries no curated file on a target whose files run code.
- [D039](../decisions/D039-per-screen-wallpaper-map.md): wallpaper is per screen through an additive `screens` map in `backgrounds.json`; a theme apply clears it.
- [D040](../decisions/D040-one-shared-install-tree.md): every channel calls one installer for one `/usr/share/vgs` tree, with local publishing scripts and MIT licensing; `vgsh self` knows the checkout, package, curl and Nix methods and updates only a checkout and a curl install; Fedora ships through COPR `vanillagreen/vgs` over two third-party COPRs.
- [D041](../decisions/D041-agent-warden-observes-the-vsys-warden.md): the agent warden stays a systemd user timer vsys ships; `vgs.agent-warden` reads its `status.json`, publishes the derived state as plugin status, and never enforces.
- [D046](../decisions/D046-slack-tokens-per-workspace-and-one-card-per-message.md): `vgs.notifications` reads one Slack token per workspace, `slack:<team id>`, beside the single-workspace one; the core's status gains `presenceList`; a rule may match its service's web origin, and the desktop and browser copies of one message show one card, the desktop's. Refines D037.
- [D048](../decisions/D048-theme-owned-hyprland-appearance.md): themes own bounded Hyprland border, radius and motion appearance groups through manifest-declared switches. Refines D015 and D028.
- [D049](../decisions/D049-slack-custom-emoji-from-the-cache-drawn-inline.md): the photo helper builds each Slack team's custom emoji from Slack's disk cache, with `emoji.list` beside it, into normalized images swapped in by rename; a card reads them from memory and draws its body through `qs.Ui`'s `ImageText`, which elides at whole words and images and loads every image off the GUI thread. Refines D046.
