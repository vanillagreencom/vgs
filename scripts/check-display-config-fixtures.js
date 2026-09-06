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
