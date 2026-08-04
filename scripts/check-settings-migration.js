#!/usr/bin/env node
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..");
const settingsDir = path.join(repoRoot, "quickshell", "vshell", "Common", "settings");
const specPath = path.join(settingsDir, "SettingsSpec.js");
const storePath = path.join(settingsDir, "SettingsStore.js");
const defaultSettingsPath = path.join(repoRoot, "config", "vshell", "settings.default.json");
const settingsDataPath = path.join(repoRoot, "quickshell", "vshell", "Common", "SettingsData.qml");

function qmlJsToPlainJs(source) {
  return source
    .split("\n")
    .filter((line) => !line.trim().startsWith(".pragma") && !line.trim().startsWith(".import"))
    .join("\n");
}

function loadModule(filePath, context) {
  vm.createContext(context);
  vm.runInContext(qmlJsToPlainJs(fs.readFileSync(filePath, "utf8")), context, {
    filename: filePath,
  });
  return context;
}

const spec = loadModule(specPath, {});
const store = loadModule(storePath, {
  console,
  SpecModule: {
    SPEC: spec.SPEC,
    getValidKeys: spec.getValidKeys,
  },
});
const defaultSettings = JSON.parse(fs.readFileSync(defaultSettingsPath, "utf8"));
const settingsDataSource = fs.readFileSync(settingsDataPath, "utf8");

const barWidgets = loadModule(path.join(settingsDir, "BarWidgets.js"), {});

const TARGET_VERSION = 21;

// The shipped seed already carries the current schema, so it must declare the
// current version. When it lags, a fresh install is treated as a legacy config
// and rewritten by migrations it was never meant to need — and the drift is
// invisible until someone reads both files side by side.
assert.strictEqual(
  defaultSettings.configVersion,
  TARGET_VERSION,
  "settings.default.json configVersion must equal the migration TARGET_VERSION; " +
    "bump the seed marker whenever a migration is appended"
);

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function migrate(fixture) {
  const migrated = clone(store.migrateToVersion(clone(fixture), TARGET_VERSION));
  assert(migrated, "migration should return an updated settings object");
  assert.strictEqual(migrated.configVersion, TARGET_VERSION);
  return migrated;
}

function assertMissing(obj, keys) {
  for (const key of keys) {
    assert.strictEqual(
      Object.prototype.hasOwnProperty.call(obj, key),
      false,
      `${key} should not be persisted after migration`
    );
  }
}

function parseQmlLiteral(raw, key) {
  const value = raw.trim().replace(/;$/, "");
  const constants = {
    "Font.Normal": 400,
    "Font.PreferDefaultHinting": 0,
    "SettingsData.TextRenderType.Qt": 0,
    "SettingsData.TextRenderType.Native": 1,
    "SettingsData.TextRenderType.Curve": 2,
    "SettingsData.TextRenderQuality.Default": 0,
    "SettingsData.TextRenderQuality.Low": 1,
    "SettingsData.TextRenderQuality.Normal": 2,
    "SettingsData.TextRenderQuality.High": 3,
    "SettingsData.TextRenderQuality.VeryHigh": 4,
  };
  if (Object.prototype.hasOwnProperty.call(constants, value)) return constants[value];
  if (value === "true") return true;
  if (value === "false") return false;
  if (/^["'].*["']$/.test(value)) return value.slice(1, -1);
  if (/^-?\d+(?:\.\d+)?$/.test(value)) return Number(value);
  throw new Error(`Unsupported QML default for ${key}: ${value}`);
}

function qmlDefaultFor(key) {
  const re = new RegExp(`property\\s+(?:bool|string|int|real)\\s+${key}\\s*:\\s*([^\\n]+)`);
  const match = settingsDataSource.match(re);
  assert(match, `SettingsData.qml should define ${key}`);
  return parseQmlLiteral(match[1], key);
}

function assertDefaultParity(keys) {
  for (const key of keys) {
    assert(Object.prototype.hasOwnProperty.call(spec.SPEC, key), `${key} should exist in SettingsSpec`);
    assert(Object.prototype.hasOwnProperty.call(defaultSettings, key), `${key} should exist in settings.default.json`);
    assert.deepStrictEqual(defaultSettings[key], spec.SPEC[key].def, `${key} seed default should match SettingsSpec`);
    assert.deepStrictEqual(qmlDefaultFor(key), spec.SPEC[key].def, `${key} QML default should match SettingsSpec`);
  }
}

assertDefaultParity([
  "popupTransparency",
  "popupBlurStrength",
  "popupGlassEffect",
  "surfaceGeometryTarget",
  "surfaceBorderWidth",
  "cornerRadius",
  "controlRadius",
  "hyprlandLayoutRadiusOverride",
  "hyprlandLayoutBorderSize",
  "hyprlandResizeOnBorder",
  "fontFamily",
  "monoFontFamily",
  "fontWeight",
  "fontScale",
  "textRenderType",
  "textRenderQuality",
  "textHintingPreference",
  "textAntialiasing",
  "textKerning",
  "textLetterSpacing",
  "textWordSpacing",
  "textLineHeight",
  "textLineHeightMode",
  "textUseVariableWeight",
  "textVariableWeight",
  "textUseOpticalSize",
  "textOpticalSize",
  "textFeatureLigatures",
  "textFeatureTabularNumbers",
  "textFeatureStylisticSet",
  "systemFontsManaged",
  "systemFontInterfaceAntialias",
  "systemFontInterfaceHinting",
  "systemFontInterfaceSubpixel",
  "systemFontInterfaceLcdFilter",
  "systemFontInterfaceAutohint",
  "systemFontMonoAntialias",
  "systemFontMonoHinting",
  "systemFontMonoSubpixel",
  "systemFontMonoLcdFilter",
  "systemFontMonoAutohint",
]);

const singleBarFixture = {
  configVersion: 1,
  barAtBottom: true,
  barLeftWidgets: ["launcherButton", "focusedWindow"],
  barCenterWidgets: ["clock"],
  barRightWidgets: ["battery"],
  barSpacing: 11,
  barInnerPadding: 6,
  barBottomGap: 4,
  barTransparency: 0.66,
  barWidgetTransparency: 0.77,
  barSquareCorners: true,
  barNoBackground: true,
  barGothCornersEnabled: true,
  barGothCornerRadiusOverride: true,
  barGothCornerRadiusValue: 16,
  barBorderEnabled: true,
  barBorderColor: "secondary",
  barBorderOpacity: 0.5,
  barBorderThickness: 3,
  barFontScale: 1.4,
  barAutoHide: true,
  barAutoHideDelay: 275,
  barOpenOnOverview: true,
  barVisible: false,
  popupGapsAuto: false,
  popupGapsManual: 9,
  unknownFutureSetting: true,
};

const singleBarMigrated = migrate(singleBarFixture);
assert.strictEqual(singleBarMigrated.barConfigs.length, 1);
const singleBar = singleBarMigrated.barConfigs[0];
assert.strictEqual(singleBar.position, 1);
assert.deepStrictEqual(singleBar.leftWidgets, ["launcherButton", "focusedWindow"]);
assert.deepStrictEqual(singleBar.centerWidgets, ["clock"]);
assert.deepStrictEqual(singleBar.rightWidgets, ["battery"]);
assert.strictEqual(singleBar.spacing, 11);
assert.strictEqual(singleBar.innerPadding, 6);
assert.strictEqual(singleBar.bottomGap, 4);
assert.strictEqual(singleBar.transparency, 0.66);
assert.strictEqual(singleBar.widgetTransparency, 0.77);
assert.strictEqual(singleBar.squareCorners, true);
assert.strictEqual(singleBar.noBackground, true);
assert.strictEqual(singleBar.gothCornersEnabled, true);
assert.strictEqual(singleBar.gothCornerRadiusOverride, true);
assert.strictEqual(singleBar.gothCornerRadiusValue, 16);
assert.strictEqual(singleBar.borderEnabled, true);
assert.strictEqual(singleBar.borderColor, "secondary");
assert.strictEqual(singleBar.borderOpacity, 0.5);
assert.strictEqual(singleBar.borderThickness, 3);
assert.strictEqual(singleBar.fontScale, 1.4);
assert.strictEqual(singleBar.autoHide, true);
assert.strictEqual(singleBar.autoHideDelay, 275);
assert.strictEqual(singleBar.openOnOverview, true);
assert.strictEqual(singleBar.visible, false);
assert.strictEqual(singleBar.popupGapsAuto, false);
assert.strictEqual(singleBar.popupGapsManual, 9);
assertMissing(singleBarMigrated, [
  "barAtBottom",
  "barLeftWidgets",
  "barCenterWidgets",
  "barRightWidgets",
  "barSpacing",
  "barFontScale",
  "popupGapsAuto",
  "popupGapsManual",
  "unknownFutureSetting",
]);

const desktopWidgetsMigrated = migrate({
  configVersion: 3,
  desktopClockEnabled: true,
  desktopClockStyle: "digital",
  desktopClockX: 24,
  desktopClockY: 48,
  desktopClockWidth: 300,
  desktopClockHeight: 160,
  desktopClockDisplayPreferences: ["DP-1"],
  systemMonitorEnabled: true,
  systemMonitorX: 80,
  systemMonitorY: 120,
  systemMonitorWidth: 360,
  systemMonitorHeight: 500,
  systemMonitorVariants: [
    {
      id: "dw_sysmon_secondary",
      name: "Secondary Monitor",
      config: { showCpu: false },
      positions: { "DP-2": { x: 10, y: 20, width: 320, height: 480 } },
    },
  ],
});
assert.deepStrictEqual(
  desktopWidgetsMigrated.desktopWidgetInstances.map((instance) => instance.id),
  ["dw_clock_primary", "dw_sysmon_primary", "dw_sysmon_secondary"]
);
assert.deepStrictEqual(desktopWidgetsMigrated.desktopWidgetInstances[0].positions.default, {
  x: 24,
  y: 48,
  width: 300,
  height: 160,
});
assert.strictEqual(desktopWidgetsMigrated.desktopWidgetInstances[1].config.showCpu, true);
assert.strictEqual(desktopWidgetsMigrated.desktopWidgetInstances[2].config.showCpu, false);

const weatherSessionMigrated = migrate({
  configVersion: 4,
  weatherLocation: "Portland",
  weatherCoordinates: { lat: 45.5152, lon: -122.6784 },
});
assertMissing(weatherSessionMigrated, ["weatherLocation", "weatherCoordinates"]);

const barElevationMigrated = migrate({
  configVersion: 5,
  barConfigs: [{ id: "default", shadowIntensity: 8 }],
});
assert.strictEqual(barElevationMigrated.barElevationEnabled, true);

const updaterWidgetMigrated = migrate({
  configVersion: 15,
  updaterUseCustomCommand: true,
  updaterCustomCommand: "paru -Syu",
  updaterIncludeFlatpak: true,
  updaterAllowAUR: true,
  barConfigs: [{
    id: "default",
    leftWidgets: ["systemUpdate"],
    centerWidgets: [],
    rightWidgets: [{ id: "sysUpdate", enabled: true }, { id: "systemUpdate", enabled: true }],
  }],
});
assert.deepStrictEqual(updaterWidgetMigrated.barConfigs[0].leftWidgets, []);
assert.deepStrictEqual(updaterWidgetMigrated.barConfigs[0].rightWidgets, [{ id: "sysUpdate", enabled: true }]);
assertMissing(updaterWidgetMigrated, [
  "updaterUseCustomCommand",
  "updaterCustomCommand",
  "updaterIncludeFlatpak",
  "updaterAllowAUR",
]);

const themeAppsMigrated = migrate({
  configVersion: 11,
  runVgsMatugenTemplates: true,
  matugenTemplateGtk: false,
  matugenTemplateKitty: true,
  matugenTemplateVscode: true,
});
assert.deepStrictEqual(themeAppsMigrated.themeApps, {
  gtk: false,
  kitty: true,
  vscode: true,
});
assertMissing(themeAppsMigrated, [
  "runVgsMatugenTemplates",
  "matugenTemplateGtk",
  "matugenTemplateKitty",
  "matugenTemplateVscode",
]);

const versionOnlyMigrated = migrate({
  configVersion: 12,
  currentThemeName: "tokyo-night",
  themeApps: { kitty: false },
  unknownFutureSetting: "drop",
});
assert.strictEqual(versionOnlyMigrated.currentThemeName, "tokyo-night");
assert.deepStrictEqual(versionOnlyMigrated.themeApps, { kitty: false });
assertMissing(versionOnlyMigrated, ["unknownFutureSetting"]);

const legacyThemeKeysMigrated = migrate({
  configVersion: 13,
  currentThemeName: "tokyo-night",
  customThemeFile: "custom-theme.json",
  registryThemeVariants: { catppuccin: "mocha" },
});
assert.strictEqual(legacyThemeKeysMigrated.currentThemeName, "tokyo-night");
assertMissing(legacyThemeKeysMigrated, ["customThemeFile", "registryThemeVariants"]);

const surfaceGeometryMigrated = migrate({
  configVersion: 14,
  cornerRadius: 18,
  hyprlandLayoutRadiusOverride: 18,
  hyprlandLayoutBorderSize: -1,
  hyprlandResizeOnBorder: false,
});
assert.strictEqual(surfaceGeometryMigrated.surfaceGeometryTarget, "sync");
assert.strictEqual(surfaceGeometryMigrated.surfaceBorderWidth, 1);
assert.strictEqual(surfaceGeometryMigrated.hyprlandResizeOnBorder, true);

const hyprlandOnlyGeometryMigrated = migrate({
  configVersion: 14,
  cornerRadius: 12,
  hyprlandLayoutRadiusOverride: 4,
});
assert.strictEqual(hyprlandOnlyGeometryMigrated.surfaceGeometryTarget, "hyprland");

const hyprlandBorderGeometryMigrated = migrate({
  configVersion: 14,
  cornerRadius: 12,
  hyprlandLayoutRadiusOverride: 12,
  hyprlandLayoutBorderSize: 3,
});
assert.strictEqual(hyprlandBorderGeometryMigrated.surfaceGeometryTarget, "hyprland");

const legacyLauncherMigrated = migrate({
  configVersion: 18,
  showLauncherButton: true,
  appLauncherViewMode: "grid",
  spotlightModalViewMode: "list",
  appDrawerSectionViewModes: { apps: "grid" },
  launcherUnloadOnClose: true,
  launcherUseOverlayLayer: true,
  launcherStyle: "spotlight",
  spotlightBarShowModeChips: true,
  rememberLastMode: false,
  rememberLastQuery: true,
  launcherSidebarShowByDefault: false,
  appLauncherGridColumns: 6,
});
assertMissing(legacyLauncherMigrated, [
  "showLauncherButton",
  "appLauncherViewMode",
  "spotlightModalViewMode",
  "appDrawerSectionViewModes",
  "launcherUnloadOnClose",
  "launcherUseOverlayLayer",
  "launcherStyle",
  "spotlightBarShowModeChips",
  "rememberLastMode",
  "rememberLastQuery",
]);
// Settings the vgsMenu launcher and the app picker still read must survive.
assert.strictEqual(legacyLauncherMigrated.launcherSidebarShowByDefault, false);
assert.strictEqual(legacyLauncherMigrated.appLauncherGridColumns, 6);

// VGS-61: bar widget lists were never reconciled against present hardware, so a
// barConfigs authored on a desktop left a laptop with no battery indicator.
// removedBarWidgets is what lets reconciliation tell "the user removed it" from
// "this config never mentioned it".
const desktopConfigOnALaptop = {
  configVersion: 19,
  barConfigs: [
    {
      id: "default",
      enabled: true,
      leftWidgets: ["launcherButton"],
      centerWidgets: ["clock"],
      rightWidgets: ["systemTray", "cpuUsage", "controlCenterButton"],
    },
  ],
};

const removalTrackingMigrated = migrate(desktopConfigOnALaptop);
assert.deepStrictEqual(
  removalTrackingMigrated.removedBarWidgets,
  [],
  "the removal record starts empty; seeding it from the current layout would preserve the bug"
);
assert.deepStrictEqual(
  removalTrackingMigrated.barConfigs[0].rightWidgets,
  ["systemTray", "cpuUsage", "controlCenterButton"],
  "migration must not touch the user's widget lists"
);

const existingRemovals = migrate({
  configVersion: 19,
  removedBarWidgets: ["battery"],
  barConfigs: [{ id: "default", enabled: true, rightWidgets: ["clock"] }],
});
assert.deepStrictEqual(existingRemovals.removedBarWidgets, ["battery"]);

// Never mentioned + hardware present -> inserted ahead of controlCenterButton.
const reconciled = clone(barWidgets.reconcile(clone(desktopConfigOnALaptop.barConfigs), [], { battery: true }));
assert(reconciled, "a battery-less config on a laptop should be reconciled");
assert.deepStrictEqual(reconciled.added, ["battery"]);
assert.deepStrictEqual(reconciled.barConfigs[0].rightWidgets, [
  "systemTray",
  "cpuUsage",
  "battery",
  "controlCenterButton",
]);

// Explicit removal must keep working, forever.
assert.strictEqual(
  barWidgets.reconcile(clone(desktopConfigOnALaptop.barConfigs), ["battery"], { battery: true }),
  null,
  "a widget the user removed must never come back"
);

// No hardware, nothing to do.
assert.strictEqual(
  barWidgets.reconcile(clone(desktopConfigOnALaptop.barConfigs), [], { battery: false }),
  null,
  "a machine without a battery must not grow a battery widget"
);

// Already mentioned anywhere counts, including disabled and in another section.
assert.strictEqual(
  barWidgets.reconcile(
    [{ id: "default", enabled: true, leftWidgets: [{ id: "battery", enabled: false }], rightWidgets: [] }],
    [],
    { battery: true }
  ),
  null,
  "a disabled battery widget is still a decision the user made"
);

// Idempotent: a second pass over its own output changes nothing.
assert.strictEqual(
  barWidgets.reconcile(reconciled.barConfigs, [], { battery: true }),
  null,
  "reconciliation must not keep adding the widget on every load"
);

// Exactly one bar is touched, and it is the first enabled one.
const multiBar = clone(
  barWidgets.reconcile(
    [
      { id: "disabled", enabled: false, rightWidgets: ["clock"] },
      { id: "laptop", enabled: true, rightWidgets: ["clock", "controlCenterButton"] },
      { id: "second", enabled: true, rightWidgets: ["clock"] },
    ],
    [],
    { battery: true }
  )
);
assert.deepStrictEqual(multiBar.barConfigs[0].rightWidgets, ["clock"]);
assert.deepStrictEqual(multiBar.barConfigs[1].rightWidgets, ["clock", "battery", "controlCenterButton"]);
assert.deepStrictEqual(multiBar.barConfigs[2].rightWidgets, ["clock"]);

// No anchor to sit ahead of -> appended rather than dropped.
const appended = clone(
  barWidgets.reconcile([{ id: "default", enabled: true, rightWidgets: ["clock"] }], [], { battery: true })
);
assert.deepStrictEqual(appended.barConfigs[0].rightWidgets, ["clock", "battery"]);

// Every bar disabled -> no target. Inserting into a bar that cannot render
// rewrites a layout the user deliberately turned off and shows them nothing.
const allBarsDisabled = [
  { id: "default", enabled: false, rightWidgets: ["clock", "controlCenterButton"] },
  { id: "second", enabled: false, rightWidgets: ["clock"] },
];
const allBarsDisabledBefore = clone(allBarsDisabled);
assert.strictEqual(barWidgets.targetBarIndex(allBarsDisabled), -1);
assert.strictEqual(
  barWidgets.reconcile(allBarsDisabled, [], { battery: true }),
  null,
  "a layout with no enabled bar has no reconciliation target"
);
assert.deepStrictEqual(
  allBarsDisabled,
  allBarsDisabledBefore,
  "reconciliation must not mutate a deliberately disabled layout"
);
assert.strictEqual(barWidgets.targetBarIndex([]), -1);
assert.strictEqual(barWidgets.targetBarIndex(null), -1);

// Enabling a bar later is all it takes: reconciliation runs on every load.
const oneBarReEnabled = clone(
  barWidgets.reconcile(
    [
      { id: "default", enabled: false, rightWidgets: ["clock", "controlCenterButton"] },
      { id: "second", enabled: true, rightWidgets: ["clock", "controlCenterButton"] },
    ],
    [],
    { battery: true }
  )
);
assert.deepStrictEqual(oneBarReEnabled.barConfigs[0].rightWidgets, ["clock", "controlCenterButton"]);
assert.deepStrictEqual(oneBarReEnabled.barConfigs[1].rightWidgets, ["clock", "battery", "controlCenterButton"]);

// A v19 config migrates and reconciles in the same load, but the migration can
// only be written once the asynchronous writability check answers. Deferred
// load steps -- reconciliation, icon-theme drift -- can save in that window, so
// committing a payload captured at parse time would revert them, and because
// that write bypasses _selfWrite the reload would put the reverted values back
// in memory. SettingsData therefore holds only a flag and serializes current
// state at commit time, which is correct under either completion ordering.
function qmlFunctionBody(name) {
  const start = settingsDataSource.indexOf(`function ${name}(`);
  assert(start >= 0, `SettingsData.qml should define ${name}`);
  const end = settingsDataSource.indexOf("\n    }", start);
  assert(end > start, `${name} should be a closed function body`);
  return settingsDataSource.slice(start, end);
}

assert(
  /property\s+bool\s+_pendingMigrationWrite\s*:\s*false/.test(settingsDataSource),
  "the pending migration should be tracked by a flag, not a held payload"
);
assert(
  /_pendingMigration(?!Write)/.test(settingsDataSource) === false,
  "SettingsData.qml must not reintroduce a held migration payload; there would be nothing to keep it in sync"
);

const writableCheckBody = qmlFunctionBody("_onWritableCheckComplete");
assert(
  /if\s*\(_pendingMigrationWrite\)\s*\n\s*saveSettings\(\);/.test(writableCheckBody),
  "the migration must be committed by serializing current state, not a captured payload"
);
assert(
  writableCheckBody.indexOf("settingsFile.setText") < 0,
  "_onWritableCheckComplete must not write settings.json directly; saveSettings() is what keeps _selfWrite and the snapshot honest"
);

// With the payload gone, reconciliation just saves like any other mutation.
const reconcileBody = qmlFunctionBody("reconcileHardwareBarWidgets");
assert(
  reconcileBody.indexOf("updateBarConfigs()") >= 0,
  "reconciliation should persist through the ordinary save path"
);

// Reconciliation finds no target while every bar is disabled, so enabling or
// adding a bar has to re-run it -- otherwise the user enables a bar and gets no
// battery indicator until the next shell start, which is the VGS-61 symptom.
// The gate reads the enabled count BEFORE the mutation, so it fires only on the
// none -> some transition and never during an ordinary widget-list edit.
const barVisibilityGate = qmlFunctionBody("_reconcileIfBarsBecameVisible");
assert(
  barVisibilityGate.indexOf("if (hadEnabledBar || getEnabledBarConfigs().length === 0)") >= 0,
  "the re-run must be gated on the no-enabled-bar -> some-enabled-bar transition"
);
assert(
  barVisibilityGate.indexOf("Qt.callLater(reconcileHardwareBarWidgets)") >= 0,
  "the re-run should be deferred so it lands after the caller's update settles"
);

for (const fn of ["addBarConfig", "updateBarConfig"]) {
  const body = qmlFunctionBody(fn);
  const captured = body.indexOf("const hadEnabledBar = getEnabledBarConfigs().length > 0;");
  const rerun = body.indexOf("_reconcileIfBarsBecameVisible(hadEnabledBar)");
  assert(captured >= 0, `${fn} must record whether any bar was enabled before it mutates barConfigs`);
  assert(rerun > captured, `${fn} must re-run reconciliation after the mutation, or a newly visible bar stays empty`);
  assert(
    captured < body.indexOf("barConfigs = configs;"),
    `${fn} must read the enabled count before the mutation, or the transition is never detected`
  );
}

// v21 (VGS-21): the two surviving spotlight keys are RENAMED, not dropped, so
// the assertions have to prove the value arrived — `assertMissing` alone would
// pass for a migration that simply deleted them, which is the failure mode the
// valid-key filter produces for free.
const spotlightRenameMigrated = migrate({
  configVersion: 19,
  spotlightCloseNiriOverview: false,
  spotlightSectionViewModes: { apps: "grid", files: "list" },
});
assertMissing(spotlightRenameMigrated, [
  "spotlightCloseNiriOverview",
  "spotlightSectionViewModes",
]);
assert.strictEqual(
  spotlightRenameMigrated.overviewSearchCloseNiriOverview,
  false,
  "a non-default spotlightCloseNiriOverview must survive the rename"
);
assert.deepStrictEqual(
  spotlightRenameMigrated.overviewSearchSectionViewModes,
  { apps: "grid", files: "list" },
  "spotlightSectionViewModes values must survive the rename"
);

// A config already carrying the new name must win over a stale old-name value,
// rather than being clobbered by it.
const spotlightRenameNoClobber = migrate({
  configVersion: 19,
  spotlightCloseNiriOverview: true,
  overviewSearchCloseNiriOverview: false,
});
assert.strictEqual(
  spotlightRenameNoClobber.overviewSearchCloseNiriOverview,
  false,
  "an existing new-key value must not be overwritten by the old key"
);

// The rename must not invent a value for a user who never set the old key —
// SPEC defaults are what should apply.
const spotlightRenameAbsent = migrate({ configVersion: 19 });
assertMissing(spotlightRenameAbsent, [
  "spotlightCloseNiriOverview",
  "spotlightSectionViewModes",
]);
assert.strictEqual(
  Object.prototype.hasOwnProperty.call(
    spotlightRenameAbsent,
    "overviewSearchCloseNiriOverview"
  ),
  false,
  "an unset old key must not materialise the new key"
);

assert.strictEqual(
  store.migrateToVersion({ configVersion: TARGET_VERSION }, TARGET_VERSION),
  null,
  "current-version settings should not be rewritten"
);

// --- Assignments in the settings singletons must target declared properties --
//
// VGS-23: SessionData.clearLauncherHistory() assigned `launcherSearchHistory`,
// which is declared nowhere. In QML that is not a parse error — it fails at
// runtime — so qmllint and qml-smoke both passed it, and the function had no
// caller, so nothing ever executed the broken line. The failure would also have
// landed mid-way: launcherLastQuery blanked, saveSettings() never reached.
//
// These two singletons are where that class of typo is most expensive (they own
// every persisted key), and both scan clean, so the check is scoped to them
// rather than the whole tree — a repo-wide version would need an allowlist, and
// an allowlist is how a real finding gets waved through.
//
// LIMITS, so the next reader does not over-trust it: whole-file declaration
// scope, not per-function. A name declared as a local in one function counts as
// declared everywhere in that file, so this cannot catch a genuine
// cross-function leak. What it does catch is the assignment that names nothing
// at all, which is the bug that shipped.
const sessionDataPath = path.join(repoRoot, "quickshell", "vshell", "Common", "SessionData.qml");

// Comments dropped and string bodies blanked in ONE pass. Sequential regexes
// are not safe here: an earlier draft of this check used
// `.replace(/\/\*[\s\S]*?\*\//g, "")` and a `/*` inside a string literal
// swallowed 38 KB of SettingsData.qml, which silently hid every declaration in
// the gap and produced 31 false positives. Newlines inside skipped regions are
// preserved so reported line numbers stay true.
function scrubQml(src) {
  let out = "";
  for (let i = 0; i < src.length; ) {
    const c = src[i];
    const d = src[i + 1];
    if (c === "/" && d === "/") {
      while (i < src.length && src[i] !== "\n") i++;
      continue;
    }
    if (c === "/" && d === "*") {
      i += 2;
      while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) {
        if (src[i] === "\n") out += "\n";
        i++;
      }
      i += 2;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      const quote = c;
      i++;
      out += '""';
      while (i < src.length && src[i] !== quote) {
        if (src[i] === "\\") i++;
        if (src[i] === "\n") out += "\n";
        i++;
      }
      i++;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

function undeclaredAssignments(source) {
  const text = scrubQml(source);
  const declared = new Set();
  const collect = (re) => {
    for (const m of text.matchAll(re)) declared.add(m[1]);
  };
  collect(
    /\b(?:readonly\s+)?property\s+(?:alias\s+)?(?:var|int|real|bool|string|double|color|point|rect|size|date|list\s*<[^>]*>|[A-Za-z][\w.]*)\s+([A-Za-z_$][\w$]*)/g
  );
  collect(/\b(?:let|var|const)\s+([A-Za-z_$][\w$]*)/g);
  collect(/\bid:\s*([A-Za-z_$][\w$]*)/g);
  collect(/\bsignal\s+([A-Za-z_$][\w$]*)/g);
  collect(/\bfunction\s+([A-Za-z_$][\w$]*)/g);
  // Parameters count as declared: they are assignable names in scope.
  for (const m of text.matchAll(/\bfunction\s+[A-Za-z_$][\w$]*\s*\(([^)]*)\)/g))
    for (const param of m[1].split(",")) {
      const name = param.trim().split(/[=\s]/)[0];
      if (name) declared.add(name);
    }
  for (const m of text.matchAll(/(?:\(([^()]*)\)|([A-Za-z_$][\w$]*))\s*=>/g))
    for (const param of (m[1] ?? m[2] ?? "").split(",")) {
      const name = param.trim().split(/[=\s]/)[0];
      if (name) declared.add(name);
    }

  const findings = [];
  text.split("\n").forEach((line, index) => {
    // Indented bare-identifier assignment: `foo = ...`, never `foo == ...`,
    // `foo => ...`, or a qualified `a.foo = ...` (the leading \s+ and the
    // identifier anchor together exclude those).
    const m = line.match(/^\s+([A-Za-z_$][\w$]*)\s*=(?!=|>)\s*\S/);
    if (m && !declared.has(m[1])) findings.push(`${m[1]} (line ${index + 1})`);
  });
  return findings;
}

for (const file of [sessionDataPath, settingsDataPath]) {
  assert.deepStrictEqual(
    undeclaredAssignments(fs.readFileSync(file, "utf8")),
    [],
    `${path.basename(file)} assigns a property it never declares; ` +
      "in QML that throws at runtime rather than failing to parse"
  );
}

console.log("Settings migration smoke tests passed.");
