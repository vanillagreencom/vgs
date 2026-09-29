.pragma library

function clearing(pad, radius, width, height, step) {
    var corner = Math.min(radius, width / 2, height / 2);
    if (corner <= 0) return pad;
    return Math.max(pad, corner + step);
}
