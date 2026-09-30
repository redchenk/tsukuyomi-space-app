#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 imageSize;
uniform vec2 imageOrigin;
uniform float hueShift;
uniform float brightness;
uniform float opacity;
uniform sampler2D costume;
out vec4 fragColor;

vec3 rgbToHsv(vec3 rgb) {
  vec4 k = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
  vec4 p = mix(vec4(rgb.bg, k.wz), vec4(rgb.gb, k.xy), step(rgb.b, rgb.g));
  vec4 q = mix(vec4(p.xyw, rgb.r), vec4(rgb.r, p.yzx), step(p.x, rgb.r));
  float d = q.x - min(q.w, q.y);
  return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + 1.0e-10)), d / (q.x + 1.0e-10), q.x);
}
vec3 hsvToRgb(vec3 hsv) {
  vec3 p = abs(fract(hsv.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
  return hsv.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), hsv.y);
}
void main() {
  vec2 uv = (FlutterFragCoord().xy - imageOrigin) / imageSize;
  vec4 pixel = texture(costume, uv);
  vec3 rgb = pixel.a > 0.0 ? pixel.rgb / pixel.a : vec3(0.0);
  if (hueShift != 0.0) {
    vec3 hsv = rgbToHsv(rgb);
    // The Scratch renderer lets colour affect very dark/unsaturated costumes.
    if (hsv.z < 0.055) hsv = vec3(0.0, 1.0, 0.055);
    else if (hsv.y < 0.09) hsv = vec3(0.0, 0.09, hsv.z);
    hsv.x = fract(hsv.x + hueShift);
    rgb = hsvToRgb(hsv);
  }
  rgb = clamp(rgb + vec3(brightness), 0.0, 1.0);
  float alpha = pixel.a * opacity;
  fragColor = vec4(rgb * alpha, alpha);
}
