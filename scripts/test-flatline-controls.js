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
const flatCode = text => qmlSource.flat(qmlSource.stripComments(text));

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

function blockById(source, type, id, label) {
    const q = qmlSource(source, label);
    const idAt = q.indexOf(`id: ${id}`);
    assert.notEqual(idAt, -1, `${label} must define id ${id}`);
    const typeAt = q.lastIndexOf(`${type} {`, idAt);
    assert.notEqual(typeAt, -1, `${label} must place id ${id} in a ${type} block`);
    return q.blockFrom(typeAt, `${type} ${id}`);
}

// Finds one property on the component itself. Nested children, JS branches,
// labels, strings, and comments cannot answer because their brace depth is not
// the component's top level or their contents are blank in codeOnly().
function topLevelBinding(block, name, label) {
    const structure = qmlSource.codeOnly(block);
    const matches = [];
    let depth = 0;
    let lineStart = 0;
    for (let i = 0; i <= structure.length; i += 1) {
        if (i !== structure.length && structure[i] !== "\n")
            continue;
        const structuralLine = structure.slice(lineStart, i);
        const colon = structuralLine.indexOf(":");
        if (depth === 1 && colon >= 0) {
            const left = structuralLine.slice(0, colon).trim();
            const declaredName = left.split(/\s+/).at(-1);
            if (declaredName === name) {
                const sourceLine = block.slice(lineStart, i);
                const sourceColon = sourceLine.indexOf(":");
                matches.push({
                    at: lineStart + sourceColon + 1,
                    value: sourceLine.slice(sourceColon + 1).trim()
                });
            }
        }
        for (const ch of structuralLine) {
            if (ch === "{") depth += 1;
            else if (ch === "}") depth -= 1;
        }
        lineStart = i + 1;
    }
    assert.equal(matches.length, 1,
        `${label} must define ${name} exactly once at component top level, found ${matches.length}`);
    const match = matches[0];
    return {
        value: match.value,
        block: match.value.startsWith("{")
            ? qmlSource(block, label).blockFrom(match.at, `${label}.${name}`)
            : null
    };
}

function assertBinding(block, name, expected, label) {
    assert.equal(topLevelBinding(block, name, label).value, expected,
        `${label}.${name} must be the live binding ${expected}`);
}

function assertExactBlock(actual, expected, label) {
    assert.equal(flatCode(actual), flatCode(expected), `${label} must keep its live decision block`);
}

function forbidCode(block, token, label, reason) {
    assert.throws(
        () => qmlSource(block, label).requires(block, label, [[token, "forbidden active code"]]),
        undefined,
        `${label} must not contain ${token} as active code — ${reason}`);
}

function assertDuplicateRecords(records) {
    assert.deepEqual(records.map(record => [
        record.id, record.sourceIndex, record.value, record.label, record.icon, record.color
    ]), [
        [0, 0, "Same", "Same", "first", "red"],
        [1, 1, "Other", "Other", "middle", "blue"],
        [2, 2, "Same", "Same", "last", "red"]
    ], "duplicate option records must preserve identity, value, label, icon, and color");
}

const duplicateRecords = Array.from(DropdownLogic.optionRecords(
    ["Same", "Other", "Same"], ["first", "middle", "last"], { Same: "red", Other: "blue" }));
assertDuplicateRecords(duplicateRecords);
const corruptRecord = (field, value) => duplicateRecords.map((record, index) => (
    index === 2 ? { ...record, [field]: value } : { ...record }));
assert.throws(() => assertDuplicateRecords(corruptRecord("value", "Other")),
    /duplicate option records must preserve/, "selection-value corruption must fail");
assert.throws(() => assertDuplicateRecords(corruptRecord("color", "blue")),
    /duplicate option records must preserve/, "swatch-color corruption must fail");

const largeOptions = Array.from({ length: 10000 }, (_, index) => `Option ${index}`);
const largeRecords = DropdownLogic.optionRecords(largeOptions, [], {});
const finder = new Fzf.Finder(largeRecords, {
    selector: option => option.label,
    limit: 50,
    casing: "case-insensitive",
    sort: true
});
const filteredRecords = Array.from(finder.find("Option 9999"), result => result.item);
assert.equal(filteredRecords.length, 1);
assert.equal(filteredRecords[0], largeRecords[9999], "filtering must retain the original record");
assert.equal(filteredRecords[0].sourceIndex, 9999);
const duplicateMatches = Array.from(new Fzf.Finder(duplicateRecords, {
    selector: option => option.label,
    casing: "case-insensitive",
    sort: true
}).find("Same"), result => result.item.sourceIndex);
assert.deepEqual(duplicateMatches, [0, 2]);
assert.deepEqual(Array.from(DropdownLogic.toggledValues(["Copy"], "Paste")), ["Copy", "Paste"]);
assert.deepEqual(Array.from(DropdownLogic.toggledValues(["Copy", "Paste"], "Copy")), ["Paste"]);

function assertButtonOwnsOnlyDeclaredGeometry(source) {
    const q = qmlSource(source, buttonPath);
    const root = q.blockFrom(q.indexOf("Item {"), "VgsButton root");
    const surface = blockById(source, "Rectangle", "buttonSurface", buttonPath);
    const mouse = blockById(source, "MouseArea", "mouseArea", buttonPath);
    forbidCode(root, "parent?.children", "VgsButton root", "geometry cannot inspect siblings");
    forbidCode(root, "followedBySecondaryLink", "VgsButton root", "row policy cannot live here");
    forbidCode(root, "reserveTrailingSpacing", "VgsButton root", "callers own action spacing");
    assertBinding(root, "implicitWidth", "visualWidth", "VgsButton root");
    assertBinding(surface, "width", "root.isSecondary ? root.visualWidth : root.width", "button surface");
    assertBinding(mouse, "anchors.fill", "buttonSurface", "button mouse area");
}

const FILTERED_OPTIONS = `{
    if (!root.enableFuzzySearch || searchQuery.length === 0)
        return root.optionRecords;
    if (!fzfFinder)
        return root.optionRecords;
    return fzfFinder.find(searchQuery).map(result => result.item);
}`;
const INIT_FINDER = `{
    fzfFinder = new Fzf.Finder(root.optionRecords, {
        "selector": option => option.label,
        "limit": 50,
        "casing": "case-insensitive",
        "sort": true,
        "tiebreakers": [(a, b, selector) => selector(a.item).length - selector(b.item).length]
    });
}`;
const OPTION_CLICK = `{
    if (root.multiSelect) {
        root.toggleSelectedValue(modelData.sourceIndex, modelData.value);
        return;
    }
    root.selectOption(modelData.sourceIndex, modelData.value);
    root.closeDropdownMenu();
}`;

function assertDropdownUsesStableRecords(dropdown, option) {
    const q = qmlSource(dropdown, dropdownPath);
    const root = q.blockFrom(q.indexOf("Item {"), "VgsDropdown root");
    const popup = blockById(dropdown, "Popup", "dropdownMenu", dropdownPath);
    const delegate = q.blockFrom(q.indexOf("delegate: VgsDropdownOption {"), "dropdown delegate");
    const optionQ = qmlSource(option, optionPath);
    const optionText = optionQ.blockFrom(optionQ.indexOf("StyledText {"), "dropdown option label");
    assertBinding(root, "optionRecords", "DropdownLogic.optionRecords(options, optionIcons, optionColorMap)",
        "VgsDropdown root");
    assertExactBlock(topLevelBinding(popup, "filteredOptions", "dropdown popup").block,
        FILTERED_OPTIONS, "dropdown popup.filteredOptions");
    assertExactBlock(q.body("initFinder"), INIT_FINDER, "initFinder");
    assertBinding(delegate, "current",
        "root.multiSelect ? root.selectedValues.includes(modelData.value) : (root.selectedOptionIndex >= 0 ? root.selectedOptionIndex === modelData.sourceIndex : root.currentValue === modelData.value)",
        "dropdown delegate");
    const clickHandlers = qmlSource(delegate, "dropdown delegate").handlers("onClicked");
    assert.equal(clickHandlers.length, 1, "dropdown delegate must define one onClicked handler");
    assertExactBlock(clickHandlers[0], OPTION_CLICK, "dropdown delegate.onClicked");
    forbidCode(delegate, "indexOf(", "dropdown delegate", "delegates cannot rescan source options");
    forbidCode(delegate, "DropdownLogic.sourceIndex", "dropdown delegate", "identity is already on the record");
    assertBinding(optionText, "text", "root.modelData.label", "dropdown option label");
}

function assertLockVideoActionSharesUnderline(source) {
    const row = blockById(source, "Item", "videoPathField", lockScreenPath);
    const field = blockById(source, "VgsTextField", "videoPathField", lockScreenPath);
    const button = blockById(source, "VgsButton", "browseVideoButton", lockScreenPath);
    assertBinding(row, "height", "videoPathField.height", "video path row");
    assertBinding(field, "rightAccessoryWidth", "browseVideoButton.width + Theme.spacingM", "video path field");
    assertBinding(button, "variant", '"secondary"', "video Browse button");
    assert.ok(row.includes(field) && row.includes(button), "video field and Browse button must share one row");
}

assertButtonOwnsOnlyDeclaredGeometry(buttonSource);
assertDropdownUsesStableRecords(dropdownSource, optionSource);
assertLockVideoActionSharesUnderline(lockScreenSource);

const controls = [
    ["button live binding replaced by a dead satisfied label", assertButtonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("implicitWidth: visualWidth",
            "property real inertWidth: { if (false) { implicitWidth: visualWidth; } return 0; }\n    implicitWidth: 0")],
    ["surface live binding replaced by an unrelated satisfied label", assertButtonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("width: root.isSecondary ? root.visualWidth : root.width",
            "property real inertSurface: { if (false) { width: root.isSecondary ? root.visualWidth : root.width; } return 0; }\n        width: root.visualWidth")],
    ["dead sibling scan returns", assertButtonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("property bool enableScaleAnimation: false",
            "readonly property real deadScan: { if (false) return parent?.children.length; return 0; }\n    property bool enableScaleAnimation: false")],
    ["button hit area expands past treatment", assertButtonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("id: mouseArea\n        anchors.fill: buttonSurface", "id: mouseArea\n        anchors.fill: root")],
    ["record adapter survives only in a dead satisfied label", source => assertDropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace(
            "readonly property var optionRecords: DropdownLogic.optionRecords(options, optionIcons, optionColorMap)",
            "property var inertRecords: { if (false) { optionRecords: DropdownLogic.optionRecords(options, optionIcons, optionColorMap); } return []; }\n    readonly property var optionRecords: options")],
    ["finder makes the right call but discards it", source => assertDropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("            fzfFinder = new Fzf.Finder(root.optionRecords, {",
            "            new Fzf.Finder(root.optionRecords, {\n                \"selector\": option => option.label\n            });\n            fzfFinder = new Fzf.Finder(root.options, {")],
    ["filtered records survive only in a dead branch", source => assertDropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("        property var filteredOptions: {",
            "        property var filteredOptions: {\n            if (false) return fzfFinder.find(searchQuery).map(result => result.item);")],
    ["delegate current identity survives only in an unrelated binding", source => assertDropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("                            current: root.multiSelect",
            "                            property bool inertCurrent: { if (false) return root.selectedOptionIndex === modelData.sourceIndex; return false; }\n                            current: false ? root.multiSelect")],
    ["delegate click makes correct calls only in dead code", source => assertDropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("                            onClicked: {",
            "                            onClicked: {\n                                if (false) { root.toggleSelectedValue(modelData.sourceIndex, modelData.value); root.selectOption(modelData.sourceIndex, modelData.value); }")],
    ["delegate reintroduces a direct indexOf scan", source => assertDropdownUsesStableRecords(source, optionSource), dropdownSource,
        dropdownSource.replace("selected: dropdownMenu.selectedIndex === index",
            "selected: dropdownMenu.selectedIndex === index\n                            property int ignoredScan: root.options.indexOf(modelData.value)")],
    ["option label survives only in a dead satisfied label", source => assertDropdownUsesStableRecords(dropdownSource, source), optionSource,
        optionSource.replace("text: root.modelData.label",
            "property string inertText: { if (false) { text: root.modelData.label; } return \"\"; }\n            text: root.modelData")],
    ["video accessory survives only in a dead satisfied label", assertLockVideoActionSharesUnderline, lockScreenSource,
        lockScreenSource.replace("rightAccessoryWidth: browseVideoButton.width + Theme.spacingM",
            "property real inertAccessory: { if (false) { rightAccessoryWidth: browseVideoButton.width + Theme.spacingM; } return 0; }\n                            rightAccessoryWidth: 0")],
    ["video Browse action leaves the shared row", assertLockVideoActionSharesUnderline, lockScreenSource,
        lockScreenSource.replace("id: browseVideoButton", "id: detachedBrowseButton")]
];

for (const [name, check, source, mutant] of controls) {
    assert.notEqual(mutant, source, `control did not apply: ${name}`);
    assert.throws(() => check(mutant), undefined, `must-fail control survived: ${name}`);
}

console.log(`flatline control checks passed (${controls.length} source mutants, 2 record mutants, 10000 filtered records)`);
