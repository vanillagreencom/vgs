#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');

const utilPath = path.join(__dirname, '..', 'quickshell', 'vshell', 'Common', 'DisplayProfileUtils.js');
const src = fs.readFileSync(utilPath, 'utf8');
const utils = new Function(`${src}\nreturn {\n  getOutputIdentifier,\n  getHyprlandOutputIdentifier,\n  modeString,\n  modeIndexForConfig,\n  profileKeyMatchesOutput,\n  matchingOutputNames,\n  configEntryMatchesOutputs,\n  configEntryMatchesLiveLayout\n};`)();

function output(overrides = {}) {
  return {
    make: 'Dell',
    model: 'U2723QE',
    serial: 'ABC123',
    enabled: true,
    modes: [
      { width: 3840, height: 2160, refresh_rate: 59997 },
      { width: 2560, height: 1440, refresh_rate: 143981 },
    ],
    current_mode: 1,
    logical: { x: 0, y: 0, scale: 1.25, transform: 'Normal' },
    ...overrides,
  };
}

const dp1 = output();
const hdmi = output({ serial: 'XYZ999', logical: { x: 2048, y: 0, scale: 1, transform: 'Normal' } });

assert.equal(utils.getOutputIdentifier(dp1, 'DP-1', 'name', 'hyprland'), 'DP-1');
assert.equal(utils.getOutputIdentifier(dp1, 'DP-1', 'model', 'hyprland'), 'Dell U2723QE');
assert.equal(utils.getOutputIdentifier(dp1, 'DP-1', 'model', 'niri'), 'Dell U2723QE ABC123');
assert.equal(utils.getHyprlandOutputIdentifier(dp1, 'DP-1', 'model', false), 'desc:Dell U2723QE ABC123');

assert.equal(utils.profileKeyMatchesOutput('DP-1', dp1, 'DP-1', 'name', 'hyprland'), true);
assert.equal(utils.profileKeyMatchesOutput('Dell U2723QE', dp1, 'DP-1', 'model', 'hyprland'), true);
assert.equal(utils.profileKeyMatchesOutput('desc:Dell U2723QE ABC123', dp1, 'DP-1', 'name', 'hyprland'), true);
assert.equal(utils.profileKeyMatchesOutput('desc:Dell U2723QE', dp1, 'DP-1', 'name', 'hyprland'), true);
assert.equal(utils.profileKeyMatchesOutput('desc:Dell U2723QE Unknown', output({ serial: '' }), 'DP-2', 'name', 'hyprland'), true);
assert.equal(utils.profileKeyMatchesOutput('desc:LG UltraFine', dp1, 'DP-1', 'name', 'hyprland'), false);

const outputs = { 'DP-1': dp1, 'HDMI-A-1': hdmi };
assert.equal(utils.configEntryMatchesOutputs({ outputs: { 'DP-1': {}, 'HDMI-A-1': {} } }, outputs, 'name', 'hyprland'), true);
assert.equal(utils.configEntryMatchesOutputs({ outputs: { 'desc:Dell U2723QE ABC123': {}, 'desc:Dell U2723QE XYZ999': {} } }, outputs, 'name', 'hyprland'), true);
assert.equal(utils.configEntryMatchesOutputs({ outputs: { 'desc:Dell U2723QE': {}, 'HDMI-A-1': {} } }, outputs, 'name', 'hyprland'), false, 'ambiguous model-only desc must not auto-match duplicate monitors');

const matchingLayout = {
  outputs: {
    'desc:Dell U2723QE ABC123': {
      mode: '2560x1440@143.981',
      position: { x: 0, y: 0 },
      scale: 1.25,
      transform: 'Normal',
    },
  },
};
assert.equal(utils.configEntryMatchesLiveLayout(matchingLayout, outputs, 'name', 'hyprland'), true);
assert.equal(utils.configEntryMatchesLiveLayout({ outputs: { 'DP-1': { ...matchingLayout.outputs['desc:Dell U2723QE ABC123'], scale: 1 } } }, outputs, 'name', 'hyprland'), false);
assert.equal(utils.configEntryMatchesLiveLayout({ outputs: { 'DP-1': { ...matchingLayout.outputs['desc:Dell U2723QE ABC123'], position: { x: 10, y: 0 } } } }, outputs, 'name', 'hyprland'), false);
assert.equal(utils.configEntryMatchesLiveLayout({ outputs: { 'DP-1': { disabled: true } } }, { 'DP-1': output({ enabled: false }) }, 'name', 'hyprland'), true);
assert.equal(utils.configEntryMatchesLiveLayout({ outputs: { 'DP-1': { disabled: true } } }, { 'DP-1': output({ enabled: true }) }, 'name', 'hyprland'), false);

assert.equal(utils.modeString({ width: 2560, height: 1440, refresh_rate: 143981 }), '2560x1440@143.981');
assert.equal(utils.modeIndexForConfig(dp1.modes, '2560x1440@143.981'), 1);
assert.equal(utils.modeIndexForConfig(dp1.modes, '1920x1080@240.000'), -1, 'unknown configured mode stays explicit instead of silently falling back to preferred');

console.log('Display config fixture tests passed.');

const controlsSource = fs.readFileSync(path.join(__dirname, '..', 'quickshell/vshell/Modules/Settings/DisplayConfig/DisplaySettingsLogic.js'), 'utf8');
const controls = new Function(`${controlsSource}\nreturn {brightnessDeviceName, previewScales, displayName};`)();
const appleDevices = [
  {name: 'apple-xdr', class: 'apple', label: 'Apple Pro Display XDR'},
  {name: 'apple-studio', class: 'apple', label: 'Apple Studio Display'},
];
assert.equal(controls.brightnessDeviceName('DP-1', {model: 'ProDisplayXDR'}, appleDevices), 'apple-xdr');
assert.equal(controls.brightnessDeviceName('DP-2', {model: 'StudioDisplay'}, appleDevices), 'apple-studio');
assert.equal(controls.brightnessDeviceName('DP-3', {model: 'Unknown'}, appleDevices), '');
assert.equal(controls.brightnessDeviceName('DP-2', {model: 'StudioDisplay'}, appleDevices, 'missing'), '', 'a disconnected pin must not control another monitor');
assert.equal(controls.brightnessDeviceName('DP-2', {model: 'StudioDisplay'}, [...appleDevices, {...appleDevices[1], name: 'second-studio'}]), '', 'duplicate models require an explicit assignment');
assert.equal(controls.brightnessDeviceName('DP-2', {model: 'StudioDisplay'}, appleDevices, 'apple-xdr'), 'apple-xdr');
assert.equal(controls.brightnessDeviceName('DP-2', {}, [{name: 'ddc', class: 'ddc', connector: 'DP-2'}]), 'ddc');
assert.equal(controls.displayName({model: 'StudioDisplay'}, 'DP-2'), 'Studio Display');
const scales = controls.previewScales([1, 4 / 3, 1.6, 2, 2.5, 8 / 3, 3.2, 4], 2);
assert.equal(scales.length, 5);
assert(scales.includes(2));
assert(scales.every((scale, index) => index === 0 || scale < scales[index - 1]));
assert(controls.previewScales([1, 2, 3], 1.5).includes(1.5));
console.log('Display selection and brightness matching tests passed.');

const { extractBlock } = require('./lib/qml-block.js');
const stateSource = fs.readFileSync(path.join(__dirname, '..', 'quickshell/vshell/Modules/Settings/DisplayConfig/DisplayConfigState.qml'), 'utf8');
const serviceSource = fs.readFileSync(path.join(__dirname, '..', 'quickshell/vshell/Services/HyprlandService.qml'), 'utf8');
const buildSnapshot = new Function('state', 'with (state) {' + extractBlock(stateSource, 'function buildOutputsWithPendingChanges()') + '}');
const normalize = new Function('outputsData', extractBlock(stateSource, 'function normalizeOutputPositions(outputsData)'));
const saved = { 'DP-9': output({ logical: { x: -4096, y: 0, scale: 1, transform: 'Normal' } }) };
const pending = { 'DP-1': { scale: 2 } };
const snapshot = buildSnapshot({ savedOutputs: saved, outputs, pendingChanges: pending, normalizeOutputPositions: normalize, CompositorService: { isHyprland: true } });
let sent;
function applySnapshot(data, settings, displayNameMode, source = serviceSource) {
  new Function('outputsData', 'settings', 'callback', 'preview', 'SettingsData', 'outputsCommand',
      extractBlock(source, 'function generateOutputsConfig(outputsData, settings, callback, preview = false)'))(
      data, settings, null, true, { displayNameMode }, (action, args) => { sent = JSON.parse(args[0]); });
  return sent;
}
applySnapshot(snapshot, {}, 'name');
assert.deepEqual(Object.keys(sent.outputs).sort(), Object.keys(outputs).sort(), 'offline saved rules must not enter a live apply');
assert.equal(sent.outputs['DP-1'].logical.x, 0, 'offline positions must not move the live layout');
assert.equal(sent.outputs['DP-1'].logical.scale, 2);
assert.deepEqual(sent.preserve, ['DP-9']);
assert.equal(saved['DP-9'].logical.x, -4096, 'the saved setup is retained');
assert.equal(outputs['DP-1'].logical.scale, 1.25, 'pending changes must not mutate the original snapshot');

const generateProfile = new Function('configEntry', 'outputs', 'SettingsData', 'CompositorService', 'DisplayProfileUtils', 'savedOutputs',
    extractBlock(stateSource, 'function generateOutputsDataFromConfig(configEntry)'));
const profileSettings = new Function('configEntry', 'outputs', 'SettingsData', 'CompositorService', 'DisplayProfileUtils',
    extractBlock(stateSource, 'function getHyprlandSettingsFromConfig(configEntry)'));
for (const [key, naming] of [['DP-1', 'name'], ['Dell U2723QE', 'model'], ['desc:Dell U2723QE ABC123', 'model']]) {
  const profile = { outputs: { [key]: { mode: '2560x1440@143.981', scale: 1.25, hyprland: { colorManagement: 'dp3', bitdepth: 10 } },
    'DP-9': { mode: '2560x1440@143.981', scale: 1 } } };
  const original = JSON.stringify(profile);
  const args = [profile, { 'DP-1': dp1 }, { displayNameMode: naming }, { isHyprland: true, compositor: 'hyprland' }, utils, saved];
  const data = generateProfile(...args);
  const settings = profileSettings(...args);
  const sentProfile = applySnapshot(data, settings, naming);
  assert.deepEqual(Object.keys(sentProfile.outputs), ['DP-1'], key);
  assert.equal(sentProfile.outputs['DP-1'].connected, true);
  assert.equal(sentProfile.outputs['DP-1'].explicitIdentifier, true);
  assert.deepEqual(sentProfile.preserve, ['DP-9']);
  assert.equal(sentProfile.settings['DP-1'].colorManagement, 'dp3', 'profile settings follow the resolved connector');
  assert.equal(sentProfile.settings['DP-1'].bitdepth, 10);
  assert.equal(JSON.stringify(profile), original, 'applying cannot remove offline saved outputs');
  const unfiltered = serviceSource.replace('outputsData[name].connected !== false', 'true');
  assert.notEqual(unfiltered, serviceSource);
  assert.throws(() => assert.deepEqual(Object.keys(applySnapshot(data, settings, naming, unfiltered).outputs), ['DP-1']), assert.AssertionError);
}

const applyProfileBody = extractBlock(stateSource, 'function applyConfigEntry(configEntry, configId, profileName, isManual)');
const applyProfile = new Function('context', 'configEntry', 'isManual', 'with (context) {' + applyProfileBody + '}');
for (const [key, ambiguous, isManual] of [
  ['Dell U2723QE', true, true], ['desc:Dell U2723QE', true, false],
  ['DP-1', false, true], ['desc:Dell U2723QE ABC123', false, false], ['DP-9', false, true]
]) {
  const profile = { outputs: { [key]: { mode: '2560x1440@143.981', scale: 1.25 },
    'eDP-1': { mode: '2560x1440@143.981', scale: 1.25 } } };
  const liveOutputs = { 'DP-1': dp1, 'DP-2': hdmi, 'eDP-1': output({ make: 'Built-in', model: 'Panel' }) };
  const errors = [];
  let writes = 0;
  const context = {
    root: { lastAppliedEntry: null }, outputs: liveOutputs, DisplayProfileUtils: utils,
    SettingsData: { displayNameMode: 'model' }, CompositorService: { isHyprland: true, compositor: 'hyprland' },
    readOnly: false, profilesLoading: true, manualActivation: isManual,
    I18n: { tr: text => ({ arg: value => text.replace('%1', value) }) },
    profileError: error => errors.push(error),
    ensureEnabledOutput: new Function('configEntry', extractBlock(stateSource, 'function ensureEnabledOutput(configEntry)')),
    generateOutputsDataFromConfig: entry => generateProfile(entry, liveOutputs, { displayNameMode: 'model' }, { isHyprland: true, compositor: 'hyprland' }, utils, saved),
    backendSettingsFromConfig: entry => profileSettings(entry, liveOutputs, { displayNameMode: 'model' }, { compositor: 'hyprland' }, utils),
    backendWriteOutputsConfig: () => writes++
  };
  applyProfile(context, profile, isManual);
  assert.equal(writes, ambiguous ? 0 : 1, key);
  assert.equal(errors.length, ambiguous ? 1 : 0, key);
  if (ambiguous) {
    assert.equal(context.root.lastAppliedEntry, null, 'a rejected setup must not replace applied state');
    assert.equal(context.profilesLoading, false);
    assert.equal(context.manualActivation, false);
  }
}

const startup = new Function('generateLayoutConfig', 'requestOutputs', extractBlock(serviceSource, 'Component.onCompleted:'));
let requests = 0;
startup(() => {}, () => requests++);
assert.equal(requests, 1, 'service startup must recover previews before Settings opens');
const noRecovery = extractBlock(serviceSource, 'Component.onCompleted:').replace('requestOutputs();', '');
assert.notEqual(noRecovery, extractBlock(serviceSource, 'Component.onCompleted:'));
let missingRequests = 0;
new Function('generateLayoutConfig', 'requestOutputs', noRecovery)(() => {}, () => missingRequests++);
assert.throws(() => assert.equal(missingRequests, 1), assert.AssertionError);
const readiness = new Function('root', extractBlock(serviceSource, 'function onIsHyprlandChanged()'));
readiness({ requestOutputs: () => requests++ });
assert.equal(requests, 2, 'late compositor detection must request recovery');

for (const action of ['confirm', 'failed-confirm', 'revert']) {
  let persisted = 'system';
  const context = { CompositorService: { isHyprland: true },
    HyprlandService: { outputPreviewToken: 'preview', finishOutputPreview: (keep, callback) => {
      context.HyprlandService.outputPreviewToken = '';
      callback(action !== 'failed-confirm');
    } },
    SettingsData: { displayNameMode: 'model', hyprlandOutputSettings: {}, saveSettings: () => persisted = context.SettingsData.displayNameMode },
    formatChanged: true, originalDisplayNameMode: 'system', outputs, pendingChanges: {}, pendingHyprlandChanges: {}, pendingNiriChanges: {},
    originalOutputs: null, originalNiriSettings: null, originalHyprlandSettings: null, lastAppliedEntry: null,
    buildCurrentOutputConfigs: () => ({}), readMonitorsJson: callback => callback({}),
    findConfigEntryByFingerprint: () => null, currentOutputSet: [], changesConfirmed: () => {}, changesReverted: () => {} };
  for (const name of ['clearPendingChanges', 'commitHyprlandSettingsChanges', 'revertChanges']) {
    const body = extractBlock(stateSource, `function ${name}()`);
    context[name] = () => new Function('context', 'with (context) {' + body + '}')(context);
  }
  const confirmBody = extractBlock(stateSource, 'function confirmChanges(profileId)');
  context.confirmChanges = profileId => new Function('context', 'profileId', 'with (context) {' + confirmBody + '}')(context, profileId);
  if (action === 'revert')
    context.revertChanges();
  else
    context.confirmChanges();
  assert.equal(persisted, action === 'confirm' ? 'model' : 'system', 'format-only ' + action);
  if (action === 'revert')
    assert.equal(context.SettingsData.displayNameMode, 'system');
}

const readQml = relative => fs.readFileSync(path.join(__dirname, '..', 'quickshell/vshell', relative), 'utf8');
const fontApply = new Function('context', 'who', 'key', 'oldValue', 'with (context) {' + extractBlock(readQml('Common/SettingsData.qml'), 'function applySystemFonts(') + '}');
for (const key of [undefined, 'systemFontInterfaceHinting', 'systemFontSize']) {
  let command;
  fontApply({ isGreeterMode: false, updateCompositorLayout: () => {}, Paths: { vshellCli: '/fixture/vshell' },
    Proc: { runCommand: (_name, args) => command = args } }, null, key, 11);
  assert.equal(command.includes('--size-only'), key === 'systemFontSize', 'only a size edit claims size ownership');
}
const testedPinFiles = new Set();
function readPinSource(file) {
  testedPinFiles.add(file);
  return readQml(file);
}
const pinSources = [
  ['Modules/Settings/DisplayConfig/DisplayBrightness.qml', 'readonly property string pinKey:'],
  ['Modules/ControlCenter/Details/BrightnessDetail.qml', 'function getScreenPinKey()'],
  ['Modules/Bar/Widgets/ControlCenterButton.qml', 'function getScreenPinKey()']
];
for (const [file, opener] of pinSources) {
  const source = readPinSource(file);
  const tail = source.slice(source.indexOf(opener) + opener.length).trimStart();
  const body = tail.startsWith('{') ? extractBlock(source, opener) : 'return ' + tail.split('\n')[0] + ';';
  const pinKey = new Function('context', 'with (context) {' + body + '}');
  for (const [displayNameMode, left] of [['name', 'DP-1'], ['model', 'DP-1'], ['model', 'DP-5']]) {
    const screens = [{ name: 'DP-1', model: 'ProDisplayXDR' }, { name: 'DP-5', model: 'ProDisplayXDR' }];
    for (const screen of screens) {
      const context = { outputName: screen.name, screenName: screen.name, screenModel: screen.model,
        root: { screenName: screen.name, screenModel: screen.model }, Quickshell: { screens },
        SettingsData: { displayNameMode, getScreenDisplayName: s => displayNameMode === 'name' ? s.name : s.model + (s.name === left ? '-0' : '-1') } };
      assert.equal(pinKey(context), screen.name, file + ' must not follow labels or arrangement');
    }
  }
}
const focusedPin = new Function('context', 'with (context) {' + extractBlock(readPinSource('Services/DisplayService.qml'), 'function getPinnedDeviceForFocusedScreen()') + '}');
for (const [connected, expected] of [[true, 'apple-one'], [false, '']]) {
  const context = { CompositorService: { getFocusedScreen: () => ({ name: 'DP-1', model: 'ProDisplayXDR' }) },
    SettingsData: { brightnessDevicePins: { 'DP-1': 'apple-one', 'ProDisplayXDR-0': 'apple-two' }, getScreenDisplayName: () => 'ProDisplayXDR-0' },
    devices: connected ? [{ id: 'apple-one' }] : [{ id: 'apple-two' }] };
  assert.equal(focusedPin(context), expected, 'focused-screen brightness must use its connector and reject an absent pinned device');
}

const embeddedPin = new Function('context', 'with (context) {' + extractBlock(readPinSource('Modules/ControlCenter/Widgets/BrightnessSliderRow.qml'), 'property string targetDeviceName:') + '}');
for (const [displayNameMode, left] of [['name', 'DP-1'], ['model', 'DP-1'], ['model', 'DP-5']]) {
  const screens = [{ name: 'DP-1', model: 'ProDisplayXDR' }, { name: 'DP-5', model: 'ProDisplayXDR' }];
  for (const screen of screens) {
    const pins = { 'DP-1': 'apple-one', 'DP-5': 'apple-two' };
    const context = { screenName: screen.name, deviceName: '', Quickshell: { screens },
      SettingsData: { brightnessDevicePins: pins, getScreenDisplayName: s => displayNameMode === 'name' ? s.name : s.model + (s.name === left ? '-0' : '-1') },
      DisplayService: { brightnessAvailable: true, currentDevice: 'fallback',
        devices: [{ name: 'fallback', class: 'apple' }, { name: 'apple-one', class: 'apple' }, { name: 'apple-two', class: 'apple' }] } };
    assert.equal(embeddedPin(context), pins[screen.name], 'embedded slider must retain its connector assignment');
  }
}

const qmlRoot = path.join(__dirname, '..', 'quickshell/vshell');
const { stripComments } = require('./lib/qml-source.js');
const pinReferences = fs.readdirSync(qmlRoot, { recursive: true }).filter(file => /\.(qml|js)$/.test(file)).filter(file => {
  const source = stripComments(readQml(file))
      .replace(/^\s*property var brightnessDevicePins:\s*\(\{\}\)\s*$/m, '')
      .replace(/^\s*brightnessDevicePins:\s*\{ def: \{\} \},?\s*$/m, '');
  return /\bbrightnessDevicePins\b/.test(source);
}).sort();
assert.deepEqual([...testedPinFiles].sort(), pinReferences, 'every runtime brightness pin reference needs a behavioral fixture');
const omittedConsumer = [...testedPinFiles].filter(file => file !== 'Services/DisplayService.qml').sort();
assert.throws(() => assert.deepEqual(omittedConsumer, pinReferences), assert.AssertionError, 'an incomplete fixture inventory must fail');

for (const [file, action] of [['DisplayPicker.qml', 'root.selected(modelData)'], ['DisplayScalePicker.qml', 'choose()']]) {
  const source = readQml('Modules/Settings/DisplayConfig/' + file);
  const handler = source.match(/^\s*Accessible\.onPressAction:\s*(.+)$/m);
  assert.ok(handler, file + ' must expose the assistive press action');
  let selected;
  new Function('root', 'modelData', 'choose', handler[1])({ selected: value => selected = value }, 'DP-1', () => selected = 'scale');
  assert.equal(selected, action === 'choose()' ? 'scale' : 'DP-1');
}
