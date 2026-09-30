#version 440

// The default Qt Quick vertex shader shares this uniform buffer.
// qt_Matrix and qt_Opacity must remain first (runtime-qml-shaders.md).
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 ink;
    vec2 dimensions;
    float phase;
    float amplitude;
    float secondaryAmplitude;
    vec4 lines; // radius and gap as diameter shares, stroke widths in pixels
    vec4 waves; // amplitude share, wave count, arc span and arc opacity
};

const float tau = 6.283185307179586;

float stroke(float distance, float width, float pixel) {
    return 1.0 - smoothstep(width * 0.5, width * 0.5 + pixel, abs(distance));
}

float arc(float radius, float angle, float index, float pixel) {
    float turn = angle - phase - index * tau / 3.0;
    float mask = smoothstep(cos(waves.z * 0.5), cos(waves.z * 0.5) + pixel, cos(turn));
    float ripple = waves.x * secondaryAmplitude * sin(waves.y * angle + phase + index * tau / 3.0);
    return mask * stroke(radius - lines.x - index * lines.y - ripple, lines.w * pixel, pixel) * waves.w;
}

void main() {
    float diameter = max(min(dimensions.x, dimensions.y), 1.0);
    vec2 point = (qt_TexCoord0 - 0.5) * dimensions / diameter;
    float radius = length(point);
    float angle = atan(point.y, point.x);
    float pixel = 1.0 / diameter;
    float ripple = waves.x * amplitude * sin(waves.y * angle + phase);
    float ring = stroke(radius - lines.x - ripple, lines.z * pixel, pixel);
    // Three arcs, no texture, blur, noise stack or unbounded work.
    float arcs = max(arc(radius, angle, 1.0, pixel),
                    max(arc(radius, angle, 2.0, pixel), arc(radius, angle, 3.0, pixel)));
    // ShaderEffect supplies QML colours already premultiplied.
    fragColor = ink * max(ring, arcs) * qt_Opacity;
}
