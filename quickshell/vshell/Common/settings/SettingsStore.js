.pragma library

    .import "./SettingsSpec.js" as SpecModule

function parse(root, jsonObj) {
    var SPEC = SpecModule.SPEC;

    if (!jsonObj) return;

    for (var k in SPEC) {
        if (k === "pluginSettings") continue;
        // Runtime-only keys are never in the JSON; resetting them here
        // would wipe values set by detection processes on every reload.
        if (SPEC[k].persist === false) continue;
        if (!(k in jsonObj)) {
            root[k] = SPEC[k].def;
        }
    }

    for (var k in jsonObj) {
        if (!SPEC[k]) continue;
        if (k === "pluginSettings") continue;
        var raw = jsonObj[k];
        var spec = SPEC[k];
        var coerce = spec.coerce;
        root[k] = coerce ? (coerce(raw) !== undefined ? coerce(raw) : root[k]) : raw;
    }
}

function toJson(root) {
    var SPEC = SpecModule.SPEC;
    var out = {};
    for (var k in SPEC) {
        if (SPEC[k].persist === false) continue;
        if (k === "pluginSettings") continue;
        out[k] = root[k];
    }
    out.configVersion = root.settingsConfigVersion;
    return out;
}

function migrateToVersion(obj, targetVersion) {
    if (!obj) return null;

    var settings = JSON.parse(JSON.stringify(obj));
    var currentVersion = settings.configVersion || 0;

    if (currentVersion >= targetVersion) {
        return null;
    }

    if (currentVersion < 2) {
        console.info("Migrating settings from version", currentVersion, "to version 2");

        if (settings.barConfigs === undefined) {
            function singleBarValue(suffix, fallback) {
                var key = "bar" + suffix;
                if (settings[key] !== undefined)
                    return settings[key];
                return fallback;
            }

            var position = 0;
            if (singleBarValue("AtBottom", settings.topBarAtBottom) !== undefined) {
                var atBottom = singleBarValue("AtBottom", settings.topBarAtBottom);
                position = atBottom ? 1 : 0;
            } else if (singleBarValue("Position", undefined) !== undefined) {
                position = singleBarValue("Position", 0);
            }

            var defaultConfig = {
                id: "default",
                name: "Main Bar",
                enabled: true,
                position: position,
                screenPreferences: ["all"],
                showOnLastDisplay: true,
                leftWidgets: singleBarValue("LeftWidgets", ["launcherButton", "workspaceSwitcher", "focusedWindow"]),
                centerWidgets: singleBarValue("CenterWidgets", ["music", "clock", "weather"]),
                rightWidgets: singleBarValue("RightWidgets", ["systemTray", "clipboard", "cpuUsage", "memUsage", "notificationButton", "battery", "controlCenterButton"]),
                spacing: singleBarValue("Spacing", 4),
                innerPadding: singleBarValue("InnerPadding", 4),
                bottomGap: singleBarValue("BottomGap", 0),
                transparency: singleBarValue("Transparency", 1.0),
                widgetTransparency: singleBarValue("WidgetTransparency", 1.0),
                squareCorners: singleBarValue("SquareCorners", false),
                noBackground: singleBarValue("NoBackground", false),
                gothCornersEnabled: singleBarValue("GothCornersEnabled", false),
                gothCornerRadiusOverride: singleBarValue("GothCornerRadiusOverride", false),
                gothCornerRadiusValue: singleBarValue("GothCornerRadiusValue", 12),
                borderEnabled: singleBarValue("BorderEnabled", false),
                borderColor: singleBarValue("BorderColor", "surfaceText"),
                borderOpacity: singleBarValue("BorderOpacity", 1.0),
                borderThickness: singleBarValue("BorderThickness", 1),
                fontScale: singleBarValue("FontScale", 1.0),
                autoHide: singleBarValue("AutoHide", false),
                autoHideDelay: singleBarValue("AutoHideDelay", 250),
                openOnOverview: singleBarValue("OpenOnOverview", false),
                visible: singleBarValue("Visible", true),
                popupGapsAuto: settings.popupGapsAuto !== undefined ? settings.popupGapsAuto : true,
                popupGapsManual: settings.popupGapsManual !== undefined ? settings.popupGapsManual : 4
            };

            settings.barConfigs = [defaultConfig];

            var singleBarSuffixes = [
                "LeftWidgets", "CenterWidgets", "RightWidgets",
                "WidgetOrder", "AutoHide", "AutoHideDelay",
                "OpenOnOverview", "Visible", "Spacing",
                "BottomGap", "InnerPadding", "Position",
                "SquareCorners", "NoBackground", "GothCornersEnabled",
                "GothCornerRadiusOverride", "GothCornerRadiusValue",
                "BorderEnabled", "BorderColor", "BorderOpacity",
                "BorderThickness", "AtBottom", "Transparency", "WidgetTransparency"
            ];

            for (var i = 0; i < singleBarSuffixes.length; i++) {
                delete settings["bar" + singleBarSuffixes[i]];
            }
            delete settings.topBarAtBottom;
            delete settings.popupGapsAuto;
            delete settings.popupGapsManual;

            console.info("Migrated single bar settings to barConfigs");
        }

        settings.configVersion = 2;
    }

    if (currentVersion < 3) {
        console.info("Migrating settings from version", currentVersion, "to version 3");
        console.info("Per-widget controlCenterButton config now supported via widgetData properties");
        settings.configVersion = 3;
    }

    if (currentVersion < 4) {
        console.info("Migrating settings from version", currentVersion, "to version 4");
        console.info("Migrating desktop widgets to unified desktopWidgetInstances");

        var instances = [];

        if (settings.desktopClockEnabled) {
            var clockPositions = {};
            if (settings.desktopClockX !== undefined && settings.desktopClockX >= 0) {
                clockPositions["default"] = {
                    x: settings.desktopClockX,
                    y: settings.desktopClockY,
                    width: settings.desktopClockWidth || 280,
                    height: settings.desktopClockHeight || 180
                };
            }

            instances.push({
                id: "dw_clock_primary",
                widgetType: "desktopClock",
                name: "Desktop Clock",
                enabled: true,
                config: {
                    style: settings.desktopClockStyle || "analog",
                    transparency: settings.desktopClockTransparency !== undefined ? settings.desktopClockTransparency : 0.8,
                    colorMode: settings.desktopClockColorMode || "primary",
                    customColor: settings.desktopClockCustomColor || "#ffffff",
                    showDate: settings.desktopClockShowDate !== false,
                    showAnalogNumbers: settings.desktopClockShowAnalogNumbers || false,
                    showAnalogSeconds: settings.desktopClockShowAnalogSeconds !== false,
                    displayPreferences: settings.desktopClockDisplayPreferences || ["all"]
                },
                positions: clockPositions
            });
        }

        if (settings.systemMonitorEnabled) {
            var sysmonPositions = {};
            if (settings.systemMonitorX !== undefined && settings.systemMonitorX >= 0) {
                sysmonPositions["default"] = {
                    x: settings.systemMonitorX,
                    y: settings.systemMonitorY,
                    width: settings.systemMonitorWidth || 320,
                    height: settings.systemMonitorHeight || 480
                };
            }

            instances.push({
                id: "dw_sysmon_primary",
                widgetType: "systemMonitor",
                name: "System Monitor",
                enabled: true,
                config: {
                    showHeader: settings.systemMonitorShowHeader !== false,
                    transparency: settings.systemMonitorTransparency !== undefined ? settings.systemMonitorTransparency : 0.8,
                    colorMode: settings.systemMonitorColorMode || "primary",
                    customColor: settings.systemMonitorCustomColor || "#ffffff",
                    showCpu: settings.systemMonitorShowCpu !== false,
                    showCpuGraph: settings.systemMonitorShowCpuGraph !== false,
                    showCpuTemp: settings.systemMonitorShowCpuTemp !== false,
                    showGpuTemp: settings.systemMonitorShowGpuTemp || false,
                    gpuPciId: settings.systemMonitorGpuPciId || "",
                    showMemory: settings.systemMonitorShowMemory !== false,
                    showMemoryGraph: settings.systemMonitorShowMemoryGraph !== false,
                    showNetwork: settings.systemMonitorShowNetwork !== false,
                    showNetworkGraph: settings.systemMonitorShowNetworkGraph !== false,
                    showDisk: settings.systemMonitorShowDisk !== false,
                    showTopProcesses: settings.systemMonitorShowTopProcesses || false,
                    topProcessCount: settings.systemMonitorTopProcessCount || 3,
                    topProcessSortBy: settings.systemMonitorTopProcessSortBy || "cpu",
                    layoutMode: settings.systemMonitorLayoutMode || "auto",
                    graphInterval: settings.systemMonitorGraphInterval || 60,
                    displayPreferences: settings.systemMonitorDisplayPreferences || ["all"]
                },
                positions: sysmonPositions
            });
        }

        var variants = settings.systemMonitorVariants || [];
        for (var i = 0; i < variants.length; i++) {
            var v = variants[i];
            instances.push({
                id: v.id,
                widgetType: "systemMonitor",
                name: v.name || ("System Monitor " + (i + 2)),
                enabled: true,
                config: v.config || {},
                positions: v.positions || {}
            });
        }

        settings.desktopWidgetInstances = instances;
        settings.configVersion = 4;
    }

    if (currentVersion < 5) {
        console.info("Migrating settings from version", currentVersion, "to version 5");
        console.info("Moving sensitive data (weather location, coordinates) to session.json");

        delete settings.weatherLocation;
        delete settings.weatherCoordinates;

        settings.configVersion = 5;
    }

    if (currentVersion < 6) {
        console.info("Migrating settings from version", currentVersion, "to version 6");

        if (settings.barElevationEnabled === undefined) {
            var bars = Array.isArray(settings.barConfigs) ? settings.barConfigs : [];
            var hadPerBarShadowEnabled = false;
            for (var j = 0; j < bars.length; j++) {
                var shadowIntensity = Number(bars[j] && bars[j].shadowIntensity);
                if (!isNaN(shadowIntensity) && shadowIntensity > 0) {
                    hadPerBarShadowEnabled = true;
                    break;
                }
            }
            settings.barElevationEnabled = hadPerBarShadowEnabled;
        }

        settings.configVersion = 6;
    }

    if (currentVersion < 11) {
        settings.configVersion = 11;
    }

    if (currentVersion < 12) {
        console.info("Migrating settings from version", currentVersion, "to version 12");
        // VGS matugenTemplate* toggles become the themeApps map. The old values
        // only expressed intent when the VGS matugen pipeline was actually on;
        // otherwise we drop them and let app detection pick defaults.
        var matugenToApp = {
            matugenTemplateGtk: "gtk", matugenTemplateHyprland: "hyprland",
            matugenTemplateQt5ct: "qt5ct", matugenTemplateQt6ct: "qt6ct",
            matugenTemplateGhostty: "ghostty", matugenTemplateKitty: "kitty",
            matugenTemplateFoot: "foot", matugenTemplateNeovim: "neovim",
            matugenTemplateAlacritty: "alacritty", matugenTemplateWezterm: "wezterm",
            matugenTemplateKcolorscheme: "kcolorscheme", matugenTemplateVscode: "vscode",
            matugenTemplateEmacs: "emacs", matugenTemplateZed: "zed"
        };
        var runTemplatesKey = "runVgsMatugenTemplates";
        if (settings.themeApps === undefined && settings[runTemplatesKey] === true) {
            var themeApps = {};
            for (var mk in matugenToApp) {
                if (typeof settings[mk] === "boolean")
                    themeApps[matugenToApp[mk]] = settings[mk];
            }
            settings.themeApps = themeApps;
        }
        var vgsKeys = Object.keys(settings);
        for (var di = 0; di < vgsKeys.length; di++) {
            var dk = vgsKeys[di];
            if (dk.indexOf("matugenTemplate") === 0 || dk === runTemplatesKey || dk === "runUserMatugenTemplates")
                delete settings[dk];
        }
        settings.configVersion = 12;
    }

    if (currentVersion < 14) {
        // Legacy theme-registry keys; nothing consumed them under VGS packages.
        delete settings.customThemeFile;
        delete settings.registryThemeVariants;
        settings.configVersion = 14;
    }

    if (currentVersion < 15) {
        console.info("Migrating settings from version", currentVersion, "to version 15");
        if (settings.surfaceBorderWidth === undefined)
            settings.surfaceBorderWidth = 1;
        if (settings.surfaceGeometryTarget === undefined) {
            var shellRadius = Number(settings.cornerRadius !== undefined ? settings.cornerRadius : 15);
            var hyprRadius = Number(settings.hyprlandLayoutRadiusOverride);
            var hyprBorder = Number(settings.hyprlandLayoutBorderSize);
            settings.surfaceGeometryTarget = ((!isNaN(hyprRadius) && hyprRadius >= 0 && Math.round(hyprRadius) !== Math.round(shellRadius)) || (!isNaN(hyprBorder) && hyprBorder >= 0)) ? "hyprland" : "sync";
        }
        if (settings.hyprlandResizeOnBorder === false)
            settings.hyprlandResizeOnBorder = true;
        settings.configVersion = 15;
    }

    if (currentVersion < 16) {
        console.info("Migrating settings from version", currentVersion, "to version 16");
        console.info("Replacing the retired systemUpdate bar widget with the VGS sysUpdate widget");

        var barConfigs = Array.isArray(settings.barConfigs) ? settings.barConfigs : [];
        var widgetSections = ["leftWidgets", "centerWidgets", "rightWidgets"];
        for (var bi = 0; bi < barConfigs.length; bi++) {
            var bar = barConfigs[bi];
            if (!bar)
                continue;

            var hasNewUpdater = false;
            for (var si = 0; si < widgetSections.length; si++) {
                var existingWidgets = Array.isArray(bar[widgetSections[si]]) ? bar[widgetSections[si]] : [];
                for (var wi = 0; wi < existingWidgets.length; wi++) {
                    var existingId = typeof existingWidgets[wi] === "string" ? existingWidgets[wi] : existingWidgets[wi]?.id;
                    if (existingId === "sysUpdate")
                        hasNewUpdater = true;
                }
            }

            for (var sj = 0; sj < widgetSections.length; sj++) {
                var sectionName = widgetSections[sj];
                var widgets = Array.isArray(bar[sectionName]) ? bar[sectionName] : [];
                var migratedWidgets = [];
                for (var wj = 0; wj < widgets.length; wj++) {
                    var widget = widgets[wj];
                    var widgetId = typeof widget === "string" ? widget : widget?.id;
                    if (widgetId !== "systemUpdate") {
                        migratedWidgets.push(widget);
                        continue;
                    }
                    if (hasNewUpdater)
                        continue;
                    if (typeof widget === "string")
                        migratedWidgets.push("sysUpdate");
                    else
                        migratedWidgets.push(Object.assign({}, widget, { id: "sysUpdate" }));
                    hasNewUpdater = true;
                }
                bar[sectionName] = migratedWidgets;
            }
        }

        delete settings.updaterHideWidget;
        delete settings.updaterUseCustomCommand;
        delete settings.updaterCustomCommand;
        delete settings.updaterTerminalAdditionalParams;
        delete settings.updaterIncludeFlatpak;
        delete settings.updaterAllowAUR;
        settings.configVersion = 16;
    }

    if (currentVersion < 17) {
        console.info("Migrating settings from version", currentVersion, "to version 17");
        console.info("New idle default: idle -> lock -> blank-to-black; no auto monitor-off");
        // Turn off auto monitor power-off only when still on the old shipped 600s
        // default (a deliberately-customized value is preserved). Add the new
        // blank-to-black keys if absent.
        if (settings.acMonitorTimeout === 600)
            settings.acMonitorTimeout = 0;
        if (settings.lockScreenBlankEnabled === undefined)
            settings.lockScreenBlankEnabled = true;
        if (settings.lockScreenBlankTimeout === undefined)
            settings.lockScreenBlankTimeout = 300;
        settings.configVersion = 17;
    }

    if (currentVersion < 18) {
        console.info("Migrating settings from version", currentVersion, "to version 18");
        console.info("Finish the no-auto-monitor-off default (v17 only zeroed the 600s value; older configs shipped 630s)");
        var legacyMonitorDefaults = [600, 630];
        if (legacyMonitorDefaults.indexOf(settings.acMonitorTimeout) >= 0)
            settings.acMonitorTimeout = 0;
        if (legacyMonitorDefaults.indexOf(settings.batteryMonitorTimeout) >= 0)
            settings.batteryMonitorTimeout = 0;
        settings.configVersion = 18;
    }

    if (currentVersion < 19) {
        console.info("Migrating settings from version", currentVersion, "to version 19");
        console.info("Retiring the legacy grid launcher; the vgsMenu plugin is the only app launcher");
        // These keys only ever configured the removed launcher modal, app
        // drawer popout and spotlight bar. The valid-key filter below would
        // drop them anyway; deleting them here keeps the intent on the record.
        delete settings.showLauncherButton;
        delete settings.appLauncherViewMode;
        delete settings.spotlightModalViewMode;
        delete settings.appDrawerSectionViewModes;
        delete settings.launcherUnloadOnClose;
        delete settings.launcherUseOverlayLayer;
        delete settings.launcherStyle;
        delete settings.spotlightBarShowModeChips;
        delete settings.rememberLastMode;
        delete settings.rememberLastQuery;
        settings.configVersion = 19;
    }

    var validKeys = SpecModule.getValidKeys();
    var filtered = {};
    for (var key in settings) {
        if (validKeys.indexOf(key) >= 0)
            filtered[key] = settings[key];
    }
    filtered.configVersion = targetVersion;

    return filtered;
}

function cleanup(fileText) {
    var getValidKeys = SpecModule.getValidKeys;
    if (!fileText || !fileText.trim()) return;

    try {
        var settings = JSON.parse(fileText);
        var validKeys = getValidKeys();
        var needsSave = false;

        for (var key in settings) {
            if (validKeys.indexOf(key) < 0) {
                delete settings[key];
                needsSave = true;
            }
        }

        return needsSave ? JSON.stringify(settings, null, 2) : null;
    } catch (e) {
        console.warn("SettingsData: Failed to cleanup unused keys:", e.message);
        return null;
    }
}
