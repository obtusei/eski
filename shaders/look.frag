#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

// eski look engine — one shader drives the live viewfinder, the editor
// preview, gallery thumbnails and full-resolution export, so a look renders
// identically everywhere. Uniform order is mirrored in look_engine.dart.

uniform vec2 uSize;   // texture size in px (set by the engine in filter mode)
uniform vec4 uCrop;   // output frame inside the texture: left, top, width, height (uv)
uniform float uScale; // detail scale multiplier
uniform float uSeed;  // grain animation seed
uniform vec4 uA;      // exposure, brightness, contrast, highlights
uniform vec4 uB;      // shadows, whites, blacks, saturation
uniform vec4 uC;      // vibrance, temperature, tint, hue
uniform vec4 uD;      // sharpness, clarity, texture, dehaze
uniform vec4 uE;      // fade, grain, grainSize, vignette
uniform vec4 uF;      // bloom, glow, halation, blur
uniform vec4 uG;      // chroma, leak, dust, borderSize
uniform vec4 uH;      // borderStyle, leakSeed, peaking, hslOn
uniform vec4 uSh;     // shadow tint rgb + luminance
uniform vec4 uMid;    // midtone tint rgb + luminance
uniform vec4 uHi;     // highlight tint rgb + luminance
uniform vec4 uMisc;   // gradingBalance, filterMode, frameAspect, quarterTurns
uniform vec4 uHslH0;
uniform vec4 uHslH1;
uniform vec4 uHslS0;
uniform vec4 uHslS1;
uniform vec4 uHslL0;
uniform vec4 uHslL1;
uniform vec4 uAccent; // peaking colour rgb, digital noise amount
uniform vec4 uM;      // motion blur, motion angle (0..1 = 0..180°), smudge, lens blur
uniform sampler2D uTex;
uniform sampler2D uCurve;

out vec4 fragColor;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

float hash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

vec2 fixUv(vec2 uv) {
#ifdef IMPELLER_TARGET_OPENGLES
  if (uMisc.y > 0.5) uv.y = 1.0 - uv.y;
#endif
  return uv;
}

vec3 tex(vec2 uv) { return texture(uTex, fixUv(clamp(uv, 0.0, 1.0))).rgb; }

// 12-tap golden-angle disc; r in pixels.
vec3 disc(vec2 uv, float r, float jitter) {
  vec2 px = 1.0 / uSize;
  float a0 = jitter * hash(uv * uSize) * 6.2831853;
  vec3 s = vec3(0.0);
  for (int i = 0; i < 12; i++) {
    float t = float(i);
    float rr = sqrt((t + 0.5) / 12.0) * r;
    float an = a0 + t * 2.3999632;
    s += tex(uv + vec2(cos(an), sin(an)) * rr * px);
  }
  return s / 12.0;
}

// Streak along d (pixels) through uv: a camera moving during the exposure.
// Smudge bends each tap through a slow noise field, like a finger drag.
vec3 streak(vec2 uv, vec2 d, float smudge, float sc) {
  vec2 px = 1.0 / uSize;
  float j = hash(uv * uSize + 3.7) - 0.5;
  vec3 s = vec3(0.0);
  float ws = 0.0;
  for (int i = 0; i < 20; i++) {
    float t = (float(i) + 0.5 + j) / 20.0 - 0.5;
    vec2 p = uv + d * t * px;
    if (smudge > 0.0) {
      vec2 np = p * uSize / (70.0 * sc);
      p += (vec2(vnoise(np), vnoise(np + 13.7)) - 0.5) * smudge * 26.0 * sc * px * (0.3 + abs(t) * 1.6);
    }
    float w = 1.0 - abs(t) * 0.9;
    s += tex(p) * w;
    ws += w;
  }
  return s / ws;
}

// Lens blur: a wide golden-angle disc that lets highlights bloom into
// discs the way an open aperture renders out-of-focus light.
vec3 bokeh(vec2 uv, float r) {
  vec2 px = 1.0 / uSize;
  float a0 = hash(uv * uSize) * 6.2831853;
  vec3 s = vec3(0.0);
  float ws = 0.0;
  for (int i = 0; i < 40; i++) {
    float t = float(i);
    float rr = sqrt((t + 0.5) / 40.0) * r;
    float an = a0 + t * 2.3999632;
    vec3 k = tex(uv + vec2(cos(an), sin(an)) * rr * px);
    float w = 1.0 + 7.0 * pow(dot(k, LUMA), 4.0);
    s += k * w;
    ws += w;
  }
  return s / ws;
}

vec3 rgb2hsv(vec3 c) {
  vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
  vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
  vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
  float d = q.x - min(q.w, q.y);
  float e = 1.0e-10;
  return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
  vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
  vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
  return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

float band(float h, float center, float width) {
  float d = abs(h - center);
  d = min(d, 1.0 - d);
  return max(0.0, 1.0 - d / width);
}

vec3 screenBlend(vec3 a, vec3 b) { return 1.0 - (1.0 - a) * (1.0 - clamp(b, 0.0, 1.0)); }

float sdBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float sc = max(uSize.x, uSize.y) / 1500.0 * uScale;
  vec2 q = (uv - uCrop.xy) / uCrop.zw; // 0..1 inside the output frame
  vec2 cq = q - 0.5;
  int turns = int(uMisc.w + 0.5); // rotate into the output frame's orientation
  if (turns == 1) cq = vec2(-cq.y, cq.x);
  else if (turns == 2) cq = -cq;
  else if (turns == 3) cq = vec2(cq.y, -cq.x);
  q = cq + 0.5;
  float aspect = uMisc.z;

  vec4 src = texture(uTex, fixUv(uv));
  vec3 c = src.rgb;

  // motion blur and smudge, in the output frame's direction
  bool soft = false;
  if (uM.x > 0.0 || uM.z > 0.0) {
    float an = uM.y * 3.14159265;
    vec2 dir = vec2(cos(an), sin(an));
    if (turns == 1) dir = vec2(dir.y, -dir.x);
    else if (turns == 2) dir = -dir;
    else if (turns == 3) dir = vec2(-dir.y, dir.x);
    vec2 d = dir * uM.x * 90.0 * sc;
    if (uM.z > 0.0) {
      float na = vnoise(uv * uSize / (160.0 * sc) + 5.0) * 12.566;
      d += vec2(cos(na), sin(na)) * uM.z * 40.0 * sc;
    }
    c = streak(uv, d, uM.z, sc);
    soft = true;
  }
  // lens blur (portrait background)
  if (uM.w > 0.0) {
    c = bokeh(uv, uM.w * 36.0 * sc);
    soft = true;
  }

  // chromatic aberration
  if (uG.x > 0.0 && !soft) {
    vec2 d = cq * uCrop.zw * uG.x * 0.016;
    c.r = tex(uv + d).r;
    c.b = tex(uv - d).b;
  }

  // detail
  vec3 large = vec3(0.0);
  bool needLarge = uD.y != 0.0 || uF.x > 0.0 || uF.y > 0.0 || uF.z > 0.0;
  if (needLarge) large = disc(uv, 26.0 * sc, 1.0);
  // Detail is taken from the sharp source, so it is skipped once softened.
  if (uD.x > 0.0 && !soft) c += (c - disc(uv, 1.3 * sc, 0.0)) * uD.x * 1.6;
  if (uD.z != 0.0 && !soft) c += (c - disc(uv, 4.5 * sc, 0.0)) * uD.z * 0.9;
  if (uD.y != 0.0 && !soft) {
    float l0 = dot(c, LUMA);
    float mid = 1.0 - abs(l0 * 2.0 - 1.0);
    c += (c - large) * uD.y * 0.7 * (0.35 + 0.65 * mid);
  }
  if (uF.w > 0.0) c = mix(c, disc(uv, uF.w * 22.0 * sc, 1.0), min(1.0, uF.w * 3.0));
  c = max(c, 0.0);

  // white balance
  float temp = uC.y;
  float tint = uC.z;
  c *= vec3(1.0 + 0.22 * temp, 1.0 - 0.14 * tint, 1.0 - 0.22 * temp);
  c *= 1.0 / (1.0 - 0.05 * tint);

  // exposure in approximately linear light, with a soft shoulder
  if (uA.x != 0.0) {
    vec3 lin = pow(c, vec3(2.2)) * exp2(uA.x * 2.0);
    lin = lin / (1.0 + max(lin - 0.8, 0.0) * 0.6);
    c = pow(lin, vec3(1.0 / 2.2));
  }
  // brightness (midtone gamma)
  if (uA.y != 0.0) c = pow(max(c, 0.0), vec3(exp2(-uA.y * 0.9)));
  // contrast
  if (uA.z > 0.0) {
    vec3 cc = clamp(c, 0.0, 1.0);
    c = mix(c, cc * cc * (3.0 - 2.0 * cc), uA.z * 0.9);
  } else if (uA.z < 0.0) {
    c = (c - 0.5) * (1.0 + uA.z * 0.6) + 0.5;
  }

  // tonal regions
  float l = clamp(dot(c, LUMA), 0.0, 1.0);
  float hiW = smoothstep(0.45, 1.0, l);
  float shW = (1.0 - smoothstep(0.0, 0.55, l)) * smoothstep(0.0, 0.06, l + 0.03);
  c += uA.w * 0.32 * hiW * (uA.w < 0.0 ? c : (1.0 - c) + 0.25);
  c += uB.x * 0.34 * shW * (uB.x > 0.0 ? (1.0 - c) : c + 0.2);
  c *= 1.0 + uB.y * 0.28 * l * l;
  c += uB.z * 0.22 * pow(1.0 - l, 3.0);

  // dehaze: pull the black point, steepen, saturate
  if (uD.w != 0.0) {
    float h = uD.w;
    c = (c - 0.09 * h) / (1.0 - 0.09 * abs(h));
    float lh = dot(c, LUMA);
    c = mix(vec3(lh), c, 1.0 + 0.3 * h);
    c = mix(c, c * c * (3.0 - 2.0 * c), clamp(h, 0.0, 1.0) * 0.35);
  }

  // tone + RGB curves (256x1 LUT built in Dart from preset and user curves)
  c = clamp(c, 0.0, 1.0);
  c.r = texture(uCurve, vec2(c.r * 0.99609375 + 0.001953125, 0.5)).r;
  c.g = texture(uCurve, vec2(c.g * 0.99609375 + 0.001953125, 0.5)).g;
  c.b = texture(uCurve, vec2(c.b * 0.99609375 + 0.001953125, 0.5)).b;

  // HSL / selective colour: red, orange, yellow, green, aqua, blue, purple, magenta
  if (uH.w > 0.5) {
    vec3 hsv = rgb2hsv(c);
    float h = hsv.x;
    float w0 = band(h, 0.0, 0.07);
    float w1 = band(h, 0.083, 0.07);
    float w2 = band(h, 0.167, 0.09);
    float w3 = band(h, 0.333, 0.16);
    float w4 = band(h, 0.5, 0.11);
    float w5 = band(h, 0.64, 0.12);
    float w6 = band(h, 0.77, 0.1);
    float w7 = band(h, 0.89, 0.1);
    vec4 wa = vec4(w0, w1, w2, w3);
    vec4 wb = vec4(w4, w5, w6, w7);
    float sw = smoothstep(0.02, 0.25, hsv.y);
    float dh = dot(wa, uHslH0) + dot(wb, uHslH1);
    float ds = dot(wa, uHslS0) + dot(wb, uHslS1);
    float dl = dot(wa, uHslL0) + dot(wb, uHslL1);
    hsv.x = fract(hsv.x + dh * 0.12 * sw + 1.0);
    hsv.y = clamp(hsv.y * (1.0 + ds), 0.0, 1.0);
    hsv.z = clamp(hsv.z * (1.0 + dl * 0.6 * sw), 0.0, 1.0);
    c = hsv2rgb(hsv);
  }

  // global hue
  if (uC.w != 0.0) {
    vec3 hsv = rgb2hsv(c);
    hsv.x = fract(hsv.x + uC.w * 0.5 + 1.0);
    c = hsv2rgb(hsv);
  }
  // saturation + vibrance
  l = dot(c, LUMA);
  float mx = max(c.r, max(c.g, c.b));
  float mn = min(c.r, min(c.g, c.b));
  float vib = uC.x * (1.0 - (mx - mn)) * 0.9;
  c = mix(vec3(l), c, max(0.0, (1.0 + uB.w) * (1.0 + vib)));

  // colour grading: three-way tint with balance
  l = clamp(dot(c, LUMA), 0.0, 1.0);
  float pivot = 0.5 + uMisc.x * 0.3;
  float gs = 1.0 - smoothstep(0.0, pivot + 0.15, l);
  float gh = smoothstep(pivot - 0.15, 1.0, l);
  float gm = max(0.0, 1.0 - gs - gh);
  c += uSh.rgb * gs + uMid.rgb * gm + uHi.rgb * gh;
  c += uSh.a * 0.25 * gs + uMid.a * 0.25 * gm + uHi.a * 0.25 * gh;

  // fade (matte blacks)
  c = c * (1.0 - uE.x * 0.22) + uE.x * 0.16;
  c = max(c, 0.0);

  // glow, bloom, halation from the wide blur
  if (needLarge) {
    float bl = dot(large, LUMA);
    if (uF.y > 0.0) c = mix(c, screenBlend(c, large * 0.85), uF.y * 0.6);
    if (uF.x > 0.0) c = screenBlend(c, large * smoothstep(0.55, 1.0, bl) * uF.x * 1.1);
    if (uF.z > 0.0) {
      float edge = smoothstep(0.6, 1.0, bl) * (1.0 - smoothstep(0.75, 1.0, l) * 0.7);
      c = screenBlend(c, vec3(1.0, 0.22, 0.08) * edge * uF.z * 0.95);
    }
  }

  // vignette (frame space)
  if (uE.w != 0.0) {
    float v = smoothstep(0.3, 1.5, length(cq * 2.0));
    c = uE.w > 0.0 ? c * (1.0 - uE.w * v * 0.9) : mix(c, vec3(1.0), -uE.w * v * 0.7);
  }

  // light leak
  if (uG.y > 0.0) {
    float s = uH.y;
    float a = hash(vec2(s, 1.7)) * 6.2831853;
    vec2 dir = vec2(cos(a), sin(a));
    float t = dot(cq, dir) + 0.5 + 0.12 * sin(dot(cq, dir.yx) * 5.0 + s * 3.0);
    float bandW = smoothstep(0.5, 1.15, t);
    float core = smoothstep(0.85, 1.25, t);
    vec3 col = mix(vec3(1.0, 0.28, 0.08), vec3(1.0, 0.82, 0.45), core);
    c = screenBlend(c, col * bandW * uG.y * 1.1);
  }

  // dust and scratches
  if (uG.z > 0.0) {
    vec2 g = q * vec2(max(aspect, 0.01), 1.0) * 34.0;
    vec2 id = floor(g);
    float r = hash(id + 11.0);
    if (r > 1.0 - 0.05 * uG.z) {
      vec2 ctr = vec2(hash(id + 3.1), hash(id + 7.3)) * 0.7 + 0.15;
      float rad = 0.03 + 0.09 * hash(id + 5.5);
      float speck = 1.0 - smoothstep(rad * 0.4, rad, length(fract(g) - ctr));
      c = mix(c, vec3(hash(id + 9.0) > 0.4 ? 0.96 : 0.05), speck * 0.8);
    }
    float col = floor(q.x * 260.0);
    float sr = hash(vec2(col, 4.2));
    if (sr > 1.0 - 0.012 * uG.z) {
      float y0 = hash(vec2(col, 8.8));
      float len = 0.15 + 0.5 * hash(vec2(col, 2.1));
      float on = step(y0, q.y) * step(q.y, y0 + len);
      float line = 1.0 - smoothstep(0.0, 0.5, abs(fract(q.x * 260.0) - 0.5));
      c = mix(c, vec3(0.93), on * line * 0.45);
    }
  }

  // grain: two octaves of value noise, strongest in the midtones
  if (uE.y > 0.0) {
    float gsz = (0.9 + uE.z * 2.6) * sc;
    vec2 gp = FlutterFragCoord().xy / gsz + uSeed * 37.0;
    float n = vnoise(gp) * 0.65 + vnoise(gp * 2.03 + 17.0) * 0.35 - 0.5;
    float gl = dot(c, LUMA);
    c += n * uE.y * 0.42 * (1.0 - 0.55 * pow(abs(gl * 2.0 - 1.0), 2.0));
  }

  // digital noise: fine per-pixel chroma noise, unlike the soft clumps of grain
  if (uAccent.a > 0.0) {
    vec2 np = floor(FlutterFragCoord().xy / max(1.0, sc * 0.7)) + uSeed * 91.0;
    vec3 n = vec3(hash(np), hash(np + 19.19), hash(np + 47.7)) - 0.5;
    float nl = dot(c, LUMA);
    c += n * uAccent.a * 0.4 * (1.0 - 0.5 * nl);
  }

  // focus peaking (viewfinder only)
  if (uH.z > 0.5) {
    vec2 px = 1.5 / uSize;
    float gx = dot(tex(uv + vec2(px.x, 0.0)) - tex(uv - vec2(px.x, 0.0)), LUMA);
    float gy = dot(tex(uv + vec2(0.0, px.y)) - tex(uv - vec2(0.0, px.y)), LUMA);
    float e = smoothstep(0.09, 0.2, length(vec2(gx, gy)));
    c = mix(c, uAccent.rgb, e);
  }

  // film borders: 1 white, 2 black, 3 print (deep bottom), 4 35mm strip
  if (uH.x > 0.5 && uG.w > 0.0) {
    vec2 ext = aspect >= 1.0 ? vec2(aspect, 1.0) : vec2(1.0, 1.0 / aspect);
    vec2 p = cq * ext; // short side spans -0.5..0.5
    vec2 half_ = ext * 0.5;
    float b = uG.w * 0.12;
    int style = int(uH.x + 0.5);
    if (style == 4) {
      float bar = b * 1.5 + 0.02;
      float dEdge = half_.y - abs(p.y);
      if (aspect < 1.0) dEdge = half_.x - abs(p.x);
      if (dEdge < bar) {
        float along = aspect < 1.0 ? p.y : p.x;
        float period = bar * 1.25;
        vec2 hp = vec2(fract(along / period) - 0.5, (dEdge / bar) - 0.5);
        float hole = sdBox(hp * vec2(period, bar), vec2(period * 0.24, bar * 0.2), bar * 0.06);
        c = hole < 0.0 ? vec3(0.9, 0.88, 0.84) : vec3(0.035);
      }
    } else {
      vec2 inner = half_ - b;
      vec2 pc = p;
      if (style == 3) {
        inner.y -= b * 1.1;
        pc.y += b * 1.1;
      }
      if (sdBox(pc, inner, 0.0) > 0.0) {
        c = style == 2 ? vec3(0.03) : (style == 3 ? vec3(0.955, 0.94, 0.905) : vec3(1.0));
      }
    }
  }

  fragColor = vec4(clamp(c, 0.0, 1.0) * src.a, src.a);
}
