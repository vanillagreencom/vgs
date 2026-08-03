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

const TARGET_VERSION = 19;

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

assert.strictEqual(
  store.migrateToVersion({ configVersion: TARGET_VERSION }, TARGET_VERSION),
  null,
  "current-version settings should not be rewritten"
);

console.log("Settings migration smoke tests passed.");
