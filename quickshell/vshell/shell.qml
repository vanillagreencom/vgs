//@ pragma Env QSG_RENDER_LOOP=threaded
//@ pragma Env QT_MEDIA_BACKEND=ffmpeg
//@ pragma Env QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi
//@ pragma Env QT_FFMPEG_ENCODING_HW_DEVICE_TYPES=vaapi
//@ pragma Env QT_WAYLAND_DISABLE_WINDOWDECORATION=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Material
//@ pragma UseQApplication
//@ pragma AppId com.vanillagreen.vshell

import QtQuick
import Quickshell

ShellRoot {
    id: entrypoint

    readonly property bool runGreeter: Quickshell.env("VSHELL_RUN_GREETER") === "1" || Quickshell.env("VSHELL_RUN_GREETER") === "true"
    readonly property bool disableHotReload: Quickshell.env("VSHELL_DISABLE_HOT_RELOAD") === "1" || Quickshell.env("VSHELL_DISABLE_HOT_RELOAD") === "true"

    Component.onCompleted: {
        Quickshell.watchFiles = !disableHotReload;
    }

    Loader {
        id: vshellLoader
        asynchronous: false
        sourceComponent: VGS {}
        active: !entrypoint.runGreeter
    }

    Loader {
        id: greeterLoader
        asynchronous: false
        sourceComponent: VGSGreeter {}
        active: entrypoint.runGreeter
    }
}
