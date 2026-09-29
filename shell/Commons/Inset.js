.pragma library

// The least inset from each side that keeps the corners of rectangular
// content at least `step` inside the drawn rounded corner, when the
// content's top and bottom edges stand `top` in from the container's. The
// drawn corner is `radius` clamped to half the smaller side; a square
// corner keeps `pad`. Content within one step of the edge clears the whole
// corner instead, since no inset keeps its corner inside the curve.
function clearing(pad, radius, width, height, step, top) {
    var corner = Math.min(radius, width / 2, height / 2);
    if (corner <= 0) return pad;
    var dy = Math.max(0, corner - top);
    var reach = corner - step;
    if (dy > reach) return Math.max(pad, corner + step);
    return Math.max(pad, corner - Math.sqrt(reach * reach - dy * dy));
}
