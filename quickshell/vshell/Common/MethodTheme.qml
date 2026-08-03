pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("MethodTheme")

    readonly property string defaultFontFamily: "Inter Variable"
    readonly property string defaultMonoFontFamily: "Fira Code"

    // Both default families load once here from the bundled, relocatable assets
    // tree, so a fresh install renders correctly with no system font packages
    // and no distro-specific paths, and every consumer (StyledText,
    // StyledTextMetrics) renders and measures with the same face. The mono face
    // is the same Fira Code build VgsNFIcon already ships, so this costs no
    // extra bytes in the package.
    FontLoader {
        id: bundledFontLoader
        source: Qt.resolvedUrl("../assets/fonts/inter/InterVariable.ttf")
    }

    FontLoader {
        id: bundledMonoFontLoader
        source: Qt.resolvedUrl("../assets/fonts/nerd-fonts/FiraCodeNerdFont-Regular.ttf")
    }

    // A FontLoader that has not resolved yields an empty family name, which
    // silently drops the family; fall back to the default family name so Qt
    // falls back through a real family rather than through "".
    readonly property string bundledFontName: bundledFontLoader.name || defaultFontFamily
    readonly property string bundledMonoFontName: bundledMonoFontLoader.name || defaultMonoFontFamily
    readonly property string homeDir: Paths.strip(StandardPaths.writableLocation(StandardPaths.HomeLocation))
    readonly property string configDir: Paths.strip(StandardPaths.writableLocation(StandardPaths.ConfigLocation))
    readonly property string shellDir: Paths.strip(Qt.resolvedUrl(".").toString()).replace("/Common/", "")
    readonly property bool isGreeterMode: Quickshell.env("VSHELL_RUN_GREETER") === "1" || Quickshell.env("VSHELL_RUN_GREETER") === "true"
    readonly property string _greeterCacheDir: Quickshell.env("VSHELL_GREET_CFG_DIR") || "/var/cache/vshell-greeter"
    readonly property string _desktopThemePath: homeDir + "/.config/vshell/theme.json"
    property string greeterThemeBaseDir: _greeterCacheDir
    readonly property string themePath: isGreeterMode ? (greeterThemeBaseDir + "/theme.json") : _desktopThemePath

    property var methodThemeJson: ({})
    property bool colorsFileLoadFailed: false
    property string currentTheme: "coppernight"
    property string currentThemeCategory: "vgs"
    property bool isLightMode: (methodThemeJson.mode || "dark") === "light"
    readonly property string dynamic: "vgs"
    readonly property string custom: "vgs-theme"
    property bool matugenAvailable: false
    property bool gtkThemingEnabled: false
    property bool qtThemingEnabled: false

    readonly property var fallbackColors: ({
        "primary": "#fab387",
        "primaryText": "#000000",
        "secondary": "#94e2d5",
        "tertiary": "#cba6f7",
        "surface": "#11111b",
        "surfaceText": "#cdd6f4",
        "surfaceVariant": "#1c1c2c",
        "surfaceVariantText": "#8b91a8",
        "surfaceTint": "#fab387",
        "background": "#11111b",
        "backgroundText": "#cdd6f4",
        "outline": "#6b7083",
        "outlineVariant": "#4d5060",
        "surfaceContainerLowest": "#11111b",
        "surfaceContainerLow": "#171725",
        "surfaceContainer": "#1c1c2c",
        "surfaceContainerHigh": "#232338",
        "surfaceContainerHighest": "#2c2c46",
        "primaryContainer": "#57423b",
        "secondaryContainer": "#304348",
        "tertiaryContainer": "#3e3550",
        "muted": "#8b91a8",
        "dim": "#7d8294",
        "error": "#ff6b6b",
        "errorContainer": "#41232b",
        "warning": "#fbbf24",
        "warningContainer": "#40341d",
        "info": "#60a5fa",
        "infoContainer": "#212f48",
        "success": "#5bd77a",
        "successContainer": "#20392e",
        "statusBg": "#2c2c46",
        "statusFg": "#cdd6f4",
        "statusMuted": "#9196ac",
        "statusAccent": "#fab387",
        "statusError": "#ff6b6b",
        "statusWarning": "#fbbf24",
        "statusSuccess": "#5bd77a",
        "statusInfo": "#60a5fa",
        "groupbarActiveBg": "#fab387",
        "groupbarActiveFg": "#000000",
        "groupbarInactiveBg": "#2c2c46",
        "groupbarInactiveFg": "#cdd6f4",
        "groupbarLockedBg": "#fab387",
        "groupbarLockedFg": "#000000"
    })

    function _colors() {
        return methodThemeJson.colors || ({});
    }

    function _color(name, fallbackName) {
        const colors = _colors();
        const fallbackKey = fallbackName || name;
        return colors[name] || fallbackColors[fallbackKey] || fallbackColors[name] || "#ff00ff";
    }

    function _blendHex(a, b, r) {
        function toRgb(hex) {
            const h = String(hex || "#000000").replace("#", "");
            return [parseInt(h.slice(0, 2), 16) || 0, parseInt(h.slice(2, 4), 16) || 0, parseInt(h.slice(4, 6), 16) || 0];
        }
        function toHex(v) { return Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, "0"); }
        const ca = toRgb(a);
        const cb = toRgb(b);
        return "#" + toHex(ca[0] * (1 - r) + cb[0] * r) + toHex(ca[1] * (1 - r) + cb[1] * r) + toHex(ca[2] * (1 - r) + cb[2] * r);
    }

    // Flatline neutral-surface mode: pull the neutral surface family (background,
    // surface, containers, outline) toward luminance-matched gray so surfaces read
    // as a shadcn "zinc/slate" base, while accent (primary/secondary) and status
    // colors keep their chroma. 0 = original palette, 1 = fully desaturated. This
    // is the single knob for how neutral the shell reads. See design-language.md.
    readonly property real flatlineNeutralAmount: 0.12
    function _neutral(c) {
        const col = (typeof c === "string") ? Qt.color(c) : c;
        if (root.flatlineNeutralAmount <= 0 || !col || col.r === undefined)
            return col;
        const gray = 0.299 * col.r + 0.587 * col.g + 0.114 * col.b;
        const a = root.flatlineNeutralAmount;
        return Qt.rgba(col.r * (1 - a) + gray * a, col.g * (1 - a) + gray * a, col.b * (1 - a) + gray * a, col.a);
    }

    readonly property var currentThemeData: ({
        "name": methodThemeJson.name || "vgs-theme",
        "primary": _color("accent", "primary"),
        "primaryText": _colors().onPrimary || _colors().selectionForeground || fallbackColors.primaryText,
        "primaryContainer": _color("primaryContainer"),
        "secondary": _color("cyan", "secondary"),
        "secondaryContainer": _color("secondaryContainer"),
        "tertiary": _color("magenta", "tertiary"),
        "tertiaryContainer": _color("tertiaryContainer"),
        "surface": _color("surface", "background"),
        "surfaceText": _color("foreground", "surfaceText"),
        "surfaceVariant": _color("surfaceVariant", "surfaceVariant"),
        "surfaceVariantText": _color("muted", "surfaceVariantText"),
        "surfaceTint": _color("accent", "primary"),
        "background": _color("background"),
        "backgroundText": _color("foreground", "backgroundText"),
        "outline": _color("outline"),
        "outlineVariant": _color("outlineVariant"),
        "surfaceContainerLowest": _color("surfaceContainerLowest"),
        "surfaceContainerLow": _color("surfaceContainerLow"),
        "surfaceContainer": _color("surfaceContainer"),
        "surfaceContainerHigh": _color("surfaceContainerHigh"),
        "surfaceContainerHighest": _color("surfaceContainerHighest"),
        "error": _color("error"),
        "errorContainer": _color("errorContainer"),
        "warning": _color("warning"),
        "warningContainer": _color("warningContainer"),
        "info": _color("info"),
        "infoContainer": _color("infoContainer"),
        "success": _color("success"),
        "successContainer": _color("successContainer")
    })

    readonly property string currentThemeName: currentThemeData.name || "coppernight"

    Component.onCompleted: {
        Quickshell.execDetached(["mkdir", "-p", homeDir + "/.config/vshell"]);
        themeFileView.reload();
    }

    property color primary: currentThemeData.primary
    property color primaryText: currentThemeData.primaryText
    property color secondary: currentThemeData.secondary
    property color tertiary: currentThemeData.tertiary || currentThemeData.secondary
    // Neutral surface family (Flatline): lightly desaturated toward gray via
    // _neutral() so surfaces keep the theme's hue but read a touch calmer.
    property color surface: _neutral(currentThemeData.surface)
    property color surfaceText: currentThemeData.surfaceText
    property color surfaceVariant: _neutral(currentThemeData.surfaceVariant)
    property color surfaceVariantText: currentThemeData.surfaceVariantText
    property color surfaceTint: currentThemeData.surfaceTint
    property color background: _neutral(currentThemeData.background)
    property color backgroundText: currentThemeData.backgroundText
    property color outline: _neutral(currentThemeData.outline)
    property color outlineVariant: _neutral(currentThemeData.outlineVariant) || withAlpha(outline, 0.6)
    property color surfaceContainerLowest: _neutral(currentThemeData.surfaceContainerLowest) || blend(surfaceContainer, surface, 1.2)
    property color surfaceContainerLow: _neutral(currentThemeData.surfaceContainerLow) || blend(surface, surfaceContainer, 0.667)
    property color surfaceContainer: _neutral(currentThemeData.surfaceContainer)
    property color surfaceContainerHigh: _neutral(currentThemeData.surfaceContainerHigh)
    property color surfaceContainerHighest: _neutral(currentThemeData.surfaceContainerHighest) || surfaceContainerHigh
    property color primaryContainer: currentThemeData.primaryContainer || blend(surfaceContainerHigh, primary, 0.45)
    property color secondaryContainer: currentThemeData.secondaryContainer || blend(surfaceContainerHigh, secondary, 0.35)
    property color tertiaryContainer: currentThemeData.tertiaryContainer || blend(surfaceContainerHigh, tertiary, 0.35)

    property color onSurface: surfaceText
    property color onSurfaceVariant: surfaceVariantText
    property color onPrimary: primaryText
    property color onSurface_12: withAlpha(onSurface, 0.12)
    property color onSurface_38: withAlpha(onSurface, 0.38)
    property color onSurfaceVariant_30: withAlpha(onSurfaceVariant, 0.30)

    property color error: currentThemeData.error || "#F2B8B5"
    property color errorContainer: currentThemeData.errorContainer || _blendHex(error, background, 0.78)
    property color warning: currentThemeData.warning || "#FF9800"
    property color warningContainer: currentThemeData.warningContainer || _blendHex(warning, background, 0.78)
    property color info: currentThemeData.info || "#2196F3"
    property color infoContainer: currentThemeData.infoContainer || _blendHex(info, background, 0.78)
    property color success: currentThemeData.success || "#4CAF50"
    property color successContainer: currentThemeData.successContainer || _blendHex(success, background, 0.78)
    property color tempWarning: warning
    property color tempDanger: error

    property color primaryHover: withAlpha(primary, 0.12)
    property color primaryHoverLight: withAlpha(primary, transparentBlurLayers ? 0.12 : 0.08)
    property color primaryPressed: withAlpha(primary, transparentBlurLayers ? 0.24 : 0.16)
    property color primarySelected: withAlpha(primary, 0.3)
    property color primaryBackground: withAlpha(primary, 0.04)

    property color secondaryHover: withAlpha(secondary, 0.08)

    // Interaction washes. These are translucent OVERLAYS, meant for a control
    // that is transparent at rest (ghost rows, nav items). Assigning one as the
    // `color` of a control that is opaque at rest replaces its fill with an 8%
    // wash, so the element goes see-through on hover instead of lighting up —
    // use hoverOn()/pressedOn()/selectedOn() for those.
    readonly property real hoverOverlayAlpha: 0.08
    readonly property real pressedOverlayAlpha: 0.12
    readonly property real selectedOverlayAlpha: 0.15

    property color surfaceHover: withAlpha(surfaceVariant, hoverOverlayAlpha)
    property color surfacePressed: withAlpha(surfaceVariant, pressedOverlayAlpha)
    property color surfaceSelected: withAlpha(surfaceVariant, selectedOverlayAlpha)
    property color surfaceLight: withAlpha(surfaceVariant, transparentBlurLayers ? 0.3 : 0.1)
    property color surfaceVariantAlpha: withAlpha(surfaceVariant, 0.2)

    readonly property bool foregroundLayers: typeof SettingsData === "undefined" || (SettingsData.blurForegroundLayers ?? true)
    readonly property bool blurForegroundLayers: BlurService.enabled && foregroundLayers
    readonly property bool transparentBlurLayers: BlurService.enabled && !foregroundLayers
    readonly property bool popupGlassEffect: BlurService.enabled && (typeof SettingsData !== "undefined") && (SettingsData.popupGlassEffect ?? false)
    // Glass rim, modeled on Liquid Glass: intensity follows the surface normal
    // against a fixed top light — top edges brightest, a weaker secondary
    // glint on bottom edges, sides dim.
    readonly property color glassRimTopColor: withAlpha("#ffffff", isLightMode ? 0.70 : 0.45)
    readonly property color glassRimBottomColor: withAlpha("#ffffff", isLightMode ? 0.38 : 0.20)
    // Glass sheen: soft white illumination wash from the top, fading out by
    // mid-surface; only a whisper of shade at the bottom for depth.
    readonly property color glassSheenTopColor: withAlpha("#ffffff", isLightMode ? 0.22 : 0.12)
    readonly property color glassSheenBottomColor: withAlpha("#000000", isLightMode ? 0.03 : 0.06)
    // Content-bearing layers need a stronger tint than the surrounding glass.
    // Keep the user's transparency on the outer flyout while flooring cards,
    // dropdown panels, and menus so text never competes with the backdrop.
    readonly property real readableSurfaceAlpha: Math.max(popupTransparency, isLightMode ? 0.86 : 0.82)
    readonly property color readableSurface: withAlpha(surfaceContainer, readableSurfaceAlpha)
    readonly property color readableSurfaceHigh: withAlpha(surfaceContainerHigh, readableSurfaceAlpha)
    readonly property color floatingSurface: foregroundLayers ? readableSurface : withAlpha(readableSurface, 0)
    readonly property color floatingSurfaceHigh: foregroundLayers ? readableSurfaceHigh : withAlpha(readableSurfaceHigh, 0)
    readonly property color nestedSurface: floatingSurfaceHigh
    readonly property real blurLayerOutlineOpacity: Math.max(0, Math.min(1, typeof SettingsData === "undefined" ? 0.12 : (SettingsData.blurLayerOutlineOpacity ?? 0.12)))
    readonly property real layerOutlineOpacity: blurLayerOutlineOpacity
    readonly property int defaultSurfaceBorderWidth: 1
    readonly property int surfaceBorderWidth: typeof SettingsData === "undefined" || !SettingsData.surfaceGeometryAppliesToQuickshell ? defaultSurfaceBorderWidth : Math.max(0, Math.round(SettingsData.surfaceBorderWidth ?? defaultSurfaceBorderWidth))
    readonly property int layerOutlineWidth: layerOutlineOpacity > 0 ? 1 : 0
    property color surfaceTextHover: withAlpha(surfaceText, 0.08)
    property color surfaceTextAlpha: withAlpha(surfaceText, 0.3)

    function roleColor(mode) {
        switch (mode) {
        case "primary":
        case "pri":
            return primary;
        case "primaryContainer":
            return primaryContainer;
        case "secondary":
        case "sec":
            return secondary;
        case "secondaryContainer":
            return secondaryContainer;
        case "tertiary":
        case "ter":
            return tertiary;
        case "tertiaryContainer":
            return tertiaryContainer;
        case "surfaceText":
            return surfaceText;
        case "surfaceVariant":
            return surfaceVariant;
        case "s":
            return surface;
        case "scll":
            return surfaceContainerLowest;
        case "scl":
            return surfaceContainerLow;
        case "sc":
            return surfaceContainer;
        case "sch":
            return surfaceContainerHigh;
        case "schh":
            return surfaceContainerHighest;
        case "sth":
            return surfaceTextHover;
        case "error":
        case "err":
            return error;
        default:
            return withAlpha(surface, 0);
        }
    }
    property color surfaceTextLight: withAlpha(surfaceText, 0.06)
    // Over glass, translucent text compounds with the translucent surface, so
    // secondary/medium labels step up toward opaque (Apple uses vibrancy here).
    property color surfaceTextSecondary: withAlpha(surfaceText, popupGlassEffect ? 0.75 : 0.6)
    property color surfaceTextMedium: withAlpha(surfaceText, popupGlassEffect ? 0.85 : 0.7)
    function inputHintFor(backgroundColor) {
        if (!backgroundColor || backgroundColor.r === undefined)
            return surfaceVariantText;
        const luminance = backgroundColor.r * 0.2126
            + backgroundColor.g * 0.7152
            + backgroundColor.b * 0.0722;
        const hue = backgroundColor.hslHue >= 0 ? backgroundColor.hslHue : 0;
        const saturation = Math.max(0, backgroundColor.hslSaturation);
        const lightnessShift = luminance < 0.55 ? 0.28 : -0.28;
        const lightness = Math.max(0, Math.min(1, backgroundColor.hslLightness + lightnessShift));
        return Qt.hsla(hue, saturation, lightness, 1);
    }

    // Standard placeholder tone. Individual fields derive from their resolved
    // background so custom/theme surfaces retain their own hue.
    readonly property color inputHintText: inputHintFor(surfaceContainerHigh)

    property color outlineButton: withAlpha(outline, 0.5)
    property color outlineLight: withAlpha(outline, Math.min(1, layerOutlineOpacity * 0.625))
    property color outlineMedium: withAlpha(outline, layerOutlineOpacity)
    property color outlineStrong: withAlpha(outline, Math.min(1, layerOutlineOpacity * 1.5))
    property color outlineHeavy: withAlpha(outline, 0.2)

    // Opaque borders for settings/content surfaces. Unlike the alpha-based outline*
    // tokens above (kept translucent for blur/glass layers), these are solid 1px
    // lines that do not let underlying content bleed through.
    readonly property color borderColor: blend(surfaceContainerHigh, outline, 0.6)
    readonly property color borderColorStrong: outline
    // A nested row/tile that must read as slightly raised above the card it sits on
    // (e.g. list rows inside a settings card). Always at least as light as the card.
    readonly property color elevatedRowColor: surfaceContainerHighest
    // Muted outline used for secondary/outlined buttons — solid, low-emphasis.
    readonly property color secondaryOutline: blend(surfaceContainerHigh, outline, 0.9)

    // Flatline focus ring (shadcn-style keyboard focus). Primitives draw this as
    // a 2px accent ring when they hold keyboard focus. See design-language.md.
    readonly property color focusRing: withAlpha(primary, 0.55)
    readonly property int focusRingWidth: 2

    // Window border tokens — mirror Hyprland's native window decorations so vShell
    // windows/modals/applets read as first-class windows. bin/vshell-helper sets
    // Hyprland's col.active_border = accent and col.inactive_border = outline; the
    // live compositor confirms active=primary, inactive=outline. Keep these in sync
    // with that helper if the mapping ever changes.
    readonly property color windowBorderActive: primary
    readonly property color windowBorderInactive: outline
    readonly property int windowBorderWidth: 2
    // Opaque 1px separator for lists/dividers/group boundaries. Named
    // separatorColor to avoid colliding with the hairline(dpr) width helper.
    readonly property color separatorColor: blend(surfaceContainerHigh, outline, 0.4)

    property color errorHover: withAlpha(error, 0.12)
    property color errorPressed: withAlpha(error, 0.16)
    property color errorSelected: withAlpha(error, 0.3)
    property color warningHover: withAlpha(warning, 0.12)

    readonly property color ccTileActiveBg: {
        switch (SettingsData.controlCenterTileColorMode) {
        case "primaryContainer":
            return primaryContainer;
        case "secondary":
            return secondary;
        case "surfaceVariant":
            return surfaceVariant;
        default:
            return primary;
        }
    }

    // Flatline: legible inactive tiles — drop the old ≤0.24 cap so tiles read as
    // solid controls over the (glass) panel instead of nearly-invisible washes.
    readonly property color ccTileInactiveBg: transparentBlurLayers ? withAlpha(surfaceContainerHigh, 0.4) : (foregroundLayers ? withAlpha(surfaceContainerHigh, popupTransparency) : withAlpha(surfaceContainer, 0))
    readonly property color ccPillInactiveBg: transparentBlurLayers ? withAlpha(surfaceContainerHigh, 0.08) : nestedSurface
    readonly property color ccPillInactiveHoverBg: transparentBlurLayers ? withAlpha(primary, 0.10) : primaryPressed
    readonly property color ccSliderTrackColor: transparentBlurLayers ? surfaceText : surfaceContainerHigh
    readonly property real ccSliderTrackOpacity: transparentBlurLayers ? 0.18 : popupTransparency

    readonly property color ccTileActiveText: {
        switch (SettingsData.controlCenterTileColorMode) {
        case "primaryContainer":
            return primary;
        case "secondary":
            return surfaceText;
        case "surfaceVariant":
            return surfaceText;
        default:
            return primaryText;
        }
    }

    readonly property color ccTileInactiveIcon: {
        switch (SettingsData.controlCenterTileColorMode) {
        case "primaryContainer":
            return primary;
        case "secondary":
            return secondary;
        case "surfaceVariant":
            return surfaceText;
        default:
            return primary;
        }
    }

    readonly property color ccTileRing: {
        switch (SettingsData.controlCenterTileColorMode) {
        case "primaryContainer":
            return withAlpha(primary, 0.22);
        case "secondary":
            return withAlpha(surfaceText, 0.22);
        case "surfaceVariant":
            return withAlpha(surfaceText, 0.22);
        default:
            return withAlpha(primaryText, 0.22);
        }
    }

    readonly property color buttonBg: {
        switch (SettingsData.buttonColorMode) {
        case "primaryContainer":
            return primaryContainer;
        case "secondary":
            return secondary;
        case "surfaceVariant":
            return surfaceVariant;
        default:
            return primary;
        }
    }

    readonly property color buttonText: {
        switch (SettingsData.buttonColorMode) {
        case "primaryContainer":
            return primary;
        case "secondary":
            return surfaceText;
        case "surfaceVariant":
            return surfaceText;
        default:
            return primaryText;
        }
    }

    readonly property color buttonHover: {
        switch (SettingsData.buttonColorMode) {
        case "primaryContainer":
            return withAlpha(primary, 0.12);
        case "secondary":
            return withAlpha(surfaceText, 0.12);
        case "surfaceVariant":
            return withAlpha(surfaceText, 0.12);
        default:
            return primaryHover;
        }
    }

    readonly property color buttonPressed: {
        switch (SettingsData.buttonColorMode) {
        case "primaryContainer":
            return withAlpha(primary, 0.16);
        case "secondary":
            return withAlpha(surfaceText, 0.16);
        case "surfaceVariant":
            return withAlpha(surfaceText, 0.16);
        default:
            return primaryPressed;
        }
    }

    // Flatline: flatter shadows — surfaces lean on borders, not drop-shadows.
    property color shadowMedium: Qt.rgba(0, 0, 0, 0.05)
    property color shadowStrong: Qt.rgba(0, 0, 0, 0.18)

    readonly property bool elevationEnabled: typeof SettingsData !== "undefined" && (SettingsData.m3ElevationEnabled ?? true)
    readonly property real elevationBlurMax: typeof SettingsData !== "undefined" && SettingsData.m3ElevationIntensity !== undefined ? Math.min(128, Math.max(32, SettingsData.m3ElevationIntensity * 2)) : 64

    readonly property real _elevMult: typeof SettingsData !== "undefined" && SettingsData.m3ElevationIntensity !== undefined ? SettingsData.m3ElevationIntensity / 12 : 1
    readonly property real _opMult: typeof SettingsData !== "undefined" && SettingsData.m3ElevationOpacity !== undefined ? SettingsData.m3ElevationOpacity / 60 : 1
    function normalizeElevationDirection(direction) {
        switch (direction) {
        case "top":
        case "topLeft":
        case "topRight":
        case "bottom":
        case "bottomLeft":
        case "bottomRight":
        case "left":
        case "right":
        case "autoBar":
            return direction;
        default:
            return "top";
        }
    }

    readonly property string elevationLightDirection: {
        if (typeof SettingsData === "undefined" || !SettingsData.m3ElevationLightDirection)
            return "top";
        switch (SettingsData.m3ElevationLightDirection) {
        case "autoBar":
        case "top":
        case "topLeft":
        case "topRight":
        case "bottom":
            return SettingsData.m3ElevationLightDirection;
        default:
            return "top";
        }
    }
    readonly property real _elevDiagRatio: 0.55
    readonly property string _globalElevationDirForTokens: {
        const normalized = normalizeElevationDirection(elevationLightDirection);
        return normalized === "autoBar" ? "top" : normalized;
    }
    readonly property real _elevDirX: {
        switch (_globalElevationDirForTokens) {
        case "topLeft":
        case "bottomLeft":
        case "left":
            return 1;
        case "topRight":
        case "bottomRight":
        case "right":
            return -1;
        default:
            return 0;
        }
    }
    readonly property real _elevDirY: {
        switch (_globalElevationDirForTokens) {
        case "bottom":
        case "bottomLeft":
        case "bottomRight":
            return -1;
        case "left":
        case "right":
            return 0;
        default:
            return 1;
        }
    }
    readonly property real _elevDirXScale: (_globalElevationDirForTokens === "left" || _globalElevationDirForTokens === "right") ? 1 : _elevDiagRatio

    readonly property var elevationLevel1: ({
            blurPx: 4 * _elevMult,
            offsetX: 1 * _elevMult * _elevDirXScale * _elevDirX,
            offsetY: 1 * _elevMult * _elevDirY,
            spreadPx: 0,
            alpha: 0.12 * _opMult
        })
    readonly property var elevationLevel2: ({
            blurPx: 8 * _elevMult,
            offsetX: 4 * _elevMult * _elevDirXScale * _elevDirX,
            offsetY: 4 * _elevMult * _elevDirY,
            spreadPx: 0,
            alpha: 0.15 * _opMult
        })
    readonly property var elevationLevel3: ({
            blurPx: 12 * _elevMult,
            offsetX: 6 * _elevMult * _elevDirXScale * _elevDirX,
            offsetY: 6 * _elevMult * _elevDirY,
            spreadPx: 0,
            alpha: 0.18 * _opMult
        })
    readonly property var elevationLevel4: ({
            blurPx: 16 * _elevMult,
            offsetX: 8 * _elevMult * _elevDirXScale * _elevDirX,
            offsetY: 8 * _elevMult * _elevDirY,
            spreadPx: 0,
            alpha: 0.18 * _opMult
        })
    readonly property var elevationLevel5: ({
            blurPx: 20 * _elevMult,
            offsetX: 10 * _elevMult * _elevDirXScale * _elevDirX,
            offsetY: 10 * _elevMult * _elevDirY,
            spreadPx: 0,
            alpha: 0.18 * _opMult
        })

    function elevationOffsetMagnitude(level, fallback, direction) {
        if (!level) {
            return fallback !== undefined ? Math.abs(fallback) : 0;
        }
        const yMag = Math.abs(level.offsetY !== undefined ? level.offsetY : 0);
        if (yMag > 0)
            return yMag;
        const xMag = Math.abs(level.offsetX !== undefined ? level.offsetX : 0);
        if (xMag > 0) {
            if (direction === "left" || direction === "right")
                return xMag;
            return xMag / _elevDiagRatio;
        }
        return fallback !== undefined ? Math.abs(fallback) : 0;
    }

    function elevationOffsetXFor(level, direction, fallback) {
        const dir = normalizeElevationDirection(direction || elevationLightDirection);
        const mag = elevationOffsetMagnitude(level, fallback, dir);
        switch (dir) {
        case "topLeft":
        case "bottomLeft":
            return mag * _elevDiagRatio;
        case "topRight":
        case "bottomRight":
            return -mag * _elevDiagRatio;
        case "left":
            return mag;
        case "right":
            return -mag;
        default:
            return 0;
        }
    }

    function elevationOffsetYFor(level, direction, fallback) {
        const dir = normalizeElevationDirection(direction || elevationLightDirection);
        const mag = elevationOffsetMagnitude(level, fallback, dir);
        switch (dir) {
        case "bottom":
        case "bottomLeft":
        case "bottomRight":
            return -mag;
        case "left":
        case "right":
            return 0;
        default:
            return mag;
        }
    }

    function elevationOffsetX(level, fallback) {
        return elevationOffsetXFor(level, elevationLightDirection, fallback);
    }

    function elevationOffsetY(level, fallback) {
        return elevationOffsetYFor(level, elevationLightDirection, fallback);
    }

    function elevationRenderPadding(level, direction, fallbackOffset, extraPadding, minPadding) {
        const dir = direction !== undefined ? direction : elevationLightDirection;
        const blur = (level && level.blurPx !== undefined) ? Math.max(0, level.blurPx) : 0;
        const spread = (level && level.spreadPx !== undefined) ? Math.max(0, level.spreadPx) : 0;
        const fallback = fallbackOffset !== undefined ? fallbackOffset : 0;
        const extra = extraPadding !== undefined ? extraPadding : 8;
        const minPad = minPadding !== undefined ? minPadding : 16;
        const offsetX = Math.abs(elevationOffsetXFor(level, dir, fallback));
        const offsetY = Math.abs(elevationOffsetYFor(level, dir, fallback));
        return Math.max(minPad, blur + spread + Math.max(offsetX, offsetY) + extra);
    }

    function elevationShadowColor(level) {
        const alpha = (level && level.alpha !== undefined) ? level.alpha : 0.3;
        let r = 0;
        let g = 0;
        let b = 0;

        if (typeof SettingsData !== "undefined") {
            const mode = SettingsData.m3ElevationColorMode || "default";
            if (mode === "default") {
                r = 0;
                g = 0;
                b = 0;
            } else if (mode === "text") {
                r = surfaceText.r;
                g = surfaceText.g;
                b = surfaceText.b;
            } else if (mode === "primary") {
                r = primary.r;
                g = primary.g;
                b = primary.b;
            } else if (mode === "surfaceVariant") {
                r = surfaceVariant.r;
                g = surfaceVariant.g;
                b = surfaceVariant.b;
            } else if (mode === "custom" && SettingsData.m3ElevationCustomColor) {
                const c = Qt.color(SettingsData.m3ElevationCustomColor);
                r = c.r;
                g = c.g;
                b = c.b;
            }
        }
        return Qt.rgba(r, g, b, alpha);
    }
    function elevationAmbient(level) {
        const blur = (level && level.blurPx !== undefined) ? Math.max(0, level.blurPx) : 0;
        const alpha = ((level && level.alpha !== undefined) ? level.alpha : 0.3) * 0.5;
        return {
            blurPx: blur * 1.75,
            spreadPx: 1,
            alpha: alpha
        };
    }

    function elevationTintOpacity(level) {
        if (!level)
            return 0;
        if (level === elevationLevel1)
            return 0.05;
        if (level === elevationLevel2)
            return 0.08;
        if (level === elevationLevel3)
            return 0.11;
        if (level === elevationLevel4)
            return 0.12;
        if (level === elevationLevel5)
            return 0.14;
        return 0.08;
    }

    readonly property var animationDurations: [
        {
            "shorter": 0,
            "short": 0,
            "medium": 0,
            "long": 0,
            "extraLong": 0
        },
        {
            "shorter": 50,
            "short": 75,
            "medium": 150,
            "long": 250,
            "extraLong": 500
        },
        {
            "shorter": 100,
            "short": 150,
            "medium": 300,
            "long": 500,
            "extraLong": 1000
        },
        {
            "shorter": 150,
            "short": 225,
            "medium": 450,
            "long": 750,
            "extraLong": 1500
        },
        {
            "shorter": 200,
            "short": 300,
            "medium": 600,
            "long": 1000,
            "extraLong": 2000
        }
    ]

    readonly property int currentAnimationSpeed: typeof SettingsData !== "undefined" ? SettingsData.animationSpeed : SettingsData.AnimationSpeed.Short
    readonly property var currentDurations: animationDurations[currentAnimationSpeed] || animationDurations[SettingsData.AnimationSpeed.Short]

    readonly property int shorterDuration: (typeof SettingsData !== "undefined" && SettingsData.animationSpeed === SettingsData.AnimationSpeed.Custom) ? SettingsData.customAnimationDuration : currentDurations.shorter
    readonly property int shortDuration: (typeof SettingsData !== "undefined" && SettingsData.animationSpeed === SettingsData.AnimationSpeed.Custom) ? SettingsData.customAnimationDuration : currentDurations.short
    readonly property bool snapListModelChanges: shortDuration <= 0
    readonly property int mediumDuration: (typeof SettingsData !== "undefined" && SettingsData.animationSpeed === SettingsData.AnimationSpeed.Custom) ? SettingsData.customAnimationDuration : currentDurations.medium
    readonly property int longDuration: (typeof SettingsData !== "undefined" && SettingsData.animationSpeed === SettingsData.AnimationSpeed.Custom) ? SettingsData.customAnimationDuration : currentDurations.long
    readonly property int extraLongDuration: (typeof SettingsData !== "undefined" && SettingsData.animationSpeed === SettingsData.AnimationSpeed.Custom) ? SettingsData.customAnimationDuration : currentDurations.extraLong
    readonly property int standardEasing: Easing.OutCubic
    readonly property int emphasizedEasing: Easing.OutQuart

    readonly property var expressiveCurves: {
        "emphasized": [0.05, 0, 2 / 15, 0.06, 1 / 6, 0.4, 5 / 24, 0.82, 0.25, 1, 1, 1],
        "emphasizedAccel": [0.3, 0, 0.8, 0.15, 1, 1],
        "emphasizedDecel": [0.05, 0.7, 0.1, 1, 1, 1],
        "standard": [0.2, 0, 0, 1, 1, 1],
        "standardAccel": [0.3, 0, 1, 1, 1, 1],
        "standardDecel": [0, 0, 0, 1, 1, 1],
        "expressiveFastSpatial": [0.42, 1.67, 0.21, 0.9, 1, 1],
        "expressiveDefaultSpatial": [0.38, 1.21, 0.22, 1, 1, 1],
        "expressiveEffects": [0.34, 0.8, 0.34, 1, 1, 1]
    }

    // Theme is the canonical access point for animation variant state. The
    // aliases below forward to AnimVariants.qml so consumers don't need two
    // imports. ~200 call sites read through Theme.variantEnterCurve /
    // Theme.isDirectionalEffect / etc. — do NOT migrate to AnimVariants directly.
    readonly property list<real> variantEnterCurve: AnimVariants.variantEnterCurve
    readonly property list<real> variantExitCurve: AnimVariants.variantExitCurve
    readonly property list<real> variantModalEnterCurve: AnimVariants.variantModalEnterCurve
    readonly property list<real> variantModalExitCurve: AnimVariants.variantModalExitCurve
    readonly property list<real> variantPopoutEnterCurve: AnimVariants.variantPopoutEnterCurve
    readonly property list<real> variantPopoutExitCurve: AnimVariants.variantPopoutExitCurve
    readonly property real variantEnterDurationFactor: AnimVariants.variantEnterDurationFactor
    readonly property real variantExitDurationFactor: AnimVariants.variantExitDurationFactor
    readonly property real variantOpacityDurationScale: AnimVariants.variantOpacityDurationScale
    readonly property bool isDirectionalEffect: AnimVariants.isDirectionalEffect
    readonly property bool isDepthEffect: AnimVariants.isDepthEffect
    readonly property real effectScaleCollapsed: AnimVariants.effectScaleCollapsed
    readonly property real effectAnimOffset: AnimVariants.effectAnimOffset
    function variantDuration(baseDuration, entering) {
        return AnimVariants.variantDuration(baseDuration, entering);
    }
    function variantExitCleanupPadding() {
        return AnimVariants.variantExitCleanupPadding();
    }
    function variantCloseInterval(baseDuration) {
        return AnimVariants.variantCloseInterval(baseDuration);
    }

    readonly property var animationPresetDurations: {
        "none": 0,
        "short": 250,
        "medium": 500,
        "long": 750
    }

    readonly property int currentAnimationBaseDuration: {
        if (typeof SettingsData === "undefined")
            return 500;

        if (SettingsData.animationSpeed === SettingsData.AnimationSpeed.Custom) {
            return SettingsData.customAnimationDuration;
        }

        const presetMap = [0, 250, 500, 750];
        return presetMap[SettingsData.animationSpeed] !== undefined ? presetMap[SettingsData.animationSpeed] : 500;
    }

    readonly property var expressiveDurations: {
        if (typeof SettingsData === "undefined") {
            return {
                "fast": 200,
                "normal": 400,
                "large": 600,
                "extraLarge": 1000,
                "expressiveFastSpatial": 350,
                "expressiveDefaultSpatial": 500,
                "expressiveEffects": 200
            };
        }

        const baseDuration = currentAnimationBaseDuration;
        return {
            "fast": baseDuration * 0.4,
            "normal": baseDuration * 0.8,
            "large": baseDuration * 1.2,
            "extraLarge": baseDuration * 2.0,
            "expressiveFastSpatial": baseDuration * 0.7,
            "expressiveDefaultSpatial": baseDuration,
            "expressiveEffects": baseDuration * 0.4
        };
    }

    readonly property int notificationAnimationBaseDuration: {
        if (typeof SettingsData === "undefined")
            return 200;
        if (SettingsData.notificationAnimationSpeed === SettingsData.AnimationSpeed.None)
            return 0;
        if (SettingsData.notificationAnimationSpeed === SettingsData.AnimationSpeed.Custom)
            return SettingsData.notificationCustomAnimationDuration;
        const presetMap = [0, 200, 400, 600];
        return presetMap[SettingsData.notificationAnimationSpeed] ?? 200;
    }

    readonly property int notificationEnterDuration: {
        const base = notificationAnimationBaseDuration;
        return base === 0 ? 0 : Math.round(base * 0.875);
    }

    readonly property int notificationExitDuration: {
        const base = notificationAnimationBaseDuration;
        return base === 0 ? 0 : Math.round(base * 0.75);
    }

    readonly property int notificationExpandDuration: {
        const base = notificationAnimationBaseDuration;
        return base === 0 ? 0 : Math.round(base * 1.0);
    }

    readonly property int notificationCollapseDuration: {
        const base = notificationAnimationBaseDuration;
        return base === 0 ? 0 : Math.round(base * 0.85);
    }

    readonly property int notificationInlineExpandDuration: notificationAnimationBaseDuration === 0 ? 0 : 185
    readonly property int notificationInlineCollapseDuration: notificationAnimationBaseDuration === 0 ? 0 : 150

    readonly property real notificationIconSizeNormal: 56
    readonly property real notificationIconSizeCompact: 48
    readonly property real notificationExpandedIconSizeNormal: 48
    readonly property real notificationExpandedIconSizeCompact: 40
    readonly property real notificationActionMinWidth: 48
    readonly property real notificationButtonCornerRadius: controlRadius
    readonly property real notificationContentSpacing: spacingXS
    readonly property real notificationCardPadding: spacingM
    readonly property real notificationCardPaddingCompact: spacingS

    readonly property real stateLayerHover: 0.08
    readonly property real stateLayerFocus: 0.12
    readonly property real stateLayerPressed: 0.12
    readonly property real stateLayerDrag: 0.16

    readonly property int popoutAnimationDuration: {
        if (typeof SettingsData === "undefined")
            return 150;
        if (SettingsData.syncComponentAnimationSpeeds) {
            return Math.min(currentAnimationBaseDuration, 1000);
        }
        const presetMap = [0, 150, 300, 500];
        if (SettingsData.popoutAnimationSpeed === SettingsData.AnimationSpeed.Custom)
            return SettingsData.popoutCustomAnimationDuration;
        return presetMap[SettingsData.popoutAnimationSpeed] ?? 150;
    }

    readonly property int modalAnimationDuration: {
        if (typeof SettingsData === "undefined")
            return 150;
        if (SettingsData.syncComponentAnimationSpeeds) {
            return Math.min(currentAnimationBaseDuration, 1000);
        }
        const presetMap = [0, 150, 300, 500];
        if (SettingsData.modalAnimationSpeed === SettingsData.AnimationSpeed.Custom)
            return SettingsData.modalCustomAnimationDuration;
        return presetMap[SettingsData.modalAnimationSpeed] ?? 150;
    }

    // Flatline (shadcn/Vercel) radius defaults — tighter than Material 3.
    // These are the values used when the user has not overridden surface
    // geometry. See docs/architecture/design-language.md.
    readonly property real maxSurfaceRadius: 14
    readonly property real defaultContainerRadius: 10
    readonly property real defaultControlRadius: 7
    property real cornerRadius: typeof SettingsData === "undefined" || !SettingsData.surfaceGeometryAppliesToQuickshell ? defaultContainerRadius : SettingsData.effectiveContainerRadius
    property real containerRadius: cornerRadius
    property real controlRadius: typeof SettingsData === "undefined" || !SettingsData.surfaceGeometryAppliesToQuickshell ? defaultControlRadius : SettingsData.effectiveControlRadius

    property string fontFamily: typeof SettingsData !== "undefined" ? SettingsData.fontFamily : "Inter Variable"

    property string monoFontFamily: typeof SettingsData !== "undefined" ? SettingsData.monoFontFamily : "Fira Code"

    property int fontWeight: typeof SettingsData !== "undefined" ? SettingsData.fontWeight : Font.Normal

    // Semantic header weights. Section headers (settings card titles) and category
    // headers (sidebar top-level groups) render bolder than body text so the
    // information hierarchy reads at a glance.
    // Flatline: bolder titles for a stronger type hierarchy.
    readonly property int fontWeightSectionHeader: Font.Bold
    readonly property int fontWeightCategoryHeader: Font.Bold

    property real fontScale: typeof SettingsData !== "undefined" ? SettingsData.fontScale : 1.0

    property real spacingXXS: 2
    property real spacingXS: 4
    property real spacingS: 8
    property real spacingM: 12
    property real spacingL: 16
    property real spacingXL: 24
    readonly property real popupDistance: spacingXS
    // Standard inner padding between a popout/dropdown/modal container edge and its content.
    // Use this for the outermost content inset so surfaces read with consistent breathing room.
    property real popoutPadding: 20
    property real fontSizeSmall: Math.round(fontScale * 12)
    property real fontSizeMedium: Math.round(fontScale * 14)
    property real fontSizeLarge: Math.round(fontScale * 16)
    property real fontSizeXLarge: Math.round(fontScale * 20)
    property real barHeight: 48
    property real iconSize: 24
    property real iconSizeSmall: 16
    property real iconSizeLarge: 32

    property real panelTransparency: 0.85
    readonly property real popupBaseTransparency: {
        if (typeof SettingsData === "undefined")
            return 1.0;
        return Math.max(0.08, Math.min(1, SettingsData.popupTransparency !== undefined ? SettingsData.popupTransparency : 1.0));
    }
    readonly property real popupBlurStrength: {
        if (typeof SettingsData === "undefined")
            return 0.0;
        return Math.max(0, Math.min(1, SettingsData.popupBlurStrength !== undefined ? SettingsData.popupBlurStrength : 0.0));
    }
    // Glass is a material: it owns the surface translucency needed for the
    // backdrop blur to read through, scaled by the user's opacity slider so
    // lowering opacity still yields thinner glass.
    // Tint alphas follow Apple's material recipes: light materials sit near 0.8,
    // dark near 0.7. The backdrop blur pulls luminance toward the material tone
    // (light lifts, dark sinks — see the helper's blur profile) and the tint
    // above finishes it, so neither mode washes out over an opposite-luminance
    // window. Both modes floor high: Apple's materials never go thin enough for
    // the backdrop to drag the surface to mid-gray under the label color, so the
    // opacity slider thins glass toward — never past — a legible floor.
    // Flatline: raise the glass legibility floor so popouts read as crisp
    // surfaces (a hint of material, not a see-through overlay) — modern design
    // systems keep panels mostly opaque.
    readonly property real glassSurfaceAlpha: Math.max(isLightMode ? 0.80 : 0.74, Math.min(0.94, glassBaseAlpha * popupBaseTransparency))
    readonly property real glassBaseAlpha: isLightMode ? 0.78 : 0.68
    // Effective popup surface alpha. Blur strength deliberately plays no part:
    // the opacity slider owns how see-through surfaces are, blur only changes
    // what the see-through region looks like.
    property real popupTransparency: popupGlassEffect ? glassSurfaceAlpha : popupBaseTransparency

    function popupAlphaForSurface(blurAvailable) {
        return blurAvailable === false ? popupBaseTransparency : popupTransparency;
    }

    function popupGlassActiveForSurface(blurAvailable) {
        return popupGlassEffect && blurAvailable !== false;
    }

    function popupSurfaceColor(baseColor, blurAvailable) {
        return withAlpha(baseColor, popupAlphaForSurface(blurAvailable));
    }

    readonly property real popupShadowOpacityScale: {
        const alpha = popupSurfaceColor(surfaceContainer).a;
        return Math.max(0.08, Math.min(1, alpha));
    }

    function popupShadowOpacity(baseOpacity) {
        const base = baseOpacity !== undefined ? baseOpacity : 1;
        return Math.max(0, Math.min(1, base * popupShadowOpacityScale));
    }


    function screenTransition() {
        // VGS applies compositor colors through its own generator and hooks.
    }

    function _runThemeHelper(id, args, label) {
        Proc.runCommand("vgs-theme-" + id, [Paths.vshellCli].concat(args), function(output, exitCode, stderr) {
            if (exitCode !== 0) {
                const msg = (stderr && stderr.trim().length > 0) ? stderr : (output || "theme command failed");
                log.warn(label + " failed:", msg);
                if (typeof ToastService !== "undefined")
                    ToastService.showError("VGS theme failed", msg);
                return;
            }
            themeFileView.reload();
        }, 0, 120000);
        return label + " requested";
    }

    function switchTheme(themeName, savePrefs, enableTransition) {
        const target = themeName || currentTheme || methodThemeJson.name || "coppernight";
        currentTheme = target;
        currentThemeCategory = "vgs";
        return _runThemeHelper("apply-" + target, ["theme", "apply", target], "Apply " + target);
    }

    function setLightMode(light, savePrefs, enableTransition) {
        return _runThemeHelper("mode-" + (light ? "light" : "dark"), ["theme", "mode", light ? "light" : "dark"], light ? "Light mode" : "Dark mode");
    }

    function toggleLightMode(savePrefs) {
        return _runThemeHelper("toggle", ["theme", "toggle"], "Theme toggle");
    }

    function forceGenerateSystemThemes() {
        return _runThemeHelper("regenerate", ["theme", "apply", currentTheme || methodThemeJson.name || "coppernight"], "Regenerate app themes");
    }

    function generateSystemThemesFromCurrentTheme() {
        return _runThemeHelper("regenerate", ["theme", "apply", currentTheme || methodThemeJson.name || "coppernight"], "Regenerate app themes");
    }

    function getAvailableThemes() {
        return ["vgs-theme"];
    }

    function setGreeterThemeBaseDir(dir) {
        const next = dir || root._greeterCacheDir;
        if (greeterThemeBaseDir === next)
            return;
        greeterThemeBaseDir = next;
        if (isGreeterMode)
            themeFileView.reload();
    }

    function resetGreeterThemeBaseDir() {
        setGreeterThemeBaseDir(root._greeterCacheDir);
    }
    property alias availableThemeNames: root._availableThemeNames
    readonly property var _availableThemeNames: ["vgs-theme"]

    function getMatugenColor(path, fallback) { return fallback; }
    function getMatugenScheme(value) { return { "value": "vgs", "label": "VGS", "description": "VGS owns theme generation." }; }
    function applyGtkColors() { return generateSystemThemesFromCurrentTheme(); }
    function applyQtColors() { return generateSystemThemesFromCurrentTheme(); }

    function panelBackground() {
        return withAlpha(surfaceContainer, panelTransparency);
    }

    property real notepadTransparency: SettingsData.notepadTransparencyOverride >= 0 ? SettingsData.notepadTransparencyOverride : popupTransparency

    property bool widgetBackgroundHasAlpha: {
        const colorMode = typeof SettingsData !== "undefined" ? SettingsData.widgetBackgroundColor : "sch";
        return colorMode === "sth" || colorMode === "custom";
    }

    function safeColor(value, fallback) {
        try {
            if (value === undefined || value === null || value === "")
                return fallback;
            return Qt.color(value);
        } catch (e) {
            return fallback;
        }
    }

    readonly property color widgetBackgroundCustomBaseColor: safeColor(typeof SettingsData !== "undefined" ? SettingsData.widgetBackgroundCustomColor : "#6750A4", primaryContainer)
    readonly property real widgetBackgroundCustomStrength: Math.max(0, Math.min(1, typeof SettingsData !== "undefined" ? (SettingsData.widgetBackgroundCustomStrength ?? 0.4) : 0.4))

    property var widgetBaseBackgroundColor: {
        const colorMode = typeof SettingsData !== "undefined" ? SettingsData.widgetBackgroundColor : "sch";
        switch (colorMode) {
        case "s":
            return surface;
        case "sc":
            return surfaceContainer;
        case "sch":
            return surfaceContainerHigh;
        case "primaryContainer":
            return primaryContainer;
        case "secondaryContainer":
            return secondaryContainer;
        case "tertiaryContainer":
            return tertiaryContainer;
        case "custom":
            return blend(surfaceContainerHigh, widgetBackgroundCustomBaseColor, widgetBackgroundCustomStrength);
        case "sth":
        default:
            return surfaceTextHover;
        }
    }

    property color widgetBaseHoverColor: {
        const blended = blend(widgetBaseBackgroundColor, primary, 0.1);
        return withAlpha(blended, Math.max(0.3, blended.a));
    }

    property color widgetIconColor: {
        if (typeof SettingsData === "undefined") {
            return surfaceText;
        }

        switch (SettingsData.widgetColorMode) {
        case "colorful":
            return surfaceText;
        case "default":
        default:
            return surfaceText;
        }
    }

    property color widgetTextColor: {
        if (typeof SettingsData === "undefined") {
            return surfaceText;
        }

        switch (SettingsData.widgetColorMode) {
        case "colorful":
            return primary;
        case "default":
        default:
            return surfaceText;
        }
    }

    function isColorDark(c) {
        return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) < 0.5;
    }

    function barIconSize(barThickness, offset, maximizeIcon, iconScale) {
        const defaultOffset = offset !== undefined ? offset : -6;
        const size = (maximizeIcon ?? false) ? iconSizeLarge : iconSize;
        const s = iconScale !== undefined ? iconScale : 1.0;

        return Math.round((barThickness / 48) * (size + defaultOffset) * s);
    }

    function barTextSize(barThickness, fontScale, maximizeText) {
        const scale = barThickness / 48;
        const barScale = fontScale !== undefined ? fontScale : 1.0;
        const maxScale = (maximizeText ?? false) ? 1.5 : 1.0;
        if (scale <= 0.75)
            return Math.round(fontSizeSmall * 0.9 * barScale * maxScale);
        if (scale >= 1.25)
            return Math.round(fontSizeMedium * barScale * maxScale);
        return Math.round(fontSizeSmall * barScale * maxScale);
    }

    function getBatteryIcon(level, isCharging, batteryAvailable) {
        if (!batteryAvailable)
            return "battery_std";

        if (isCharging) {
            if (level >= 90)
                return "battery_charging_full";
            if (level >= 80)
                return "battery_charging_90";
            if (level >= 60)
                return "battery_charging_80";
            if (level >= 50)
                return "battery_charging_60";
            if (level >= 30)
                return "battery_charging_50";
            if (level >= 20)
                return "battery_charging_30";
            return "battery_charging_20";
        } else {
            if (level >= 95)
                return "battery_full";
            if (level >= 85)
                return "battery_6_bar";
            if (level >= 70)
                return "battery_5_bar";
            if (level >= 55)
                return "battery_4_bar";
            if (level >= 40)
                return "battery_3_bar";
            if (level >= 25)
                return "battery_2_bar";
            if (level >= 10)
                return "battery_1_bar";
            return "battery_alert";
        }
    }

    function getPowerProfileIcon(profile) {
        switch (profile) {
        case 0:
            return "battery_saver";
        case 1:
            return "battery_std";
        case 2:
            return "flash_on";
        default:
            return "settings";
        }
    }

    function getPowerProfileLabel(profile) {
        switch (profile) {
        case 0:
            return I18n.tr("Power Saver", "power profile option");
        case 1:
            return I18n.tr("Balanced", "power profile option");
        case 2:
            return I18n.tr("Performance", "power profile option");
        default:
            return I18n.tr("Unknown", "power profile option");
        }
    }

    function getPowerProfileDescription(profile) {
        switch (profile) {
        case 0:
            return I18n.tr("Extend battery life", "power profile description");
        case 1:
            return I18n.tr("Balance power and performance", "power profile description");
        case 2:
            return I18n.tr("Prioritize performance", "power profile description");
        default:
            return I18n.tr("Custom power profile", "power profile description");
        }
    }

    function onLightModeChanged() {}

    function withAlpha(c, a) {
        if (!c || c.r === undefined)
            return Qt.rgba(0, 0, 0, 0);
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    function popupLayerColor(baseColor) {
        return popupSurfaceColor(baseColor);
    }

    function blendAlpha(c, a) {
        if (!c || c.r === undefined)
            return Qt.rgba(0, 0, 0, 0);
        return Qt.rgba(c.r, c.g, c.b, c.a * a);
    }

    // Composite an interaction state onto an opaque fill, returning a solid
    // colour so a filled row can light up without losing its fill.
    //
    // These tint toward the on-surface colour (the Material "state layer"
    // model) rather than toward surfaceVariant. surfaceVariant only reads as a
    // highlight over the darker base surfaces; composited onto an already
    // elevated fill it is a near-invisible *darkening*, which is the opposite
    // of what a hover should do. Tinting toward surfaceText always moves away
    // from the fill — lighter on dark themes, darker on light ones.
    function hoverOn(base) {
        return blend(base, surfaceText, hoverOverlayAlpha);
    }

    function pressedOn(base) {
        return blend(base, surfaceText, pressedOverlayAlpha);
    }

    function selectedOn(base) {
        return blend(base, surfaceText, selectedOverlayAlpha);
    }

    function blend(c1, c2, r) {
        return Qt.rgba(c1.r * (1 - r) + c2.r * r, c1.g * (1 - r) + c2.g * r, c1.b * (1 - r) + c2.b * r, c1.a * (1 - r) + c2.a * r);
    }

    function getFillMode(modeName) {
        switch (modeName) {
        case "Stretch":
            return Image.Stretch;
        case "Fit":
        case "PreserveAspectFit":
            return Image.PreserveAspectFit;
        case "Fill":
        case "PreserveAspectCrop":
            return Image.PreserveAspectCrop;
        case "Tile":
            return Image.Tile;
        case "TileVertically":
            return Image.TileVertically;
        case "TileHorizontally":
            return Image.TileHorizontally;
        case "Pad":
            return Image.Pad;
        default:
            return Image.PreserveAspectCrop;
        }
    }

    // Returns numeric fillMode value for shader use (matches shader calculateUV logic)
    function getShaderFillMode(modeName) {
        switch (modeName) {
        case "Stretch": return 0;
        case "Fit":
        case "PreserveAspectFit": return 1;
        case "Fill":
        case "PreserveAspectCrop": return 2;
        case "Tile": return 3;
        case "TileVertically": return 4;
        case "TileHorizontally": return 5;
        case "Pad": return 6;
        case "Scrolling": return 7;
        default: return 2;
        }
    }

    function snap(value, dpr) {
        const s = dpr || 1;
        return Math.round(value * s) / s;
    }

    function px(value, dpr) {
        const s = dpr || 1;
        return Math.round(value * s) / s;
    }

    function hairline(dpr) {
        return 1 / (dpr || 1);
    }

    function invertHex(hex) {
        hex = hex.replace('#', '');

        if (!/^[0-9A-Fa-f]{6}$/.test(hex)) {
            return hex;
        }

        const r = parseInt(hex.substr(0, 2), 16);
        const g = parseInt(hex.substr(2, 2), 16);
        const b = parseInt(hex.substr(4, 2), 16);

        const invR = (255 - r).toString(16).padStart(2, '0');
        const invG = (255 - g).toString(16).padStart(2, '0');
        const invB = (255 - b).toString(16).padStart(2, '0');

        return `#${invR}${invG}${invB}`;
    }

    property var baseLogoColor: {
        if (typeof SettingsData === "undefined")
            return "";
        const colorOverride = SettingsData.launcherLogoColorOverride;
        if (!colorOverride || colorOverride === "")
            return "";
        if (colorOverride === "primary")
            return primary;
        if (colorOverride === "surface")
            return surfaceText;
        return colorOverride;
    }

    property var effectiveLogoColor: {
        if (typeof SettingsData === "undefined")
            return "";

        const colorOverride = SettingsData.launcherLogoColorOverride;
        if (!colorOverride || colorOverride === "")
            return "";

        if (colorOverride === "primary")
            return primary;
        if (colorOverride === "surface")
            return surfaceText;

        if (!SettingsData.launcherLogoColorInvertOnMode) {
            return colorOverride;
        }

        if (isLightMode) {
            return invertHex(colorOverride);
        }

        return colorOverride;
    }


    FileView {
        id: themeFileView
        path: root.themePath
        blockLoading: false
        watchChanges: true
        printErrors: false

        function parseTheme() {
            try {
                const raw = themeFileView.text();
                if (!raw || raw.trim().length === 0)
                    return;
                root.methodThemeJson = JSON.parse(raw);
                if (root.methodThemeJson.name)
                    root.currentTheme = root.methodThemeJson.name;
                // CLI applies only touch theme.json; keep the session wallpaper in sync
                // so `vshell theme apply` changes the background like UI applies do.
                // wallpaperSource=folder decouples the wallpaper from theme applies.
                if (root.methodThemeJson.wallpaper && typeof SessionData !== "undefined"
                        && SessionData.wallpaperPath !== root.methodThemeJson.wallpaper
                        && (typeof SettingsData === "undefined" || SettingsData.wallpaperSource !== "folder"))
                    SessionData.setWallpaper(root.methodThemeJson.wallpaper);
                root.colorsFileLoadFailed = false;
            } catch (e) {
                root.colorsFileLoadFailed = true;
                root.log.warn("Failed to parse VGS theme:", e.message);
            }
        }

        onLoaded: parseTheme()
        onFileChanged: themeFileView.reload()
        onLoadFailed: function(error) {
            root.colorsFileLoadFailed = true;
            root.log.warn("VGS theme not readable, using fallback:", error);
        }
    }

    IpcHandler {
        target: "theme"

        function toggle(): string { return root.toggleLightMode(true); }
        function light(): string { return root.setLightMode(true, true, true); }
        function dark(): string { return root.setLightMode(false, true, true); }
        function getMode(): string { return root.isLightMode ? "light" : "dark"; }
        function reload(): string { themeFileView.reload(); return "VGS_THEME_RELOAD_REQUESTED"; }
    }
}
