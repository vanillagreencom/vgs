#version 450

// A shared signed-distance pass draws the surface rim and interior illumination.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float widthPx;
    float heightPx;
    float radiusPx;
    float rimWidthPx;       // 0 disables the rim
    vec4 rimTopColor;       // straight rgba: glint on up-facing edges
    vec4 rimBottomColor;    // straight rgba: secondary glint on down-facing edges
    vec4 sheenTopColor;     // straight rgba
    vec4 sheenBottomColor;  // straight rgba
} ubuf;

float sdRoundBox(vec2 p, vec2 c, vec2 hs, float r) {
    r = min(r, min(hs.x, hs.y));
    vec2 q = abs(p - c) - hs + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

// Outward surface normal of the rounded box in item space (y grows downward).
// Analytic, not derivative-based: dFdy orientation flips between RHI backends.
vec2 rboxNormal(vec2 p, vec2 c, vec2 hs, float r) {
    r = min(r, min(hs.x, hs.y));
    vec2 rel = p - c;
    vec2 q = abs(rel) - hs + r;
    if (q.x > 0.0 && q.y > 0.0)
        return sign(rel) * normalize(q);
    if (q.x > q.y)
        return vec2(rel.x >= 0.0 ? 1.0 : -1.0, 0.0);
    return vec2(0.0, rel.y >= 0.0 ? 1.0 : -1.0);
}

void main() {
    vec2 sizePx = vec2(ubuf.widthPx, ubuf.heightPx);
    vec2 px = qt_TexCoord0 * sizePx;
    vec2 hs = sizePx * 0.5;
    float d = sdRoundBox(px, hs, hs, ubuf.radiusPx);
    float fw = max(fwidth(d), 1e-4);
    float cov = 1.0 - smoothstep(-fw, fw, d);
    float t = clamp(qt_TexCoord0.y, 0.0, 1.0);

    vec4 col = vec4(0.0);

    if (ubuf.rimWidthPx > 0.0) {
        float covInner = 1.0 - smoothstep(-fw, fw, d + ubuf.rimWidthPx);
        float rimMask = max(0.0, cov - covInner);
        vec2 n = rboxNormal(px, hs, hs, ubuf.radiusPx);
        float up = clamp(-n.y, 0.0, 1.0);
        float down = clamp(n.y, 0.0, 1.0);
        float rimA = ubuf.rimTopColor.a * (0.22 + 0.78 * up * up)
                   + ubuf.rimBottomColor.a * (down * down);
        vec3 rimRgb = mix(ubuf.rimTopColor.rgb, ubuf.rimBottomColor.rgb, down);
        col += vec4(rimRgb, 1.0) * (min(rimA, 1.0) * rimMask);
    }

    float sheenTopA = ubuf.sheenTopColor.a * (1.0 - smoothstep(0.0, 0.50, t));
    float sheenBottomA = ubuf.sheenBottomColor.a * smoothstep(0.65, 1.0, t);
    col += vec4(ubuf.sheenTopColor.rgb, 1.0) * (sheenTopA * cov);
    col += vec4(ubuf.sheenBottomColor.rgb, 1.0) * (sheenBottomA * cov);

    fragColor = col * ubuf.qt_Opacity;
}
