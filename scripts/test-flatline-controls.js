#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const qmlSource = require("./lib/qml-source.js");

const repoRoot = path.join(__dirname, "..");
const buttonPath = path.join(repoRoot, "quickshell/vshell/Widgets/VgsButton.qml");
const dropdownPath = path.join(repoRoot, "quickshell/vshell/Widgets/VgsDropdown.qml");
const optionPath = path.join(repoRoot, "quickshell/vshell/Widgets/VgsDropdownOption.qml");
const logicPath = path.join(repoRoot, "quickshell/vshell/Widgets/VgsDropdownLogic.js");
const lockScreenPath = path.join(repoRoot, "quickshell/vshell/Modules/Settings/LockScreenTab.qml");

const buttonSource = fs.readFileSync(buttonPath, "utf8");
const dropdownSource = fs.readFileSync(dropdownPath, "utf8");
const optionSource = fs.readFileSync(optionPath, "utf8");
const lockScreenSource = fs.readFileSync(lockScreenPath, "utf8");
const logicSource = fs.readFileSync(logicPath, "utf8")
    .split("\n")
    .filter(line => !line.trim().startsWith(".pragma") && !line.trim().startsWith(".import"))
    .join("\n");
const DropdownLogic = vm.createContext({});
vm.runInContext(logicSource, DropdownLogic, { filename: logicPath });

// The adapter preserves source identity even when labels repeat. Icons remain
// positional, while colors keep the existing label-keyed compatibility API.
const duplicateRecords = Array.from(DropdownLogic.optionRecords(
    ["Same", "Other", "Same"],
    ["first", "middle", "last"],
    { Same: "red", Other: "blue" }
));
assert.deepEqual(duplicateRecords.map(record => ({
    id: record.id,
    sourceIndex: record.sourceIndex,
    value: record.value,
    label: record.label,
    icon: record.icon,
    color: record.color
})), [
    { id: 0, sourceIndex: 0, value: "Same", label: "Same", icon: "first", color: "red" },
    { id: 1, sourceIndex: 1, value: "Other", label: "Other", icon: "middle", color: "blue" },
    { id: 2, sourceIndex: 2, value: "Same", label: "Same", icon: "last", color: "red" }
], "duplicate labels must retain distinct source identities and positional icons");

const largeOptions = Array.from({ length: 10000 }, (_, index) => `Option ${index}`);
const largeRecords = DropdownLogic.optionRecords(largeOptions, [], {});
assert.equal(largeRecords.length, largeOptions.length, "the adapter must keep every large-list entry");
assert.equal(largeRecords[9999].sourceIndex, 9999, "a delegate reads source identity directly from its record");
assert.equal(largeRecords[9999].label, "Option 9999", "large-list labels remain searchable strings");
assert.deepEqual(Array.from(DropdownLogic.toggledValues(["Copy"], "Paste")), ["Copy", "Paste"]);
assert.deepEqual(Array.from(DropdownLogic.toggledValues(["Copy", "Paste"], "Copy")), ["Paste"]);

function buttonOwnsOnlyDeclaredGeometry(source) {
    const q = qmlSource(source, buttonPath);
    const code = qmlSource.stripComments(source);
    const mouseAt = q.indexOf("id: mouseArea");
    if (mouseAt < 0)
        return false;
    const mouseBlock = q.blockFrom(q.lastIndexOf("MouseArea {", mouseAt), "the button mouse area");
    return !code.includes("parent?.children")
        && !code.includes("followedBySecondaryLink")
        && !code.includes("reserveTrailingSpacing")
        && code.includes("implicitWidth: visualWidth")
        && code.includes("width: root.isSecondary ? root.visualWidth : root.width")
        && qmlSource.stripComments(mouseBlock).includes("anchors.fill: buttonSurface");
}

function dropdownUsesStableRecords(dropdown, option) {
    const dropdownCode = qmlSource.stripComments(dropdown);
    const optionCode = qmlSource.stripComments(option);
    return dropdownCode.includes("readonly property var optionRecords: DropdownLogic.optionRecords(options, optionIcons, optionColorMap)")
        && dropdownCode.includes("new Fzf.Finder(root.optionRecords")
        && dropdownCode.includes('"selector": option => option.label')
        && dropdownCode.includes("modelData.sourceIndex")
        && !dropdownCode.includes("DropdownLogic.sourceIndex")
        && optionCode.includes("text: root.modelData.label");
}

function lockVideoActionSharesUnderline(source) {
    const q = qmlSource(source, lockScreenPath);
    const fieldAt = q.indexOf("id: videoPathField");
    if (fieldAt < 0)
        return false;
    const itemAt = q.lastIndexOf("Item {", fieldAt);
    if (itemAt < 0)
        return false;
    const block = q.blockFrom(itemAt, "the video path field row");
    const code = qmlSource.stripComments(block);
    return code.includes("height: videoPathField.height")
        && code.includes("width: parent.width")
        && code.includes("rightAccessoryWidth: browseVideoButton.width + Theme.spacingM")
        && code.includes("id: browseVideoButton")
        && code.includes('variant: "secondary"')
        && code.indexOf("id: videoPathField") < code.indexOf("id: browseVideoButton");
}

assert.equal(buttonOwnsOnlyDeclaredGeometry(buttonSource), true,
    "VgsButton geometry must depend only on its properties, content, and allocated width");
assert.equal(dropdownUsesStableRecords(dropdownSource, optionSource), true,
    "dropdown filtering and delegates must carry stable source records instead of rescanning labels");
assert.equal(lockVideoActionSharesUnderline(lockScreenSource), true,
    "the lock-screen video Browse action must remain inside the field's shared underline row");

const controls = [
    ["sibling traversal returns to VgsButton", buttonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("    property bool enableScaleAnimation: false",
            "    readonly property var siblings: parent?.children\n    property bool enableScaleAnimation: false")],
    ["a filled button surface shrinks back to content width", buttonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("width: root.isSecondary ? root.visualWidth : root.width",
            "width: root.visualWidth")],
    ["the button hit area expands beyond its treatment", buttonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("id: mouseArea\n        anchors.fill: buttonSurface",
            "id: mouseArea\n        anchors.fill: root")],
    ["dropdown delegates reconstruct source indices", source => dropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("selected: dropdownMenu.selectedIndex === index",
            "selected: dropdownMenu.selectedIndex === index\n                            property int oldScan: DropdownLogic.sourceIndex(root.options, dropdownMenu.filteredOptions, modelData, index)")],
    ["fuzzy search drops normalized records", source => dropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("new Fzf.Finder(root.optionRecords", "new Fzf.Finder(root.options")],
    ["the option delegate renders the record object", source => dropdownUsesStableRecords(dropdownSource, source), optionSource,
        optionSource.replace("text: root.modelData.label", "text: root.modelData")],
    ["the video field stops reserving its inline action", lockVideoActionSharesUnderline, lockScreenSource,
        lockScreenSource.replace("rightAccessoryWidth: browseVideoButton.width + Theme.spacingM", "rightAccessoryWidth: 0")],
    ["the video Browse action leaves the shared row", lockVideoActionSharesUnderline, lockScreenSource,
        lockScreenSource.replace("id: browseVideoButton", "id: detachedBrowseButton")]
];

for (const [name, check, source, mutant] of controls) {
    assert.notEqual(mutant, source, `control did not apply: ${name}`);
    assert.equal(check(mutant), false, `must-fail control survived: ${name}`);
}

console.log(`flatline control checks passed (${controls.length} source mutants caught, 10000 dropdown records exercised)`);
