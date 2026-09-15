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
    // Mirrors `portable_ref` and `resolve_path` in bin/vshell_helper.py, which owns
    // the rule; session.json is the one durable file the shell writes without the
    // helper, and its writer runs on a coalesced timer no subprocess can sit inside.
    // scripts/lib/wallpaper-ref-cases.json is the single case table both run.
    // Keep this region free of root., Theme., I18n. and Qt. references: scripts/test-wallpaper-refs.js extracts and executes it.

    // A wallpaper path as durable state records it, given this installation's root
    // and the user's theme package directory. A path inside the root becomes a
    // rooted reference; one inside the user's packages is already durable; one that
    // ends in a package background's tail was recorded by another installation and
    // is re-rooted on this one. Anything else, a picture outside VGS or the colour
    // literal setWallpaperColor stores in the same field, passes through.
    function wallpaperRefFrom(path, repo, userThemes, token) {
        if (!path || !path.startsWith("/"))
            return path || "";
        if (path.startsWith(repo + "/"))
            return token + path.substring(repo.length);
        if (path.startsWith(userThemes + "/"))
            return path;
        const tail = path.match(/\/themes\/([^/]+)\/backgrounds\/([^/]+)$/);
        if (tail)
            return token + "/themes/" + tail[1] + "/backgrounds/" + tail[2];
        return path;
    }

    // The inverse, for the token alone; `expandTilde` owns the other form the helper
    // writes into a target's destination.
    function resolveRefFrom(ref, repo, token) {
        if (!ref)
            return "";
        if (ref.startsWith(token))
            return repo + ref.substring(token.length);
        return ref;
    }
    // END WALLPAPER REFERENCE DECISION

    function wallpaperRef(path: string): string {
        return wallpaperRefFrom(path, root.repoRoot, strip(root.config) + "/themes", root.rootToken);
    }

    function resolveRef(ref: string): string {
        return expandTilde(resolveRefFrom(ref, root.repoRoot, root.rootToken));
    }

    // A wallpaper as the shell holds it, out of whatever durable state recorded it.
    // Normalising before resolving is what recovers a record an installation that is
    // gone wrote: wallpaperRefFrom's third arm re-roots a package background on this
    // installation, so a session written before references existed shows the same
    // image rather than nothing. `resolved_wallpaper` is the helper's counterpart.
    function resolveWallpaper(value: string): string {
        return resolveRef(wallpaperRef(value));
    }

    readonly property url imagecache: `${cache}/imagecache`

    function stringify(path: url): string {
        return path.toString().replace(/%20/g, " ");
    }

    function expandTilde(path: string): string {
        if (!path.startsWith("~"))
            return path;
        return strip(root.home) + path.substring(1);
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
        return "image://icon/" + target;
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
