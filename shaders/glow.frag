#version 460 core

#include <flutter/runtime_effect.glsl>

// The dock's glow, drawn once into images by lib/glow.dart (GlowSprite):
// one lamp behind the frosted glass, as a few closed-form shapes fitted to
// references traced by tool/glow (the glow setting's steps, GlowLook.steps):
// the lamp seen through the frosting (a box blurred by a Gaussian), the
// frosting's wide light round it, light carried along the glass and out at
// its cut edges; or, as the second mode, the light the lamp throws on the
// wallpaper beyond the dock. In linear light, shown through the same tone
// curve as the reference, to be added to what lies beneath.

uniform vec2 uSize;
// The lamp's centre x and y, half width and half height.
uniform vec4 uLamp;
// Its corner radius; the band's top and bottom; the exposure.
uniform vec4 uBand;
// Core amount and blur; the wide light's amount and size.
uniform vec4 uCore;
// The wide light's power; light along the glass: amount and length; the edges' amount.
uniform vec4 uGlass;
// The edges' length; the wallpaper's light: amount, size and power.
uniform vec4 uEdge;
// The lamp's colour (linear, luminance 1) times its heat; the mode (0 the glass, 1 the wallpaper).
uniform vec4 uTint;

out vec4 fragColor;

// Abramowitz and Stegun 7.1.26, as tool/glow/fit.py has it.
float erf(float x) {
  float s = sign(x);
  x = abs(x);
  float t = 1.0 / (1.0 + 0.3275911 * x);
  float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
  return s * y;
}

// A box of half-width h blurred by a Gaussian of s: 1 inside, 0 far out.
float box(float u, float h, float s) {
  float k = 0.70710678 / s;
  return 0.5 * (erf((u + h) * k) - erf((u - h) * k));
}

// Distance outside a rounded rectangle of half-sizes h centred at 0 (0 inside).
float outside(vec2 p, vec2 h, float r) {
  vec2 q = abs(p) - (h - r);
  return max(length(max(q, 0.0)) - r, 0.0);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 d = p - uLamp.xy;
  vec2 h = uLamp.zw;
  float away = outside(d, h, uBand.x);
  float light;
  if (uTint.w > 0.5) {
    if (p.y > uBand.y && p.y < uBand.z) {
      // Under the glass: its own light is drawn there.
      fragColor = vec4(0.0);
      return;
    }
    light = uEdge.y * pow(1.0 + (away / uEdge.z) * (away / uEdge.z), -uEdge.w);
  } else {
    float core = uCore.x * box(d.x, h.x, uCore.y) * box(d.y, h.y, uCore.y);
    float pool = uCore.z * pow(1.0 + (away / uCore.w) * (away / uCore.w), -uGlass.x);
    float along = max(abs(d.x) - h.x, 0.0);
    float glass = uGlass.y * exp(-along / uGlass.z);
    // The cut edges: their outer dp, edged to a pixel.
    float edge = 1.0 - smoothstep(0.5, 1.5, min(p.y - uBand.y, uBand.z - p.y));
    float edges = uGlass.w * edge * exp(-along / uEdge.x);
    light = core + pool + glass + edges;
  }
  vec3 shown = 1.0 - exp(-uBand.w * uTint.rgb * light);
  fragColor = vec4(shown, max(shown.r, max(shown.g, shown.b)));
}
