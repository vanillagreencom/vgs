.pragma library

// The painted extent of one Lucide path, as { left, top, right, bottom }
// in the icon's 24 unit box, or null for an empty path. Line and curve
// segments count their end and control points, the hull that holds the
// curve; an arc counts the whole ellipse it lies on. The extent can be
// larger than the ink, never smaller, so an icon aligned by it never
// crosses the edge it is aligned to.
function bounds(data) {
    var tokens = String(data).match(/[a-zA-Z]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?/g);
    if (tokens === null) return null;
    var box = null;
    var add = function (x, y) {
        if (box === null) box = { left: x, top: y, right: x, bottom: y };
        else {
            box.left = Math.min(box.left, x);
            box.top = Math.min(box.top, y);
            box.right = Math.max(box.right, x);
            box.bottom = Math.max(box.bottom, y);
        }
    };
    var at = 0, command = "", x = 0, y = 0, startX = 0, startY = 0;
    var number = function () { return Number(tokens[at++]); };
    var isNumber = function (token) { return token !== undefined && !/^[a-zA-Z]$/.test(token); };
    while (at < tokens.length) {
        if (!isNumber(tokens[at])) command = tokens[at++];
        var relative = command === command.toLowerCase();
        var ox = relative ? x : 0, oy = relative ? y : 0;
        switch (command.toUpperCase()) {
        case "Z":
            x = startX; y = startY;
            continue;
        case "M":
            x = ox + number(); y = oy + number();
            startX = x; startY = y;
            add(x, y);
            command = relative ? "l" : "L";
            break;
        case "L":
        case "T":
            x = ox + number(); y = oy + number();
            add(x, y);
            break;
        case "H":
            x = ox + number();
            add(x, y);
            break;
        case "V":
            y = oy + number();
            add(x, y);
            break;
        case "C":
            add(ox + number(), oy + number());
            add(ox + number(), oy + number());
            x = ox + number(); y = oy + number();
            add(x, y);
            break;
        case "S":
        case "Q":
            add(ox + number(), oy + number());
            x = ox + number(); y = oy + number();
            add(x, y);
            break;
        case "A": {
            var rx = Math.abs(number()), ry = Math.abs(number());
            number(); number(); number();
            var nx = ox + number(), ny = oy + number();
            var cx = (x + nx) / 2, cy = (y + ny) / 2;
            var half = Math.hypot(nx - x, ny - y) / 2;
            // The ellipse through both ends with the stated radii, grown
            // when they are too small, as an SVG renderer grows them; the
            // centre lies within `half` of the chord's middle, so the box
            // around that middle holds the ellipse wherever it lies.
            var r = Math.max(rx, ry, half);
            add(cx - r - half, cy - r - half);
            add(cx + r + half, cy + r + half);
            add(nx, ny);
            x = nx; y = ny;
            break;
        }
        default:
            return box;
        }
    }
    return box;
}
