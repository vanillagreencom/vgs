pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import QtCore
import qs.Services

Singleton {
    id: root

    readonly property url home: StandardPaths.standardLocations(StandardPaths.HomeLocation)[0]
    readonly property url pictures: StandardPaths.standardLocations(StandardPaths.PicturesLocation)[0]
    readonly property url xdgCache: StandardPaths.standardLocations(StandardPaths.GenericCacheLocation)[0]

    readonly property url data: `${StandardPaths.standardLocations(StandardPaths.GenericDataLocation)[0]}/vshell`
    readonly property url state: `${StandardPaths.standardLocations(StandardPaths.GenericStateLocation)[0]}/vshell`
    readonly property url cache: `${StandardPaths.standardLocations(StandardPaths.GenericCacheLocation)[0]}/vshell`
    readonly property url config: `${StandardPaths.standardLocations(StandardPaths.GenericConfigLocation)[0]}/vshell`

    // Qt.resolvedUrl() resolves inside Quickshell's virtual filesystem
    // (qrc:/qs-blackhole), which is not a runnable path; shellDir is the real
    // launch directory. `..` resolves through the ~/.config/quickshell/vshell
    // symlink when the kernel walks the path, so this stays correct for a
    // source checkout, a packaged install, and a shell started without
    // VSHELL_ROOT.
    readonly property string repoRoot: Quickshell.env("VSHELL_ROOT") || (Quickshell.shellDir + "/../..")
    readonly property string vshellCli: repoRoot + "/bin/vshell"

    // The token durable theme state roots a wallpaper path on, spelled as
    // bin/vshell_helper.py writes and reads it.
    readonly property string rootToken: "${VSHELL_ROOT}"

    // BEGIN WALLPAPER REFERENCE DECISION
    // Recording and resolving, mirroring `portable_ref` and `resolve_path` in
    // bin/vshell_helper.py, because session.json is written on a coalesced timer no
    // subprocess can sit inside. Repairing a background another installation
    // recorded is not here: `recovered_package_ref` in the helper owns it, and it
    // tests the filesystem, which this cannot do synchronously.
    // docs/architecture/wallpaper.md states the rule.
    // scripts/lib/wallpaper-ref-cases.json is the case table both runtimes run.
    // Keep this region free of root., Theme., I18n. and Qt. references: scripts/test-wallpaper-refs.js extracts and executes it.

    // The directories the rule is stated against, derived once from what the shell
    // knows about itself. Deriving them here rather than at each use site is what
    // lets the test drive the same composition the shell runs.
    function refRootsFrom(repo, configDir, homeDir, token) {
        return { repo: repo, userThemes: configDir + "/themes", home: homeDir, token: token };
    }

    // A wallpaper path as durable state records it: one containment test. A path
    // inside this installation's root becomes a rooted reference and everything
    // else passes through, a user theme package and a picture outside VGS alike,
    // as does the colour literal setWallpaperColor stores in the same field.
    function wallpaperRefIn(path, roots) {
        if (!path || !path.startsWith("/"))
            return path || "";
        if (path.startsWith(roots.repo + "/"))
            return roots.token + path.substring(roots.repo.length);
        return path;
    }

    // The `~` form the helper writes into a target's destination. One owner: the
    // `expandTilde` below is this function with the shell's own home.
    function expandTildeIn(path, homeDir) {
        if (!path || !path.startsWith("~"))
            return path || "";
        return homeDir + path.substring(1);
    }

    // A reference as the path on this machine now. A rooted reference never also
    // carries a `~`, so the two forms are separate arms.
    function resolveRefIn(ref, roots) {
        if (!ref)
            return "";
        if (ref.startsWith(roots.token))
            return roots.repo + ref.substring(roots.token.length);
        return expandTildeIn(ref, roots.home);
    }

    // END WALLPAPER REFERENCE DECISION

    readonly property var refRoots: refRootsFrom(repoRoot, strip(config), strip(home), rootToken)

    function wallpaperRef(path: string): string {
        return wallpaperRefIn(path, root.refRoots);
    }

    function resolveRef(ref: string): string {
        return resolveRefIn(ref, root.refRoots);
    }

    readonly property url imagecache: `${cache}/imagecache`

    function stringify(path: url): string {
        return path.toString().replace(/%20/g, " ");
    }

    function expandTilde(path: string): string {
        return expandTildeIn(path, strip(root.home));
    }

    function shortenHome(path: string): string {
        return path.replace(strip(root.home), "~");
    }

    function strip(path: url): string {
        return stringify(path).replace("file://", "");
    }

    function toFileUrl(path: string): string {
        return path.startsWith("file://") ? path : "file://" + path;
    }

    function mkdir(path: url): void {
        Quickshell.execDetached(["mkdir", "-p", strip(path)]);
    }

    function copy(from: url, to: url): void {
        Quickshell.execDetached(["cp", strip(from), strip(to)]);
    }

    function isSteamApp(appId: string): bool {
        return appId && /^steam_app_\d+$/.test(appId);
    }

    function moddedAppId(appId: string): string {
        const subs = SettingsData.appIdSubstitutions || [];
        for (let i = 0; i < subs.length; i++) {
            const sub = subs[i];
            if (sub.type === "exact" && appId === sub.pattern) {
                return sub.replacement;
            } else if (sub.type === "contains" && appId.includes(sub.pattern)) {
                return sub.replacement;
            } else if (sub.type === "regex") {
                const match = appId.match(new RegExp(sub.pattern));
                if (match) {
                    return sub.replacement.replace(/\$(\d+)/g, (_, n) => match[n] || "");
                }
            }
        }
        const steamMatch = appId.match(/^steam_app_(\d+)$/);
        if (steamMatch)
            return `steam_icon_${steamMatch[1]}`;
        return appId;
    }

    // The URL that draws an icon file through Quickshell's icon image provider, which
    // renders at the device pixel ratio. A plain file:// source is loaded at native
    // size and mipmapped down, which visibly softened large themed icons on HiDPI.
    function iconProviderUrl(path: string): string {
        return "image://icon/" + path;
    }

    function themedIconPath(name: string): string {
        if (!name)
            return "";
        const themed = (typeof IconThemeService !== "undefined") ? IconThemeService.resolve(name) : "";
        if (themed)
            return themed;
        return Quickshell.iconPath(name, true);
    }

    function resolveIconPath(iconName: string): string {
        if (!iconName)
            return "";
        const moddedId = moddedAppId(iconName);
        if (moddedId !== iconName) {
            if (moddedId.startsWith("~") || moddedId.startsWith("/"))
                return toFileUrl(expandTilde(moddedId));
            if (moddedId.startsWith("file://"))
                return moddedId;
            return themedIconPath(moddedId);
        }
        return themedIconPath(iconName) || DesktopService.resolveIconPath(iconName);
    }

    function resolveIconUrl(iconName: string): string {
        if (!iconName)
            return "";
        const moddedId = moddedAppId(iconName);
        const target = (moddedId !== iconName) ? moddedId : iconName;
        if (target.startsWith("~") || target.startsWith("/"))
            return toFileUrl(expandTilde(target));
        if (target.startsWith("file://"))
            return target;
        const themed = (typeof IconThemeService !== "undefined") ? IconThemeService.resolve(target) : "";
        if (themed)
            return themed;
        return iconProviderUrl(target);
    }

    function getAppIcon(appId: string, desktopEntry: var): string {
        if (appId === "org.quickshell") {
            return Qt.resolvedUrl("../assets/vgslogo.svg");
        }

        const moddedId = moddedAppId(appId);
        if (moddedId !== appId)
            return resolveIconPath(appId);

        if (desktopEntry && desktopEntry.icon) {
            return themedIconPath(desktopEntry.icon);
        }

        const icon = themedIconPath(appId);
        if (icon && icon !== "")
            return icon;

        return DesktopService.resolveIconPath(appId);
    }

    function getAppName(appId: string, desktopEntry: var): string {
        if (appId === "org.quickshell" || appId === "com.vanillagreen.vshell") {
            return "VGS";
        }

        return desktopEntry && desktopEntry.name ? desktopEntry.name : appId;
    }
}
