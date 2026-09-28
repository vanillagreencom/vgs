#version 440
// Edge light for the launcher's glass card: two point lights orbit just
// outside a rounded-rect card. The crisp glass edge reflects each light
// where its surface normal faces it, and a faint glow refracts a few pixels
// into the glass. The highlight is symmetric around the light, like a real
// specular reflection, and only the lights move. Compiled to
// edgelight.frag.qsb by the command in the plugin's README.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;        // item size, logical px
    float radius;     // corner radius, logical px
    float thickness;  // edge width, logical px
    vec2 lightA;      // light positions, px, relative to the card center
    vec2 lightB;
    float powerA;     // light strengths
    float powerB;
    float reach;      // light falloff radius, px
    float base;       // ambient edge strength
    vec4 neutral;     // the light at rest, straight alpha
    vec4 accent;      // the light while lit, straight alpha
    float lit;        // 0 at rest, 1 lit
};

float shine(vec2 p, vec2 n, vec2 light, float power) {
    vec2 v = light - p;
    float d = length(v);
    float facing = max(dot(n, v / max(d, 0.001)), 0.0);
    return power * pow(facing, 3.0) * exp(-(d * d) / (reach * reach));
}

void main() {
    vec2 p = qt_TexCoord0 * size - 0.5 * size;
    float r = min(radius, 0.5 * min(size.x, size.y));
    vec2 h = max(0.5 * size - r, vec2(0.0));
    vec2 q = abs(p) - h;
    float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;   // < 0 inside
    // Only a thin band at the edge carries light; skip the card interior.
    if (dist > 1.0 || dist < -14.0) { fragColor = vec4(0.0); return; }

    // Outward surface normal of the rounded rect at the nearest edge point.
    vec2 m = max(q, 0.0);
    vec2 s = vec2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
    vec2 n = length(m) > 0.0 ? normalize(m) * s : (q.x > q.y ? vec2(s.x, 0.0) : vec2(0.0, s.y));

    float light = shine(p, n, lightA, powerA) + shine(p, n, lightB, powerB);

    float aa = max(fwidth(dist), 0.0001);
    float edge = smoothstep(-thickness - aa, -thickness + aa, dist) * (1.0 - smoothstep(-aa, aa, dist));
    float glow = exp(min(dist, 0.0) / 5.0) * (1.0 - smoothstep(-aa, aa, dist));

    float a = edge * (base + light) + glow * 0.22 * light;
    // The light blends from the neutral to the accent here rather than in
    // QML, so no colour is built from channels outside the table.
    vec4 color = mix(neutral, accent, lit);
    a = clamp(a, 0.0, 1.0) * color.a * qt_Opacity;
    fragColor = vec4(color.rgb * a, a);
}
