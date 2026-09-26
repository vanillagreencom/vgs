# Review a plugin

Run the checks first, then read. A finding names the rule and the line.

1. `.agents/skills/vgs-plugin/scripts/vgs-plugin check <dir>`: manifest and boundary. Every printed line is a blocker.
2. Open every entry point and confirm: `property var shell: null` exists, no entry point assigns `moduleName`, `bar` or `settings` (the core does), every timer, `Process`, `FileView` and connection sits inside the entry point's tree, no capability is read from `bar`, and no copy of `shell.settings` is held past the assignment.
3. Confirm every colour and size reads `Color` or `Style`.
4. Confirm any compositor call goes through `shell.<capability>` and the capability is in the manifest.
5. For a bar, confirm it declares the three section containers and creates no widget itself.
6. Confirm the smoke rows exist as [`new-plugin.md`](new-plugin.md) step 8 lists them for the plugin's kinds, that a planted defect turned one red, and that `scripts/validate qml` passed on the machine that produced the PR.
