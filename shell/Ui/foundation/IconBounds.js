.pragma library

// The painted extent of one Lucide path, as { left, top, right, bottom }
// in the icon's 24 unit box, or null for an empty path. Line and curve
// segments count their end and control points, the hull that holds the
// curve; a smooth segment (S, T) counts the control point it reflects from
// the segment before. An arc counts its ends and each axis extreme of its
// ellipse that lies inside its sweep, with the centre and radii an SVG
// renderer derives (SVG 1.1 F.6.5, F.6.6). The extent can be larger than
// the ink, never smaller, so an icon aligned by it never crosses the edge
// it is aligned to. The scanner reads an arc's two flags as one character
// each, as the SVG grammar does, so packed flags such as `a1 1 0 000 2`
// read as flags 0 and 0 and the point (0, 2).
function bounds(data) {
    var text = String(data);
    var at = 0;
    var NUMBER = /[\s,]*(-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)/y;
    var COMMAND = /[\s,]*([a-zA-Z])/y;
    var FLAG = /[\s,]*([01])/y;
    var read = function (pattern) {
        pattern.lastIndex = at;
        var found = pattern.exec(text);
        if (found === null) return null;
        at = pattern.lastIndex;
        return found[1];
    };
    var number = function () {
        var token = read(NUMBER);
        if (token === null) throw new Error("number");
        return Number(token);
    };
    var flag = function () {
        var token = read(FLAG);
        if (token === null) throw new Error("flag");
        return token === "1";
    };
    var startsNumber = function () {
        NUMBER.lastIndex = at;
        return NUMBER.test(text);
    };

    var box = null;
    var add = function (px, py) {
        if (box === null) box = { left: px, top: py, right: px, bottom: py };
        else {
            box.left = Math.min(box.left, px);
            box.top = Math.min(box.top, py);
            box.right = Math.max(box.right, px);
            box.bottom = Math.max(box.bottom, py);
        }
    };

    var command = "", x = 0, y = 0, startX = 0, startY = 0;
    // The control point a following S or T reflects, and the command that
    // set it.
    var controlX = 0, controlY = 0, controlOf = "";
    try {
        while (true) {
            if (!startsNumber()) {
                var next = read(COMMAND);
                if (next === null) break;
                command = next;
            }
            var relative = command === command.toLowerCase();
            var ox = relative ? x : 0, oy = relative ? y : 0;
            var kind = command.toUpperCase();
            var reflects = (kind === "S" && (controlOf === "C" || controlOf === "S")) || (kind === "T" && (controlOf === "Q" || controlOf === "T"));
            var reflectedX = reflects ? 2 * x - controlX : x, reflectedY = reflects ? 2 * y - controlY : y;
            var setControl = "";
            switch (kind) {
            case "Z":
                x = startX; y = startY;
                // Numbers after Z start no segment; the next read stops.
                command = "";
                break;
            case "M":
                x = ox + number(); y = oy + number();
                startX = x; startY = y;
                add(x, y);
                command = relative ? "l" : "L";
                break;
            case "L":
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
                controlX = ox + number(); controlY = oy + number();
                add(controlX, controlY);
                x = ox + number(); y = oy + number();
                add(x, y);
                setControl = "C";
                break;
            case "S":
                add(reflectedX, reflectedY);
                controlX = ox + number(); controlY = oy + number();
                add(controlX, controlY);
                x = ox + number(); y = oy + number();
                add(x, y);
                setControl = "S";
                break;
            case "Q":
                controlX = ox + number(); controlY = oy + number();
                add(controlX, controlY);
                x = ox + number(); y = oy + number();
                add(x, y);
                setControl = "Q";
                break;
            case "T":
                controlX = reflectedX; controlY = reflectedY;
                add(controlX, controlY);
                x = ox + number(); y = oy + number();
                add(x, y);
                setControl = "T";
                break;
            case "A": {
                var rx = Math.abs(number()), ry = Math.abs(number());
                var rotation = number() * Math.PI / 180;
                var large = flag(), sweep = flag();
                var nx = ox + number(), ny = oy + number();
                addArc(add, x, y, rx, ry, rotation, large, sweep, nx, ny);
                x = nx; y = ny;
                break;
            }
            default:
                return box;
            }
            controlOf = setControl;
        }
    } catch (error) {
        // A path that ends inside a segment's arguments keeps the extent
        // read so far, as a renderer draws the segments before the error.
    }
    return box;
}

// Add an arc's ends and each axis extreme of its ellipse inside its sweep.
function addArc(add, x1, y1, rx, ry, phi, large, sweep, x2, y2) {
    add(x2, y2);
    if (rx === 0 || ry === 0 || (x1 === x2 && y1 === y2)) return;
    var cos = Math.cos(phi), sin = Math.sin(phi);
    var dx = (x1 - x2) / 2, dy = (y1 - y2) / 2;
    var x1p = cos * dx + sin * dy, y1p = -sin * dx + cos * dy;
    // Radii too small to reach both ends grow until they do.
    var lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
    if (lambda > 1) { rx *= Math.sqrt(lambda); ry *= Math.sqrt(lambda); }
    var num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    var den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var coef = (large !== sweep ? 1 : -1) * Math.sqrt(Math.max(0, num / den));
    var cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx;
    var cx = cos * cxp - sin * cyp + (x1 + x2) / 2;
    var cy = sin * cxp + cos * cyp + (y1 + y2) / 2;
    var angle = function (ux, uy, vx, vy) { return Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy); };
    var start = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep && delta > 0) delta -= 2 * Math.PI;
    if (sweep && delta < 0) delta += 2 * Math.PI;
    var full = 2 * Math.PI;
    var inside = function (theta) {
        var t = delta >= 0 ? theta - start : start - theta;
        t = ((t % full) + full) % full;
        return t <= Math.abs(delta) + 1e-9;
    };
    var pointAt = function (theta) {
        add(cx + rx * cos * Math.cos(theta) - ry * sin * Math.sin(theta),
            cy + rx * sin * Math.cos(theta) + ry * cos * Math.sin(theta));
    };
    var extremeX = Math.atan2(-ry * sin, rx * cos);
    var extremeY = Math.atan2(ry * cos, rx * sin);
    [extremeX, extremeX + Math.PI, extremeY, extremeY + Math.PI].forEach(function (theta) {
        if (inside(theta)) pointAt(theta);
    });
}
