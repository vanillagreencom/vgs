# Runtime: QML shaders

Covers: shell/Ui/feedback/VoiceOrb.qml, shell/Ui/feedback/shaders/**, scripts/check-voiceorb-shader.py, scripts/test-check-voiceorb-shader.py, scripts/shader/**

The Qt facts the passive shader component rests on. Its component contract is in [components-media.md § VoiceOrb](components-media.md#voiceorb).

## ShaderEffect

- Qt Quick accepts baked `.qsb` packs rather than inline shader source. A fragment-only effect uses the default vertex shader's texture coordinates at location 0. Its shared `std140` uniform block starts with `qt_Matrix` at offset 0 and `qt_Opacity` at offset 64. Custom uniforms follow them. QML properties supply uniforms by matching their names. A QML colour reaches a `vec4` premultiplied by alpha, so the fragment output multiplies that colour by coverage and `qt_Opacity`, not by its alpha again. Source: [ShaderEffect](https://doc.qt.io/qt-6/qml-qtquick-shadereffect.html), Qt 6.11.2 reference.
- `VoiceOrb` has no texture input, intermediate layer or blur. Its shader evaluates a ring and concentric arcs directly. `scripts/check-voiceorb-shader.py` refuses iteration and texture sampling in this source. The unit suite reads uniforms, not pixels: the offscreen software renderer does not draw `ShaderEffect` ([validation-qml-unit.md](validation-qml-unit.md)).
- `ShaderEffect.status` is not a rendering verdict for repeated instances on Qt 6.11.2. `QQuickShaderEffectPrivate::updateShader` takes cached reflection data without calling the manager's `prepareShaderCode`; `status()` reads that manager, whose default remains Uncompiled. The cache-miss path sets Compiled in `QSGRhiGuiThreadShaderEffectManager::prepareShaderCode`. Sources: [Qt item implementation](https://github.com/qt/qtdeclarative/blob/v6.11.2/src/quick/items/qquickshadereffect.cpp) and [RHI manager implementation](https://github.com/qt/qtdeclarative/blob/v6.11.2/src/quick/scenegraph/qsgrhishadereffectnode.cpp). The `shot` capture in the lane's direct diagnostic run `1790756314266202821`, on 2026-09-30, draws all nine examples while eight managers report Uncompiled. The Gallery row therefore captures each orb's box from the nested compositor and requires pixels in its tone. Its control first draws a blue ring in a blank slot, then hides only its shader and requires those pixels to disappear.

## Animation lifetime

- `FrameAnimation.triggered` runs on animation updates, not on a timer. `frameTime` gives seconds since its previous update. Source: [FrameAnimation](https://doc.qt.io/qt-6/qml-qtquick-frameanimation.html).
- An item's `visible` property follows hidden ancestors. It does not mean the item lies inside a scrolling viewport. Source: [Item.visible](https://doc.qt.io/qt-6/qml-qtquick-item.html#visible-prop). `VoiceOrb` therefore also checks its attached `Window.window`, the host window's `visible`, and that the window is not minimized. The attached window belongs to the item, not a separate window the component creates ([runtime-qml.md](runtime-qml.md)).
- The driver owns the phase and level smoothing. Stopping it holds the phase and uses the current bounded levels directly. No animation or timer continues to smooth a hidden or reduced-motion orb. `scripts/qml-tests/tst_voiceorb.qml` first observes triggered signals, then holds their count and phase under each stop condition. These are animation-lifetime readings, not frame-presentation evidence.

## Baked asset

- `scripts/check-voiceorb-shader.py --write` rebuilds the shipped pack with `qsb --qt6 --qsbversion 64`. The targets cover the Qt Quick OpenGL, Direct3D and Metal forms alongside SPIR-V. The serialization option keeps the pack compatible with Qt 6.4 and later; it is not the component's Qt API floor. Source: [QSB manual](https://doc.qt.io/qt-6/qtshadertools-qsb.html), and `/usr/lib/qt6/bin/qsb --help` on this lane, qsb 6.11.2.
- The checker locates `qsb` on PATH or in Qt's Linux tool directories. An absent compiler exits 77. It compares a fresh compile with the shipped bytes and fails on invalid source or a stale pack. `scripts/test-check-voiceorb-shader.py` plants source, pack, compiler, iteration and texture defects. This is a build tool contract, not a plugin command requirement under D035. Installed users need no compiler.
- The source and pack travel through the shared installer and `packaging/install-tree.manifest`. The core module resolves the pack beside its QML file, independently of a plugin's published source revision. The Gallery smoke brings each example into the viewport and reads its actual tone pixels from the nested output. The read-only prefix row instruments its disposable installed tree with the same observer as the source sandbox, then summons the installed Gallery before comparing its tree snapshots.

## Decisions

- A generic passive visual belongs to `qs.Ui`: [D060](../decisions/D060-passive-voice-orb.md).

## Frame timing

- The threaded renderer's `qt.scenegraph.time.renderloop` messages identify the `QQuickWindow` by address. `sync` and `render` are CPU-side timings, truncated to integer milliseconds. They are not GPU execution times. `QSG_RHI_PROFILE=1` enables GPU timestamps; the same category prints `last retrieved GPU frame time` for completed GPU work. Qt retrieves timestamps asynchronously. Each stream therefore discards its own warmup samples. Sources: [Qt render loop](https://github.com/qt/qtdeclarative/blob/v6.11.2/src/quick/scenegraph/qsgthreadedrenderloop.cpp), [QQuickGraphicsConfiguration.setTimestamps](https://doc.qt.io/qt-6/qquickgraphicsconfiguration.html#setTimestamps).
- `QSG_NO_VSYNC=1` requests swap interval 0. It does not remove Wayland compositor pacing. The instrument uses GPU timestamp frame time on minus off, not the interval between `frameSwapped` signals, for GPU cost. Presentation keeps its own reading. Qt's Vulkan device log identifies the selected physical device and its type; a CPU device cannot establish hardware shader cost. Source: [Qt Vulkan device selection](https://github.com/qt/qtbase/blob/v6.11.2/src/gui/rhi/qrhivulkan.cpp).
- The standalone scene and the measured ceilings are in [validation-shaders.md](validation-shaders.md). They do not set a cost claim for another shader, device or backend.
