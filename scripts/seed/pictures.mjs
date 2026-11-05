// Drawn pictures for the seed (seed.mjs): profile pictures, group pictures,
// and the photos sent as pics. Plain shapes and gradients, made as JPEG.

import { encodeJpeg } from "./jpeg.mjs";

const clamp = (v, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));
const mix = (a, b, t) => a.map((v, i) => v + (b[i] - v) * clamp(t));
/** 1 inside, 0 outside, a pixel of softness at the edge (no jagged outlines). */
const inside = (d) => clamp(0.5 - d);

function hsl(h, s, l) {
  const k = (n) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  return [0, 8, 4].map((n) => 255 * (l - a * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1))));
}

/** A head-and-shoulders figure on a coloured background, in the person's hue. */
export function avatar(hue) {
  const bg = hsl(hue, 0.55, 0.52), fg = hsl(hue, 0.6, 0.86);
  return encodeJpeg(256, 256, (x, y) => {
    const head = Math.hypot(x - 128, y - 104) - 50;
    const body = (Math.hypot((x - 128) / 92, (y - 252) / 84) - 1) * 84;
    return mix(bg, fg, Math.max(inside(head), inside(body)));
  });
}

/** Mountains under a clear sky, with a lake in front. */
export function mountains(w, h) {
  const peak = (x, cx, top, half) => top + (Math.abs(x - cx) / half) * (h * 0.62 - top);
  return encodeJpeg(w, h, (x, y) => {
    const ground = h * 0.62;
    if (y > ground) {
      // The lake mirrors the sky, darker, with a few ripples.
      const ripple = 0.08 * Math.sin(y * 0.9 + Math.sin(x * 0.05) * 2);
      return mix([70, 120, 170], [30, 60, 100], (y - ground) / (h - ground) + ripple);
    }
    let c = mix([120, 180, 235], [205, 230, 250], y / ground);
    const far = peak(x, w * 0.68, h * 0.2, w * 0.45);
    if (y > far) {
      c = mix([150, 165, 190], [110, 125, 150], (y - far) / (ground - far));
      if (y < h * 0.3) c = mix(c, [245, 248, 252], 0.85); // snow on the top
    }
    const near = peak(x, w * 0.3, h * 0.3, w * 0.4);
    if (y > near) c = mix([80, 110, 95], [50, 80, 65], (y - near) / (ground - near));
    return c;
  });
}

/** Book spines on a shelf. */
export function books(w, h) {
  const spines = [];
  for (let x = w * 0.08, i = 0; x < w * 0.92; i++) {
    const width = w * (0.05 + ((i * 37) % 7) / 100);
    spines.push({ x, width, top: h * (0.22 + ((i * 53) % 9) / 60), color: hsl((i * 67) % 360, 0.45, 0.45) });
    x += width + 3;
  }
  return encodeJpeg(w, h, (x, y) => {
    if (y > h * 0.78) return mix([120, 80, 50], [90, 58, 36], (y - h * 0.78) / (h * 0.22));
    const s = spines.find((b) => x >= b.x && x < b.x + b.width && y >= b.top);
    if (s) {
      const band = Math.abs(y - (s.top + h * 0.08)) < 4 ? 0.35 : 0;
      return mix(s.color, [235, 215, 160], band);
    }
    return mix([245, 232, 210], [225, 205, 180], y / h);
  });
}

/** The sun going down over the sea. */
export function sunset(w, h) {
  const horizon = h * 0.62, sun = { x: w * 0.5, y: horizon - h * 0.05, r: w * 0.12 };
  return encodeJpeg(w, h, (x, y) => {
    if (y > horizon) {
      const sea = mix([70, 50, 90], [25, 20, 50], (y - horizon) / (h - horizon));
      // The sun's path on the water: broken streaks, narrowing towards us.
      const spread = w * 0.04 + (y - horizon) * 0.25;
      const streak = Math.sin(y * 1.3) > 0.2 ? clamp(1 - Math.abs(x - sun.x) / spread) : 0;
      return mix(sea, [255, 190, 120], streak * 0.8);
    }
    let c = y < horizon * 0.5
      ? mix([45, 35, 95], [190, 80, 110], y / (horizon * 0.5))
      : mix([190, 80, 110], [255, 170, 100], (y - horizon * 0.5) / (horizon * 0.5));
    const d = Math.hypot(x - sun.x, y - sun.y);
    c = mix(c, [255, 210, 150], clamp(1 - (d - sun.r) / (w * 0.25)) * 0.5); // the glow
    return mix(c, [255, 236, 190], inside(d - sun.r));
  });
}
