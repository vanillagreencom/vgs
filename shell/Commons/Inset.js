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

// The side padding of a one-line control whose content, `contentHeight`
// tall, centres in its `height`: the least whole inset from `pad` that
// keeps the content's corners `step` inside the drawn corner, which the
// control's height bounds, since a one-line control is wider than tall.
function controlPadding(pad, radius, height, contentHeight, step) {
    return Math.ceil(clearing(pad, radius, 2 * height, height, step, (height - contentHeight) / 2));
}

// The top and bottom inset of a list of rows whose fills reach the side of a
// container `border` wide with drawn corner `radius`, when a row's drawn
// corner is `rowRadius`: the border alone while the row's corner is at least
// as round as the container's inner corner, so the first and last rows'
// fills meet the border and their corners stay inside its curve. Otherwise
// the list starts lower by the difference, where the first row's corner
// centre meets the container's, so its corner still stays inside the curve.
function listInset(radius, border, rowRadius) {
    return border + Math.max(0, radius - border - rowRadius);
}
