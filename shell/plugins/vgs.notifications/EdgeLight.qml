import QtQuick

// Specular light on the edge of a notification's glass card. Two point
// lights orbit just outside the card and the edge catches each one where it
// faces it; lay it over the card through `follow`. `active` blends the light
// from the neutral grey to the theme's accent, as a critical notification
// is; `boost` multiplies both lights and `spin` adds orbits per second,
// which the card raises while it is a dot and while the pointer is on it.
// The orbit stands still while the theme's motion scale is 0. The shader is
// shaders/edgelight.frag, compiled to the .qsb beside it, loaded from this
// plugin's published revision.
ShaderEffect {
    id: edge

    required property var look
    required property Item follow
    property bool active: false
    property real boost: 1
    property real spin: 0

    x: follow.x
    y: follow.y
    width: follow.width
    height: follow.height
    opacity: follow.opacity
    scale: follow.scale
    transformOrigin: follow.transformOrigin

    readonly property real radius: follow.radius
    // The corner the radius rounds to on this size.
    readonly property real corner: Math.min(radius, width / 2, height / 2)
    readonly property bool running: visible && opacity > 0 && look.motion.scale > 0

    // Shader uniforms, by name.
    readonly property size size: Qt.size(width, height)
    readonly property real thickness: look.edge.thickness
    readonly property real reach: look.edge.reach
    readonly property real base: look.edge.base
    readonly property color neutral: look.edge.neutral
    readonly property color accent: look.palette.accent
    property real lit: active ? 1 : 0
    Behavior on lit {
        Anim { duration: edge.look.motion.duration.long2; curve: edge.look.motion.curve.standard }
    }
    readonly property real powerA: look.edge.strengthA * boost
    readonly property real powerB: look.edge.strengthB * boost
    readonly property point lightA: orbitPoint(phase)
    // The counter light trails half an orbit behind, drifting a little.
    readonly property point lightB: orbitPoint(phase + 0.5 + 0.045 * Math.sin(clock / 5.3))

    // Phase is a fraction of the orbit, so the lights hold their place
    // while the card resizes. `clock` drives the pace wobble.
    property real phase: Math.random()
    property real clock: Math.random() * 100

    readonly property real orbitRadius: corner + look.edge.lift
    readonly property real orbitW: Math.max(0, width - 2 * corner)
    readonly property real orbitH: Math.max(0, height - 2 * corner)
    readonly property real orbitLength: 2 * (orbitW + orbitH) + 2 * Math.PI * orbitRadius

    // The point on the orbit, a rounded rect `lift` outside the card, at a
    // fraction of its length, clockwise from the top-left of the top edge,
    // relative to the card's centre.
    function orbitPoint(f) {
        const w = orbitW, h = orbitH, r = orbitRadius, arc = Math.PI * r / 2;
        let s = ((f % 1) + 1) % 1 * orbitLength;
        const hw = w / 2, hh = h / 2;
        if (s < w) return Qt.point(-hw + s, -hh - r);
        s -= w;
        if (s < arc) return Qt.point(hw + r * Math.sin(s / r), -hh - r * Math.cos(s / r));
        s -= arc;
        if (s < h) return Qt.point(hw + r, -hh + s);
        s -= h;
        if (s < arc) return Qt.point(hw + r * Math.cos(s / r), hh + r * Math.sin(s / r));
        s -= arc;
        if (s < w) return Qt.point(hw - s, hh + r);
        s -= w;
        if (s < arc) return Qt.point(-hw - r * Math.sin(s / r), hh + r * Math.cos(s / r));
        s -= arc;
        if (s < h) return Qt.point(-hw - r, hh - s);
        s -= h;
        return Qt.point(-hw - r * Math.cos(s / r), -hh - r * Math.sin(s / r));
    }

    fragmentShader: Qt.resolvedUrl("shaders/edgelight.frag.qsb")
    blending: true

    FrameAnimation {
        running: edge.running && edge.orbitLength > 0
        onTriggered: {
            // A long frame is capped, so a stall never jumps the lights.
            const dt = Math.min(frameTime, 0.05);
            edge.clock += dt;
            // An uneven pace: two slow, unrelated waves on the mean speed.
            const pace = 1 + 0.3 * Math.sin(edge.clock * 0.83) + 0.12 * Math.sin(edge.clock * 2.1 + 1.3);
            edge.phase = (edge.phase + dt * (edge.look.edge.speed * pace / edge.orbitLength + edge.spin)) % 1;
        }
    }
}
