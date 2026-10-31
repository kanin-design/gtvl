#version 460 core

#include <flutter/runtime_effect.glsl>

// The dock's glow: a lamp behind the frosted glass under the app in focus,
// as a few closed-form shapes fitted to references traced by tool/glow (the
// glow setting's steps, GlowLook.steps in lib/glow.dart): the lamp seen
// through the frosting (a box blurred by a Gaussian), the frosting's wide
// light round it, light carried along the glass and out at its cut edges;
// or, as the second mode, the light the
// lamp throws on the wallpaper beyond the dock. Up to four lamps: the one in
// focus and the embers it left. Summed in linear light and shown through
// the same tone curve as the reference, to be added to what lies beneath.

uniform vec2 uSize;
// Lamps' centre y, half width, half height, corner radius.
uniform vec4 uLamp;
// Core amount and blur; the wide light's amount and size.
uniform vec4 uCore;
// The wide light's power; light along the glass: amount and length; the edges' amount.
uniform vec4 uGlass;
// The edges' length; the band's top and bottom; the exposure.
uniform vec4 uEdge;
// The wallpaper's light: amount, size, power; and the mode (0 the glass, 1 the wallpaper).
uniform vec4 uBleed;
// Each lamp: centre x, heat (0 for none), stretch; and its colour (linear, luminance 1).
uniform vec4 uSpot0;
uniform vec4 uTint0;
uniform vec4 uSpot1;
uniform vec4 uTint1;
uniform vec4 uSpot2;
uniform vec4 uTint2;
uniform vec4 uSpot3;
uniform vec4 uTint3;

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

// One lamp's light at p, in luminance.
float light(vec2 p, vec4 spot) {
  vec2 d = p - vec2(spot.x, uLamp.x);
  vec2 h = vec2(uLamp.y * spot.z, uLamp.z);
  float r = uLamp.w;
  float away = outside(d, h, r);
  if (uBleed.w > 0.5) {
    return uBleed.x * pow(1.0 + (away / uBleed.y) * (away / uBleed.y), -uBleed.z);
  }
  float core = uCore.x * box(d.x, h.x, uCore.y) * box(d.y, h.y, uCore.y);
  float pool = uCore.z * pow(1.0 + (away / uCore.w) * (away / uCore.w), -uGlass.x);
  float along = max(abs(d.x) - h.x, 0.0);
  float glass = uGlass.y * exp(-along / uGlass.z);
  // The cut edges: their outer dp, edged to a pixel.
  float edge = 1.0 - smoothstep(0.5, 1.5, min(p.y - uEdge.y, uEdge.z - p.y));
  float edges = uGlass.w * edge * exp(-along / uEdge.x);
  return core + pool + glass + edges;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  if (uBleed.w > 0.5 && p.y > uEdge.y && p.y < uEdge.z) {
    // Under the glass: its own light is drawn there.
    fragColor = vec4(0.0);
    return;
  }
  vec3 sum = vec3(0.0);
  if (uSpot0.y > 0.0) sum += uTint0.rgb * (uSpot0.y * light(p, uSpot0));
  if (uSpot1.y > 0.0) sum += uTint1.rgb * (uSpot1.y * light(p, uSpot1));
  if (uSpot2.y > 0.0) sum += uTint2.rgb * (uSpot2.y * light(p, uSpot2));
  if (uSpot3.y > 0.0) sum += uTint3.rgb * (uSpot3.y * light(p, uSpot3));
  vec3 shown = 1.0 - exp(-uEdge.w * sum);
  fragColor = vec4(shown, max(shown.r, max(shown.g, shown.b)));
}
