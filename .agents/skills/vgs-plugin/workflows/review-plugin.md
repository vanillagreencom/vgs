# Review a plugin

Run the checks first, then read. A finding names the rule and the line.

1. `.agents/skills/vgs-plugin/scripts/vgs-plugin check <dir>`: manifest and boundary. Every printed line is a blocker.
2. Open every entry point and confirm: the imports are on the allowed list, no window type is named, `moduleName` equals the manifest id, every timer, `Process`, `FileView` and connection sits inside the entry point's tree.
3. Confirm every colour and size reads `Color` or `Style`.
4. Confirm any compositor call goes through `shell.<capability>` and the capability is in the manifest.
5. Confirm the smoke row exists and names the plugin, and that `scripts/validate qml` passed on the machine that produced the PR.
6. Confirm every figure in the diff was printed by a script named beside it.
