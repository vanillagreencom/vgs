.pragma library

// The control points `Easing.bezierCurve` reads for one curve of
// look.motion.curve, ending at (1, 1).
function bezier(curve) {
    return [curve.x1, curve.y1, curve.x2, curve.y2, 1, 1];
}
