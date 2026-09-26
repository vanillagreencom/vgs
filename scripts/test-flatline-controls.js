#!/usr/bin/env node

"use strict";

const test = require("node:test");
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
const choicePath = path.join(repoRoot, "quickshell/vshell/Modules/Settings/Widgets/SettingsChoiceRow.qml");
const fzfPath = path.join(repoRoot, "quickshell/vshell/Common/fzf.js");
const lockScreenPath = path.join(repoRoot, "quickshell/vshell/Modules/Settings/LockScreenTab.qml");
const windowRulesPath = path.join(repoRoot, "quickshell/vshell/Modules/Settings/WindowRulesTab.qml");

const read = file => fs.readFileSync(file, "utf8");
const buttonSource = read(buttonPath);
const dropdownSource = read(dropdownPath);
const optionSource = read(optionPath);
const choiceSource = read(choicePath);
const lockScreenSource = read(lockScreenPath);
const windowRulesSource = read(windowRulesPath);
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

function assertBinding(block, name, expected, label) {
    assert.equal(qmlSource(block, label).binding(name).value, expected,
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
test("optionRecords keeps identity, value, label, icon and colour on duplicate options, and the check rejects corruption", () => {
    assertDuplicateRecords(duplicateRecords);
    const corruptRecord = (field, value) => duplicateRecords.map((record, index) => (
        index === 2 ? { ...record, [field]: value } : { ...record }));
    assert.throws(() => assertDuplicateRecords(corruptRecord("value", "Other")),
        /duplicate option records must preserve/, "selection-value corruption must fail");
    assert.throws(() => assertDuplicateRecords(corruptRecord("color", "blue")),
        /duplicate option records must preserve/, "swatch-color corruption must fail");
});

test("the finder returns the original records with their source indexes, over ten thousand options and duplicates", () => {
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
});

test("toggledValues adds an absent value and removes a present one", () => {
    for (const [values, toggled, expected] of [
        [["Copy"], "Paste", ["Copy", "Paste"]],
        [["Copy", "Paste"], "Copy", ["Paste"]]
    ]) {
        assert.deepEqual(Array.from(DropdownLogic.toggledValues(values, toggled)), expected);
    }
});

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
    assertBinding(surface, "anchors.horizontalCenter",
        "root.isSecondary ? parent.horizontalCenter : undefined", "button surface");
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
    assertExactBlock(qmlSource(popup, "dropdown popup").binding("filteredOptions").block,
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

function runSelectCurrent(source, multiSelect) {
    const events = [];
    const root = {
        multiSelect,
        toggleSelectedValue: (index, value) => events.push(["multi", index, value]),
        selectOption: (index, value) => events.push(["single", index, value])
    };
    const body = qmlSource(source, dropdownPath).body("selectCurrent");
    vm.runInNewContext(`(() => ${body})()`, {
        root,
        filteredOptions: [duplicateRecords[2]],
        selectedIndex: 0,
        close: () => events.push(["close"])
    });
    return events;
}

function assertKeyboardSelectionUsesStableRecord(source) {
    assert.deepEqual(runSelectCurrent(source, false), [["single", 2, "Same"], ["close"]],
        "single-select keyboard choice must emit the record source index/value and close");
    assert.deepEqual(runSelectCurrent(source, true), [["multi", 2, "Same"]],
        "multi-select keyboard choice must emit the record source index/value and stay open");
}

function runChoiceHandler(source, name, args) {
    const handlers = qmlSource(source, choicePath).handlers(name);
    assert.equal(handlers.length, 1, `SettingsChoiceRow must define one ${name} handler`);
    const expression = handlers[0].slice(handlers[0].indexOf(":") + 1);
    const events = [];
    const handler = vm.runInNewContext(`(${expression})`, {
        selectionChanged: (index, selected) => events.push([index, selected])
    });
    handler(...args);
    return events;
}

function assertChoiceForwardsSelection(source) {
    assert.deepEqual(runChoiceHandler(source, "onOptionSelected", [2, "Same"]), [[2, true]],
        "single selection must forward its source index as selected");
    assert.deepEqual(runChoiceHandler(source, "onMultiSelectionChanged", [2, "Same", false, ["Other"]]),
        [[2, false]], "multi selection must forward its source index and selected state");
}

function assertWindowSelectorKeepsIndexedIdentity(source) {
    const selector = blockById(source, "VgsDropdown", "windowSelector", windowRulesPath);
    const handlers = qmlSource(selector, "window selector").handlers("onOptionSelected");
    assert.equal(handlers.length, 1, "window selector must define one indexed selection handler");
    forbidCode(selector, "indexOf(", "window selector", "duplicate labels cannot identify windows");
    const windows = [
        { id: "first", appId: "Same", title: "" },
        { id: "middle", appId: "Other", title: "" },
        { id: "last", appId: "Same", title: "" }
    ];
    let opened = null;
    const context = vm.createContext({
        index: 2,
        value: "Same",
        options: ["Same", "Other", "Same"],
        selectedOptionIndex: -1,
        root: { activeWindows: windows, openRuleModal: window => { opened = window; } }
    });
    vm.runInContext(`(() => ${handlers[0]})()`, context);
    assert.equal(context.selectedOptionIndex, 2,
        "window selector must retain the emitted source index for trigger rendering");
    assert.equal(opened, windows[2], "window selector must open the duplicate record at source index 2");
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

test("VgsButton owns only its declared geometry", () => assertButtonOwnsOnlyDeclaredGeometry(buttonSource));
test("VgsDropdown renders and selects through stable option records", () => assertDropdownUsesStableRecords(dropdownSource, optionSource));
test("keyboard selection emits the record's source index and value", () => assertKeyboardSelectionUsesStableRecord(dropdownSource));
test("SettingsChoiceRow forwards the source index and selected state", () => assertChoiceForwardsSelection(choiceSource));
test("the window selector keeps indexed identity over duplicate labels", () => assertWindowSelectorKeepsIndexedIdentity(windowRulesSource));
test("the lock video field and its Browse button share one row and underline", () => assertLockVideoActionSharesUnderline(lockScreenSource));

const controls = [
    ["button live binding replaced by a dead satisfied label", assertButtonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("implicitWidth: visualWidth",
            "property real inertWidth: { if (false) { implicitWidth: visualWidth; } return 0; }\n    implicitWidth: 0")],
    ["surface live binding replaced by an unrelated satisfied label", assertButtonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("width: root.isSecondary ? root.visualWidth : root.width",
            "property real inertSurface: { if (false) { width: root.isSecondary ? root.visualWidth : root.width; } return 0; }\n        width: root.visualWidth")],
    ["explicit-width secondary surface stays left aligned", assertButtonOwnsOnlyDeclaredGeometry, buttonSource,
        buttonSource.replace("anchors.horizontalCenter: root.isSecondary ? parent.horizontalCenter : undefined",
            "anchors.horizontalCenter: undefined")],
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
    ["single keyboard selection restores the old string assignment", assertKeyboardSelectionUsesStableRecord, dropdownSource,
        dropdownSource.replace("const option = filteredOptions[selectedIndex];",
            "const option = filteredOptions[selectedIndex].value;")],
    ["single keyboard selection substitutes the popup index", assertKeyboardSelectionUsesStableRecord, dropdownSource,
        dropdownSource.replace("root.selectOption(option.sourceIndex, option.value);",
            "root.selectOption(selectedIndex, option.value);")],
    ["multi keyboard selection substitutes the popup index", assertKeyboardSelectionUsesStableRecord, dropdownSource,
        dropdownSource.replace("root.toggleSelectedValue(option.sourceIndex, option.value);",
            "root.toggleSelectedValue(selectedIndex, option.value);")],
    ["single-choice forwarding handler is deleted", assertChoiceForwardsSelection, choiceSource,
        choiceSource.replace("onOptionSelected: (index, value) => selectionChanged(index, true)", "")],
    ["multi-choice forwarding survives only in an inert handler", assertChoiceForwardsSelection, choiceSource,
        choiceSource.replace("onMultiSelectionChanged: (index, value, selected, values) => selectionChanged(index, selected)",
            "onMultiSelectionChanged: (index, value, selected, values) => { if (false) selectionChanged(index, selected); }")],
    ["window selector re-derives identity from a duplicate label", assertWindowSelectorKeepsIndexedIdentity, windowRulesSource,
        windowRulesSource.replace("selectedOptionIndex = index;",
            "selectedOptionIndex = options.indexOf(value);")],
    ["video accessory survives only in a dead satisfied label", assertLockVideoActionSharesUnderline, lockScreenSource,
        lockScreenSource.replace("rightAccessoryWidth: browseVideoButton.width + Theme.spacingM",
            "property real inertAccessory: { if (false) { rightAccessoryWidth: browseVideoButton.width + Theme.spacingM; } return 0; }\n                            rightAccessoryWidth: 0")],
    ["video Browse action leaves the shared row", assertLockVideoActionSharesUnderline, lockScreenSource,
        lockScreenSource.replace("id: browseVideoButton", "id: detachedBrowseButton")]
];

test("every planted source mutant is caught by its predicate", () => {
    for (const [name, check, source, mutant] of controls) {
        assert.notEqual(mutant, source, `control did not apply: ${name}`);
        assert.throws(() => check(mutant), undefined, `must-fail control survived: ${name}`);
    }
});
