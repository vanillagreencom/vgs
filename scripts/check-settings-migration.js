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

const TARGET_VERSION = 24;

// Anchor the seed and test version to the runtime migration version.
// Comparing only test constants can leave a new runtime migration untested.
const runtimeConfigVersion = (() => {
  const match = settingsDataSource.match(/readonly\s+property\s+int\s+settingsConfigVersion\s*:\s*(\d+)/);
  assert(match, "SettingsData.qml should declare settingsConfigVersion");
  return Number(match[1]);
})();

assert.deepStrictEqual(
  {
    "SettingsData.qml settingsConfigVersion": runtimeConfigVersion,
    "settings.default.json configVersion": defaultSettings.configVersion,
    "check-settings-migration.js TARGET_VERSION": TARGET_VERSION,
  },
  {
    "SettingsData.qml settingsConfigVersion": runtimeConfigVersion,
    "settings.default.json configVersion": runtimeConfigVersion,
    "check-settings-migration.js TARGET_VERSION": runtimeConfigVersion,
  },
  "schema version disagreement: the runtime authority is SettingsData.qml's " +
    "settingsConfigVersion; whichever value differs above must be brought up to it " +
    "(append a migration, never renumber)"
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
  "notificationFirstRunTakeoverDone",
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

// removedBarWidgets distinguishes explicit removal from a widget never present in the configuration.
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


const reconciled = clone(barWidgets.reconcile(clone(desktopConfigOnALaptop.barConfigs), [], { battery: true }));
assert(reconciled, "a battery-less config on a laptop should be reconciled");
assert.deepStrictEqual(reconciled.added, ["battery"]);
assert.deepStrictEqual(reconciled.barConfigs[0].rightWidgets, [
  "systemTray",
  "cpuUsage",
  "battery",
  "controlCenterButton",
]);

// Explicit widget removal must survive reconciliation.
assert.strictEqual(
  barWidgets.reconcile(clone(desktopConfigOnALaptop.barConfigs), ["battery"], { battery: true }),
  null,
  "a widget the user removed must never come back"
);


assert.strictEqual(
  barWidgets.reconcile(clone(desktopConfigOnALaptop.barConfigs), [], { battery: false }),
  null,
  "a machine without a battery must not grow a battery widget"
);

// A disabled widget or a widget in another section still counts as present.
assert.strictEqual(
  barWidgets.reconcile(
    [{ id: "default", enabled: true, leftWidgets: [{ id: "battery", enabled: false }], rightWidgets: [] }],
    [],
    { battery: true }
  ),
  null,
  "a disabled battery widget is still a decision the user made"
);


assert.strictEqual(
  barWidgets.reconcile(reconciled.barConfigs, [], { battery: true }),
  null,
  "reconciliation must not keep adding the widget on every load"
);


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


const appended = clone(
  barWidgets.reconcile([{ id: "default", enabled: true, rightWidgets: ["clock"] }], [], { battery: true })
);
assert.deepStrictEqual(appended.barConfigs[0].rightWidgets, ["clock", "battery"]);

// Disabled bars provide no visible target and must retain their configured layout.
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

// Writability is checked asynchronously. Reconciliation can save while migration waits,
// so the deferred commit must serialize current settings instead of a parse-time payload.
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


const reconcileBody = qmlFunctionBody("reconcileHardwareBarWidgets");
assert(
  reconcileBody.indexOf("updateBarConfigs()") >= 0,
  "reconciliation should persist through the ordinary save path"
);

// Enabling the first bar must rerun reconciliation or its battery widget waits until shell restart.
// Ordinary edits to an enabled bar must not trigger that transition.
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

// Assert the renamed value arrives. A missing-key assertion alone also accepts deletion.
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

// An existing destination key takes precedence over the old key.
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

// Absent old keys must use schema defaults instead of invented migration values.
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

// Fresh installs start with takeover unspent. Existing configurations must mark it spent,
// including configurations that disabled VGS notifications.
const firstRunTakeoverMigrated = migrate({ configVersion: 21 });
assert.strictEqual(
  firstRunTakeoverMigrated.notificationFirstRunTakeoverDone,
  true,
  "an existing config is not a first run; the takeover one-shot must arrive spent"
);
assert.strictEqual(
  spec.SPEC.notificationFirstRunTakeoverDone.def,
  false,
  "the seed default must stay false, or a fresh install would never take the name"
);
// Old configurations traverse intermediate migrations and must also arrive with takeover spent.
assert.strictEqual(
  migrate({ configVersion: 1 }).notificationFirstRunTakeoverDone,
  true,
  "an ancient config is still not a first run"
);
// The explicit notification opt-out must survive migration.
assert.strictEqual(
  migrate({ configVersion: 21, notificationServerEnabled: false }).notificationServerEnabled,
  false,
  "the notification opt-out must survive the update that adds the takeover"
);

assert.strictEqual(
  store.migrateToVersion({ configVersion: TARGET_VERSION }, TARGET_VERSION),
  null,
  "current-version settings should not be rewritten"
);

// Check bare assignments in settings singletons against whole-file declarations.
// This catches names declared nowhere. It cannot detect a local name used from another function.
const sessionDataPath = path.join(repoRoot, "quickshell", "vshell", "Common", "SessionData.qml");

// Scan comments and strings together so a comment delimiter inside a string cannot hide code.
// Preserve newlines for diagnostics. A slash can begin a regex where a value is expected;
// after a value it represents division.
const VALUE_KEYWORDS = new Set([
  "return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
  "throw", "case", "do", "else", "yield", "await",
]);

function regexCanStartHere(out) {
  let j = out.length - 1;
  while (j >= 0 && /\s/.test(out[j])) j--;
  if (j < 0) return true;
  const ch = out[j];

  // Postfix ++ and -- end an expression. Their following slash represents division.
  if ((ch === "+" || ch === "-") && out[j - 1] === ch) return false;

  // A closing brace can end a block or an object literal. This character scanner cannot distinguish them.
  // It treats a same-line slash pair after a closing brace as a regex, which can hide object division.
  if ("(,=:[!&|?{};+-*%~^<>".includes(ch)) return true;

  if (ch === ")" || ch === "]") return false;
  // Quotes remain after string bodies are blanked, so the closing quote marks a completed value.
  if (ch === '"' || ch === "'" || ch === "`") return false;
  if (!/[\w$]/.test(ch)) return false;
  let k = j;
  while (k >= 0 && /[\w$]/.test(out[k])) k--;
  return VALUE_KEYWORDS.has(out.slice(k + 1, j + 1));
}

function scrubQml(src) {
  let out = "";
  for (let i = 0; i < src.length; ) {
    const c = src[i];
    const d = src[i + 1];

    // Skip complete regex literals so an embedded quote cannot desynchronize string scanning.
    if (c === "/" && d !== "/" && d !== "*" && regexCanStartHere(out)) {
      let j = i + 1;
      let inClass = false;
      let closed = false;
      while (j < src.length) {
        const ch = src[j];
        if (ch === "\\") {
          j += 2;
          continue;
        }
        if (ch === "\n") break;
        if (ch === "[") inClass = true;
        else if (ch === "]") inClass = false;
        else if (ch === "/" && !inClass) {
          closed = true;
          break;
        }
        j++;
      }
      if (closed) {
        j++;
        while (j < src.length && /[a-z]/.test(src[j])) j++; // Use a placeholder without an identifier or equals sign so it cannot create a false assignment.
        out += "0";
        i = j;
        continue;
      }

    }

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
    // Match indented bare assignments while excluding equality, arrow functions, and qualified names.
    const m = line.match(/^\s+([A-Za-z_$][\w$]*)\s*=(?!=|>)\s*\S/);
    if (m && !declared.has(m[1])) findings.push(`${m[1]} (line ${index + 1})`);
  });
  return findings;
}

// Scratchpad migration must not adopt compositor-owned pads and create competing rule owners.
const scratchpadsMigrated = migrate({ configVersion: 22 });
assert.deepStrictEqual(
  scratchpadsMigrated.scratchpads,
  [],
  "scratchpads must be seeded empty, never imported from the compositor"
);

// Existing scratchpads are user content and must retain their keys and values.
const existingScratchpads = migrate({
  configVersion: 22,
  scratchpads: [{ id: "term", name: "Terminal", command: "ghostty", keybind: "SUPER, T" }],
});
assert.deepStrictEqual(existingScratchpads.scratchpads, [
  { id: "term", name: "Terminal", command: "ghostty", keybind: "SUPER, T" },
]);

// Run the migration chain from one configuration and require both results.
// Separate checks can miss a version collision that skips a step for existing users.
for (const from of [1, 19, 21, 22]) {
  const walked = migrate({ configVersion: from });
  assert.strictEqual(
    walked.configVersion,
    24,
    `a v${from} config must land on the current schema version`
  );
  assert.deepStrictEqual(
    walked.scratchpads,
    [],
    `a v${from} config must arrive with the v23 scratchpads key`
  );
  // Earlier configurations must acquire takeover state; configurations at that step retain their value.
  if (from < 22)
    assert.strictEqual(
      walked.notificationFirstRunTakeoverDone,
      true,
      `a v${from} config must also arrive with the v22 takeover one-shot spent`
    );
}


const bothSteps = migrate({
  configVersion: 21,
  scratchpads: [{ id: "keep", command: "x", classRegex: "^x$" }],
});
assert.strictEqual(bothSteps.notificationFirstRunTakeoverDone, true);
assert.deepStrictEqual(bothSteps.scratchpads, [{ id: "keep", command: "x", classRegex: "^x$" }]);

// The launcher view migration preserves the app grid choice and supplies a default when absent.
const collapsedViewMode = migrate({
  configVersion: 23,
  launcherMenuViewModes: { apps: "grid", files: "list", folders: "list" },
});
assert.strictEqual(collapsedViewMode.configVersion, 24);
assert.strictEqual(collapsedViewMode.launcherMenuViewMode, "grid");
assert.strictEqual(collapsedViewMode.launcherMenuViewModes, undefined);
assert.strictEqual(migrate({ configVersion: 23 }).launcherMenuViewMode, undefined);

for (const file of [sessionDataPath, settingsDataPath]) {
  assert.deepStrictEqual(
    undeclaredAssignments(fs.readFileSync(file, "utf8")),
    [],
    `${path.basename(file)} assigns a property it never declares; ` +
      "in QML that throws at runtime rather than failing to parse"
  );
}

console.log("Settings migration smoke tests passed.");
