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
const fzfPath = path.join(repoRoot, "quickshell/vshell/Common/fzf.js");
const lockScreenPath = path.join(repoRoot, "quickshell/vshell/Modules/Settings/LockScreenTab.qml");

const read = file => fs.readFileSync(file, "utf8");
const buttonSource = read(buttonPath);
const dropdownSource = read(dropdownPath);
const optionSource = read(optionPath);
const lockScreenSource = read(lockScreenPath);

function qmlLibrary(file, expose = "") {
    const source = read(file).split("\n")
        .filter(line => !line.trim().startsWith(".pragma") && !line.trim().startsWith(".import"))
        .join("\n");
    const context = vm.createContext({});
    vm.runInContext(`${source}\n${expose}`, context, { filename: file });
    return context;
}

const DropdownLogic = qmlLibrary(logicPath);
const Fzf = qmlLibrary(fzfPath, "this.Finder = Finder;");

function hasCode(block, token, label) {
    try {
        qmlSource(block, label).requires(block, label, [[token, "required active code"]]);
        return true;
    } catch {
        return false;
    }
}

function blockById(source, type, id, label) {
    const q = qmlSource(source, label);
    const idAt = q.indexOf(`id: ${id}`);
    if (idAt < 0)
        return null;
    const typeAt = q.lastIndexOf(`${type} {`, idAt);
    return typeAt < 0 ? null : q.blockFrom(typeAt, `${type} ${id}`);
}

// Run the shipped adapter and shipped fuzzy finder together. Filtering a large
// list must return the original record, including duplicate-label identity.
const duplicateRecords = Array.from(DropdownLogic.optionRecords(
    ["Same", "Other", "Same"], ["first", "middle", "last"], { Same: "red", Other: "blue" }));
assert.deepEqual(duplicateRecords.map(record => [record.id, record.sourceIndex, record.label, record.icon]), [
    [0, 0, "Same", "first"], [1, 1, "Other", "middle"], [2, 2, "Same", "last"]
]);

const largeOptions = Array.from({ length: 10000 }, (_, index) => `Option ${index}`);
const largeRecords = DropdownLogic.optionRecords(largeOptions, [], {});
const finder = new Fzf.Finder(largeRecords, {
    selector: option => option.label,
    limit: 50,
    casing: "case-insensitive",
    sort: true
});
const filtered = Array.from(finder.find("Option 9999"), result => result.item);
assert.equal(filtered.length, 1, "the large-list filter must reach the requested record");
assert.equal(filtered[0], largeRecords[9999], "filtering must return the original record, not rebuild identity");
assert.equal(filtered[0].sourceIndex, 9999, "the delegate receives source identity directly from the filtered record");
const duplicateMatches = Array.from(new Fzf.Finder(duplicateRecords, {
    selector: option => option.label,
    casing: "case-insensitive",
    sort: true
}).find("Same"), result => result.item.sourceIndex);
assert.deepEqual(duplicateMatches, [0, 2], "duplicate labels remain distinct through filtering");
assert.deepEqual(Array.from(DropdownLogic.toggledValues(["Copy"], "Paste")), ["Copy", "Paste"]);
assert.deepEqual(Array.from(DropdownLogic.toggledValues(["Copy", "Paste"], "Copy")), ["Paste"]);

function buttonOwnsOnlyDeclaredGeometry(source) {
    const q = qmlSource(source, buttonPath);
    const root = q.blockFrom(q.indexOf("Item {"), "VgsButton root");
    const surface = blockById(source, "Rectangle", "buttonSurface", buttonPath);
    const mouse = blockById(source, "MouseArea", "mouseArea", buttonPath);
    return surface !== null && mouse !== null
        && !hasCode(root, "parent?.children", "VgsButton root")
        && !hasCode(root, "followedBySecondaryLink", "VgsButton root")
        && !hasCode(root, "reserveTrailingSpacing", "VgsButton root")
        && hasCode(root, "implicitWidth: visualWidth", "VgsButton root")
        && hasCode(surface, "width: root.isSecondary ? root.visualWidth : root.width", "button surface")
        && hasCode(mouse, "anchors.fill: buttonSurface", "button mouse area");
}

function dropdownUsesStableRecords(dropdown, option) {
    const q = qmlSource(dropdown, dropdownPath);
    const root = q.blockFrom(q.indexOf("Item {"), "VgsDropdown root");
    const finderBody = q.body("initFinder");
    const filtered = q.blockFrom(q.indexOf("property var filteredOptions:"), "filteredOptions binding");
    const delegate = q.blockFrom(q.indexOf("delegate: VgsDropdownOption {"), "dropdown delegate");
    const optionRoot = qmlSource(option, optionPath).blockFrom(
        qmlSource(option, optionPath).indexOf("Rectangle {"), "VgsDropdownOption root");
    return hasCode(root,
        "readonly property var optionRecords: DropdownLogic.optionRecords(options, optionIcons, optionColorMap)",
        "VgsDropdown root")
        && hasCode(finderBody, "new Fzf.Finder(root.optionRecords", "initFinder")
        && hasCode(finderBody, '"selector": option => option.label', "initFinder")
        && hasCode(filtered, "return fzfFinder.find(searchQuery).map(result => result.item);", "filteredOptions")
        && hasCode(delegate, "root.selectedOptionIndex === modelData.sourceIndex", "dropdown delegate")
        && hasCode(delegate, "root.toggleSelectedValue(modelData.sourceIndex, modelData.value);", "dropdown delegate")
        && hasCode(delegate, "root.selectOption(modelData.sourceIndex, modelData.value);", "dropdown delegate")
        && !hasCode(delegate, "indexOf(", "dropdown delegate")
        && !hasCode(delegate, "DropdownLogic.sourceIndex", "dropdown delegate")
        && hasCode(optionRoot, "text: root.modelData.label", "dropdown option");
}

function lockVideoActionSharesUnderline(source) {
    const row = blockById(source, "Item", "videoPathField", lockScreenPath);
    const field = blockById(source, "VgsTextField", "videoPathField", lockScreenPath);
    const button = blockById(source, "VgsButton", "browseVideoButton", lockScreenPath);
    return row !== null && field !== null && button !== null
        && hasCode(row, "height: videoPathField.height", "video path row")
        && hasCode(field, "rightAccessoryWidth: browseVideoButton.width + Theme.spacingM", "video path field")
        && hasCode(button, 'variant: "secondary"', "video Browse button")
        && row.includes(field) && row.includes(button);
}

assert.equal(buttonOwnsOnlyDeclaredGeometry(buttonSource), true);
assert.equal(dropdownUsesStableRecords(dropdownSource, optionSource), true);
assert.equal(lockVideoActionSharesUnderline(lockScreenSource), true);

const controls = [
    ["button requirement survives only in comment/string decoys", buttonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("implicitWidth: visualWidth",
            '// implicitWidth: visualWidth\n    property string widthDecoy: "implicitWidth: visualWidth"\n    implicitWidth: 0')],
    ["dead sibling scan returns", buttonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("property bool enableScaleAnimation: false",
            "readonly property real deadScan: { if (false) return parent?.children.length; return 0; }\n    property bool enableScaleAnimation: false")],
    ["filled surface shrinks to content", buttonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("width: root.isSecondary ? root.visualWidth : root.width", "width: root.visualWidth")],
    ["button hit area expands past treatment", buttonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("id: mouseArea\n        anchors.fill: buttonSurface", "id: mouseArea\n        anchors.fill: root")],
    ["record adapter survives only in comment/string decoys", source => dropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace(
            "readonly property var optionRecords: DropdownLogic.optionRecords(options, optionIcons, optionColorMap)",
            '// readonly property var optionRecords: DropdownLogic.optionRecords(options, optionIcons, optionColorMap)\n    property string recordDecoy: "readonly property var optionRecords: DropdownLogic.optionRecords(options, optionIcons, optionColorMap)"\n    readonly property var optionRecords: options')],
    ["fuzzy search drops normalized records", source => dropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("new Fzf.Finder(root.optionRecords", "new Fzf.Finder(root.options")],
    ["delegate reintroduces a direct indexOf scan", source => dropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("selected: dropdownMenu.selectedIndex === index",
            "selected: dropdownMenu.selectedIndex === index\n                            property int ignoredScan: root.options.indexOf(modelData.value)")],
    ["delegate hides indexOf in dead code", source => dropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("selected: dropdownMenu.selectedIndex === index",
            "selected: dropdownMenu.selectedIndex === index\n                            property int ignoredScan: { if (false) return root.options.indexOf(modelData.value); return modelData.sourceIndex; }")],
    ["delegate identity survives only in a string", source => dropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("root.selectedOptionIndex === modelData.sourceIndex",
            'root.selectedOptionIndex === 0 /* modelData.sourceIndex */')],
    ["option label survives only in comment/string decoys", source => dropdownUsesStableRecords(dropdownSource, source), optionSource,
        optionSource.replace("text: root.modelData.label",
            '// text: root.modelData.label\n            property string labelDecoy: "text: root.modelData.label"\n            text: root.modelData')],
    ["video accessory survives only in comment/string decoys", lockVideoActionSharesUnderline, lockScreenSource,
        lockScreenSource.replace("rightAccessoryWidth: browseVideoButton.width + Theme.spacingM",
            '// rightAccessoryWidth: browseVideoButton.width + Theme.spacingM\n                            property string accessoryDecoy: "rightAccessoryWidth: browseVideoButton.width + Theme.spacingM"\n                            rightAccessoryWidth: 0')],
    ["video Browse action leaves the shared row", lockVideoActionSharesUnderline, lockScreenSource,
        lockScreenSource.replace("id: browseVideoButton", "id: detachedBrowseButton")]
];

for (const [name, check, source, mutant] of controls) {
    assert.notEqual(mutant, source, `control did not apply: ${name}`);
    assert.equal(check(mutant), false, `must-fail control survived: ${name}`);
}

console.log(`flatline control checks passed (${controls.length} source mutants caught, 10000 filtered records exercised)`);
