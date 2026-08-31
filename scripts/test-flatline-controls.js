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

function requireCode(block, token, label, reason) {
    qmlSource(block, label).requires(block, label, [[token, reason]]);
}

function forbidCode(block, token, label, reason) {
    assert.throws(
        () => qmlSource(block, label).requires(block, label, [[token, "forbidden active code"]]),
        undefined,
        `${label} must not contain ${token} as active code — ${reason}`);
}

function blockById(source, type, id, label) {
    const q = qmlSource(source, label);
    const idAt = q.indexOf(`id: ${id}`);
    assert.notEqual(idAt, -1, `${label} must define id ${id}`);
    const typeAt = q.lastIndexOf(`${type} {`, idAt);
    assert.notEqual(typeAt, -1, `${label} must place id ${id} in a ${type} block`);
    return q.blockFrom(typeAt, `${type} ${id}`);
}

function assertDuplicateRecords(records) {
    assert.deepEqual(records.map(record => [
        record.id,
        record.sourceIndex,
        record.value,
        record.label,
        record.icon,
        record.color
    ]), [
        [0, 0, "Same", "Same", "first", "red"],
        [1, 1, "Other", "Other", "middle", "blue"],
        [2, 2, "Same", "Same", "last", "red"]
    ], "duplicate option records must preserve identity, runtime value, label, icon, and swatch color");
}

// Run the shipped adapter and shipped fuzzy finder together. Filtering a large
// list must return the original record, including duplicate-label identity.
const duplicateRecords = Array.from(DropdownLogic.optionRecords(
    ["Same", "Other", "Same"], ["first", "middle", "last"], { Same: "red", Other: "blue" }));
assertDuplicateRecords(duplicateRecords);

const corruptRecord = (field, value) => duplicateRecords.map((record, index) => (
    index === 2 ? { ...record, [field]: value } : { ...record }));
assert.throws(() => assertDuplicateRecords(corruptRecord("value", "Other")),
    /duplicate option records must preserve/, "the record-value assertion must catch selection identity corruption");
assert.throws(() => assertDuplicateRecords(corruptRecord("color", "blue")),
    /duplicate option records must preserve/, "the record-color assertion must catch swatch corruption");

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

function assertButtonOwnsOnlyDeclaredGeometry(source) {
    const q = qmlSource(source, buttonPath);
    const root = q.blockFrom(q.indexOf("Item {"), "VgsButton root");
    const surface = blockById(source, "Rectangle", "buttonSurface", buttonPath);
    const mouse = blockById(source, "MouseArea", "mouseArea", buttonPath);
    forbidCode(root, "parent?.children", "VgsButton root", "button geometry cannot inspect siblings");
    forbidCode(root, "followedBySecondaryLink", "VgsButton root", "row policy cannot live in the button");
    forbidCode(root, "reserveTrailingSpacing", "VgsButton root", "callers own action spacing");
    requireCode(root, "implicitWidth: visualWidth", "VgsButton root", "content determines implicit width");
    requireCode(surface, "width: root.isSecondary ? root.visualWidth : root.width", "button surface",
        "filled treatment consumes allocated width while links stay content-sized");
    requireCode(mouse, "anchors.fill: buttonSurface", "button mouse area", "hit area matches treatment");
}

function assertDropdownUsesStableRecords(dropdown, option) {
    const q = qmlSource(dropdown, dropdownPath);
    const root = q.blockFrom(q.indexOf("Item {"), "VgsDropdown root");
    const finderBody = q.body("initFinder");
    const filtered = q.blockFrom(q.indexOf("property var filteredOptions:"), "filteredOptions binding");
    const delegate = q.blockFrom(q.indexOf("delegate: VgsDropdownOption {"), "dropdown delegate");
    const optionQ = qmlSource(option, optionPath);
    const optionRoot = optionQ.blockFrom(optionQ.indexOf("Rectangle {"), "VgsDropdownOption root");
    requireCode(root,
        "readonly property var optionRecords: DropdownLogic.optionRecords(options, optionIcons, optionColorMap)",
        "VgsDropdown root", "string arrays adapt to stable records once");
    requireCode(finderBody, "new Fzf.Finder(root.optionRecords", "initFinder", "fuzzy search receives records");
    requireCode(finderBody, '"selector": option => option.label', "initFinder", "search reads record labels");
    requireCode(filtered, "return fzfFinder.find(searchQuery).map(result => result.item);", "filteredOptions",
        "filter results retain their original records");
    requireCode(delegate, "root.selectedOptionIndex === modelData.sourceIndex", "dropdown delegate",
        "current selection compares stable source identity");
    requireCode(delegate, "root.toggleSelectedValue(modelData.sourceIndex, modelData.value);", "dropdown delegate",
        "multi-select forwards record identity and value");
    requireCode(delegate, "root.selectOption(modelData.sourceIndex, modelData.value);", "dropdown delegate",
        "single-select forwards record identity and value");
    forbidCode(delegate, "indexOf(", "dropdown delegate", "delegates cannot rescan source options");
    forbidCode(delegate, "DropdownLogic.sourceIndex", "dropdown delegate", "delegates cannot reconstruct identity");
    requireCode(optionRoot, "text: root.modelData.label", "dropdown option", "delegates render record labels");
}

function assertLockVideoActionSharesUnderline(source) {
    const row = blockById(source, "Item", "videoPathField", lockScreenPath);
    const field = blockById(source, "VgsTextField", "videoPathField", lockScreenPath);
    const button = blockById(source, "VgsButton", "browseVideoButton", lockScreenPath);
    requireCode(row, "height: videoPathField.height", "video path row", "row follows the shared field height");
    requireCode(row, "id: videoPathField", "video path row", "field stays inside the shared row");
    requireCode(row, "id: browseVideoButton", "video path row", "Browse stays inside the shared row");
    requireCode(field, "rightAccessoryWidth: browseVideoButton.width + Theme.spacingM", "video path field",
        "field reserves inline accessory width");
    requireCode(button, 'variant: "secondary"', "video Browse button", "inline action remains link-styled");
}

assertButtonOwnsOnlyDeclaredGeometry(buttonSource);
assertDropdownUsesStableRecords(dropdownSource, optionSource);
assertLockVideoActionSharesUnderline(lockScreenSource);

const controls = [
    ["button requirement survives only in comment/string decoys", assertButtonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("implicitWidth: visualWidth",
            '// implicitWidth: visualWidth\n    property string widthDecoy: "implicitWidth: visualWidth"\n    implicitWidth: 0')],
    ["dead sibling scan returns", assertButtonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("property bool enableScaleAnimation: false",
            "readonly property real deadScan: { if (false) return parent?.children.length; return 0; }\n    property bool enableScaleAnimation: false")],
    ["filled surface shrinks to content", assertButtonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("width: root.isSecondary ? root.visualWidth : root.width", "width: root.visualWidth")],
    ["button hit area expands past treatment", assertButtonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("id: mouseArea\n        anchors.fill: buttonSurface", "id: mouseArea\n        anchors.fill: root")],
    ["record adapter survives only in comment/string decoys", source => assertDropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace(
            "readonly property var optionRecords: DropdownLogic.optionRecords(options, optionIcons, optionColorMap)",
            '// readonly property var optionRecords: DropdownLogic.optionRecords(options, optionIcons, optionColorMap)\n    property string recordDecoy: "readonly property var optionRecords: DropdownLogic.optionRecords(options, optionIcons, optionColorMap)"\n    readonly property var optionRecords: options')],
    ["fuzzy search drops normalized records", source => assertDropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("new Fzf.Finder(root.optionRecords", "new Fzf.Finder(root.options")],
    ["delegate reintroduces a direct indexOf scan", source => assertDropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("selected: dropdownMenu.selectedIndex === index",
            "selected: dropdownMenu.selectedIndex === index\n                            property int ignoredScan: root.options.indexOf(modelData.value)")],
    ["delegate hides indexOf in dead code", source => assertDropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("selected: dropdownMenu.selectedIndex === index",
            "selected: dropdownMenu.selectedIndex === index\n                            property int ignoredScan: { if (false) return root.options.indexOf(modelData.value); return modelData.sourceIndex; }")],
    ["delegate identity survives only in a string", source => assertDropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("root.selectedOptionIndex === modelData.sourceIndex",
            'root.selectedOptionIndex === 0 /* modelData.sourceIndex */')],
    ["option label survives only in comment/string decoys", source => assertDropdownUsesStableRecords(dropdownSource, source), optionSource,
        optionSource.replace("text: root.modelData.label",
            '// text: root.modelData.label\n            property string labelDecoy: "text: root.modelData.label"\n            text: root.modelData')],
    ["video accessory survives only in comment/string decoys", assertLockVideoActionSharesUnderline, lockScreenSource,
        lockScreenSource.replace("rightAccessoryWidth: browseVideoButton.width + Theme.spacingM",
            '// rightAccessoryWidth: browseVideoButton.width + Theme.spacingM\n                            property string accessoryDecoy: "rightAccessoryWidth: browseVideoButton.width + Theme.spacingM"\n                            rightAccessoryWidth: 0')],
    ["video Browse action leaves the shared row", assertLockVideoActionSharesUnderline, lockScreenSource,
        lockScreenSource.replace("id: browseVideoButton", "id: detachedBrowseButton")]
];

for (const [name, check, source, mutant] of controls) {
    assert.notEqual(mutant, source, `control did not apply: ${name}`);
    assert.throws(() => check(mutant), undefined, `must-fail control survived: ${name}`);
}

console.log(`flatline control checks passed (${controls.length} source mutants, 2 record mutants, 10000 filtered records)`);
