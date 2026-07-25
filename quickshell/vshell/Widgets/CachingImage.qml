import QtQuick
import Quickshell.Io
import qs.Common

Item {
    id: root

    property string imagePath: ""
    property int maxCacheSize: 512
    property int status: isAnimated ? animatedImg.status : staticImg.status
    property int fillMode: Image.PreserveAspectCrop
    // Grid usage: when a preloader has already filled the disk cache, skip the
    // per-tile `test -f` probe process. A missing thumb still falls back to the
    // source image through the Image.Error path.
    property bool assumeCached: false

    readonly property bool isRemoteUrl: imagePath.startsWith("http://") || imagePath.startsWith("https://")
    readonly property bool isAnimated: {
        if (!imagePath)
            return false;
        const lower = imagePath.toLowerCase();
        return lower.endsWith(".gif") || lower.endsWith(".webp");
    }
    readonly property string normalizedPath: {
        if (!imagePath)
            return "";
        if (isRemoteUrl)
            return imagePath;
        if (imagePath.startsWith("file://"))
            return imagePath.substring(7);
        return imagePath;
    }

    function djb2Hash(str) {
        if (!str)
            return "";
        let hash = 5381;
        for (let i = 0; i < str.length; i++) {
            hash = ((hash << 5) + hash) + str.charCodeAt(i);
            hash = hash & 0x7FFFFFFF;
        }
        return hash.toString(16).padStart(8, '0');
    }

    readonly property string imageHash: normalizedPath ? djb2Hash(normalizedPath) : ""
    // Plain filesystem path (for test/ffmpegthumbnailer/saveToFile) …
    readonly property string cachePath: imageHash && !isRemoteUrl && !isAnimated ? `${Paths.strip(Paths.imagecache)}/${imageHash}@${maxCacheSize}x${maxCacheSize}.png` : ""
    // … and the file:// form Image.source resolves to.
    readonly property string cacheUrl: cachePath ? "file://" + cachePath : ""
    readonly property string encodedImagePath: {
        if (!normalizedPath)
            return "";
        if (isRemoteUrl)
            return normalizedPath;
        return "file://" + normalizedPath.split('/').map(s => encodeURIComponent(s)).join('/');
    }

    AnimatedImage {
        id: animatedImg
        anchors.fill: parent
        visible: root.isAnimated
        asynchronous: true
        fillMode: root.fillMode
        source: root.isAnimated ? root.imagePath : ""
        playing: visible && status === AnimatedImage.Ready
    }

    Image {
        id: staticImg
        anchors.fill: parent
        visible: !root.isAnimated
        asynchronous: true
        fillMode: root.fillMode
        sourceSize.width: root.maxCacheSize
        sourceSize.height: root.maxCacheSize
        smooth: true

        onStatusChanged: {
            if (source.toString() === root.cacheUrl && status === Image.Error) {
                source = root.encodedImagePath;
                return;
            }
            if (root.isRemoteUrl || source.toString() !== root.encodedImagePath || status !== Image.Ready || !root.cachePath)
                return;
            Paths.mkdir(Paths.imagecache);
            const grabPath = root.cachePath;
            if (visible && width > 0 && height > 0 && Window.window?.visible) {
                grabToImage(res => res.saveToFile(grabPath));
            }
        }
    }

    Process {
        id: cacheProbe

        property string cachePath: ""
        property string fallbackSource: ""

        running: false
        command: ["test", "-f", cachePath]

        onExited: exitCode => {
            if (cacheProbe.cachePath !== root.cachePath)
                return;
            staticImg.source = exitCode === 0 ? "file://" + cacheProbe.cachePath : cacheProbe.fallbackSource;
        }
    }

    onImagePathChanged: {
        if (!imagePath) {
            staticImg.source = "";
            return;
        }
        if (isAnimated)
            return;
        if (isRemoteUrl) {
            staticImg.source = imagePath;
            return;
        }
        Paths.mkdir(Paths.imagecache);
        const encoded = "file://" + normalizedPath.split('/').map(s => encodeURIComponent(s)).join('/');
        if (!cachePath) {
            staticImg.source = encoded;
            return;
        }
        if (assumeCached) {
            staticImg.source = cacheUrl;
            return;
        }
        cacheProbe.running = false;
        cacheProbe.cachePath = cachePath;
        cacheProbe.fallbackSource = encoded;
        cacheProbe.running = true;
    }
}
