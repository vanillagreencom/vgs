# D057: String settings take runtime options from their plugin's status

[← Decision Index](INDEX.md)

**Date**: 2026-09-30
**Status**: Active
**Research**: [VGS-616](../plans/v2-jarvis-plan.md#310-settings-status-and-files)
**Refines**: [D032](D032-settings-plugin-and-manifest-settings-convention.md), [D037](D037-plugin-status.md)

**Context**: A manifest cannot list the devices, accounts and models a service discovers at runtime. The Settings page still comes from manifest data alone. Removing an offered option must not remove the user's configured value.

**Decision**: A string schema entry may name a `choices` status entry through `optionsFrom`. The status belongs to the same plugin. Its service publishes labeled, stable string ids through the existing status capability. `PluginLogic.js` judges the manifest and each publication, and builds the manager's `settingChoices` models. [status.md § Setting choices](../architecture/status.md#setting-choices) fixes the value shape and editor semantics.

**Rationale**:
- Runtime discovery has one owner, the service. Opening an editor starts no process.
- A choice label may change without changing the stored id.
- A removed id stays configured and visible as unavailable. Publication changes no setting.
- Empty string follows the first offer without writing that offer into the configuration. With no offers, it resolves to no choice.
- `Select.activated` distinguishes a user choice from a model or binding update. A refresh cannot save a different value by accident.

## Omarchy comparison

Read basecamp/omarchy's default branch `quattro` at `8b4eae66da2938ba9559f103b18dbf85cdf28a70`. GitHub's repository metadata and branch endpoint reported that branch and commit on 2026-09-30. The reference files are [Dropdown.qml](https://github.com/basecamp/omarchy/blob/8b4eae66da2938ba9559f103b18dbf85cdf28a70/shell/Ui/Dropdown.qml), [MultiSelect.qml](https://github.com/basecamp/omarchy/blob/8b4eae66da2938ba9559f103b18dbf85cdf28a70/shell/Ui/MultiSelect.qml) and [BarWidgetRegistry.qml](https://github.com/basecamp/omarchy/blob/8b4eae66da2938ba9559f103b18dbf85cdf28a70/shell/services/BarWidgetRegistry.qml).

- `Dropdown` draws `{ value, label }` options, emits the value on selection and displays the raw configured value when no option matches. VGS takes the separate label and value and adds an unavailable label.
- `MultiSelect` runs `optionsCommand` when its popup opens or refreshes. Its selection labels fall back to persisted ids when an offer disappears. VGS keeps persisted ids too, but uses D037's existing per-plugin status instead of one command per editor.
- `BarWidgetRegistry` replaces its widget map and publishes a revision. VGS already replaces the status record map whole. `Registry.managerRows` reads that map through `PluginStatus.valuesOf`, so a status write updates the editor without a new watcher.

## Alternatives considered

| Alternative | Reason |
|---|---|
| A discovery command per editor | Repeats discovery already owned by the plugin's service. |
| Runtime enum options | An enum refuses a configured value after it leaves the options. |
| Store the first offer instead of empty string | A new first offer would stop following the user's automatic choice. |
| Plugin-supplied editor code | Breaks D032's manifest-only page and adds another editor style. |

**Revisit When**: A setting needs several selected values, or discovery needs more than the existing bounded status list permits.

**Verification**: `scripts/test-plugin-logic.js` pins the schema reference rules. `scripts/test-plugin-status.js` pins the choices shape, bounds, immutability and retained ids, with controls per rule. `scripts/qml-tests/tst_overlays.qml` and `scripts/test-qml-unit.sh` pin user-only activation. `scripts/smoke/rows/status.sh` reads choices from every fixture instance. `scripts/smoke/rows/settings.sh` reads the drawn Select, the saved id, refreshes without writes, empty offers, disabled state and editor controls.
