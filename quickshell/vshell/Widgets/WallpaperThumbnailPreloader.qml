pragma ComponentBehavior: Bound

import QtQuick
import qs.Common

// Preload wallpaper thumbnails in a batch. Missing ffmpegthumbnailer leaves CachingImage to fill its cache lazily.
Item {
    id: root

    visible: false

    property var paths: []
    property int cacheSize: 256
    property bool autoStart: true
    property bool generating: false
    // A tool-available batch has returned. Individual thumbnails can still be missing; CachingImage handles those misses.
    property bool cacheReady: false

    signal finished(bool toolAvailable)

    property int _toolState: -1 // -1 unknown, 0 unavailable, 1 available
    property int _generation: 0

    onPathsChanged: if (autoStart)
        preload()

    // Must match djb2Hash + cachePath in Widgets/CachingImage.qml.
    function _hash(str) {
        if (!str)
            return "";
        let hash = 5381;
        for (let i = 0; i < str.length; i++) {
            hash = ((hash << 5) + hash) + str.charCodeAt(i);
            hash = hash & 0x7FFFFFFF;
        }
        return hash.toString(16).padStart(8, '0');
    }

    function _cachePathFor(path) {
        const hash = _hash(path);
        if (!hash)
            return "";
        return `${Paths.strip(Paths.imagecache)}/${hash}@${cacheSize}x${cacheSize}.png`;
    }

    function _isAnimated(path) {
        const lower = path.toLowerCase();
        return lower.endsWith(".gif") || lower.endsWith(".webp");
    }

    function preload() {
        if (_toolState === 0) {
            finished(false);
            return;
        }
        if (_toolState === -1) {
            Proc.runCommand("wallpaperThumbToolCheck", ["sh", "-c", "command -v ffmpegthumbnailer"], function (out, code) {
                root._toolState = code === 0 ? 1 : 0;
                if (root._toolState === 1)
                    root._start();
                else
                    root.finished(false);
            });
            return;
        }
        _start();
    }

    function _start() {
        Paths.mkdir(Paths.imagecache);
        const args = [];
        for (let i = 0; i < paths.length; i++) {
            const p = paths[i];
            if (!p || p.startsWith("#") || _isAnimated(p))
                continue;
            const cachePath = _cachePathFor(p);
            if (cachePath)
                args.push(cachePath, p);
        }
        if (args.length === 0) {
            generating = false;
            cacheReady = true;
            finished(true);
            return;
        }
        generating = true;
        const generation = ++_generation;

        const script = 'size="$1"; shift; while [ "$#" -ge 2 ]; do t="$1"; s="$2"; shift 2; [ "$t" -nt "$s" ] || ffmpegthumbnailer -i "$s" -o "$t" -s "$size"; done';
        Proc.runCommand(null, ["sh", "-c", script, "thumbs", String(cacheSize)].concat(args), function (out, code) {
            if (generation !== root._generation)
                return;
            root.generating = false;
            root.cacheReady = true;
            root.finished(true);
        }, 0, 120000);
    }
}
