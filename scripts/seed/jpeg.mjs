// A small baseline JPEG encoder, so the seed (seed.mjs) can make real photos
// and profile pictures in Node with no dependencies: pics are JPEG inside
// their envelope (crypto.js, packMedia), and the server rebuilds profile and
// group pictures from JPEG, PNG, or WebP (images.rs). Colour (YCbCr, no
// subsampling), the standard tables from the JPEG spec (Annex K), one scan.
// Made for drawn pictures of a few hundred pixels, not for speed.

const ZIGZAG = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
];

const LUMA_Q = [
  16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
];
const CHROMA_Q = [
  17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
  ...new Array(32).fill(99),
];

// Huffman tables: how many codes of each length (1 to 16), then the symbols.
const DC_LUMA = { bits: [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], vals: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11] };
const DC_CHROMA = { bits: [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0], vals: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11] };
const AC_LUMA = {
  bits: [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d],
  vals: [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
  ],
};
const AC_CHROMA = {
  bits: [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77],
  vals: [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
  ],
};

/** Canonical codes: symbol -> [code, length]. */
function codes({ bits, vals }) {
  const out = new Map();
  let code = 0, k = 0;
  for (let len = 1; len <= 16; len++) {
    for (let i = 0; i < bits[len - 1]; i++) out.set(vals[k++], [code++, len]);
    code <<= 1;
  }
  return out;
}

/** The IJG quality scaling (1 to 100) of a base table. */
function scaled(base, quality) {
  const s = quality < 50 ? 5000 / quality : 200 - quality * 2;
  return base.map((q) => Math.min(255, Math.max(1, Math.floor((q * s + 50) / 100))));
}

// cos((2x + 1) u pi / 16), with the DCT's scale folded in.
const COS = Array.from({ length: 64 }, (_, i) => {
  const u = i >> 3, x = i & 7;
  return (u === 0 ? Math.SQRT1_2 : 1) * Math.cos(((2 * x + 1) * u * Math.PI) / 16) / 2;
});

/** 8x8 forward DCT, separable: rows, then columns. */
function fdct(block, out) {
  const tmp = new Float64Array(64);
  for (let y = 0; y < 8; y++) {
    for (let u = 0; u < 8; u++) {
      let s = 0;
      for (let x = 0; x < 8; x++) s += block[y * 8 + x] * COS[u * 8 + x];
      tmp[y * 8 + u] = s;
    }
  }
  for (let u = 0; u < 8; u++) {
    for (let v = 0; v < 8; v++) {
      let s = 0;
      for (let y = 0; y < 8; y++) s += tmp[y * 8 + u] * COS[v * 8 + y];
      out[v * 8 + u] = s;
    }
  }
}

class Bits {
  bytes = [];
  acc = 0;
  n = 0;
  put(value, length) {
    for (let i = length - 1; i >= 0; i--) {
      this.acc = (this.acc << 1) | ((value >> i) & 1);
      if (++this.n === 8) {
        this.bytes.push(this.acc);
        if (this.acc === 0xff) this.bytes.push(0); // a data 0xFF is stuffed
        this.acc = 0;
        this.n = 0;
      }
    }
  }
  finish() {
    if (this.n > 0) this.put(0x7f, 8 - this.n); // pad with ones
    return this.bytes;
  }
}

/** The bits that say a coefficient's value after its size category. */
function category(v) {
  const a = Math.abs(v);
  let size = 0;
  while (a >> size) size++;
  return [size, v < 0 ? v + (1 << size) - 1 : v];
}

/**
 * `pixel(x, y)` -> [r, g, b] (0 to 255) for each pixel of a `width` x
 * `height` picture. Returns the JPEG as a Uint8Array.
 */
export function encodeJpeg(width, height, pixel, quality = 85) {
  const lq = scaled(LUMA_Q, quality), cq = scaled(CHROMA_Q, quality);
  const tables = [
    { q: lq, dc: codes(DC_LUMA), ac: codes(AC_LUMA) },
    { q: cq, dc: codes(DC_CHROMA), ac: codes(AC_CHROMA) },
    { q: cq, dc: codes(DC_CHROMA), ac: codes(AC_CHROMA) },
  ];
  // The whole picture as Y, Cb, Cr, level-shifted around zero.
  const planes = [0, 1, 2].map(() => new Float64Array(width * height));
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const [r, g, b] = pixel(x, y);
      const i = y * width + x;
      planes[0][i] = 0.299 * r + 0.587 * g + 0.114 * b - 128;
      planes[1][i] = -0.168736 * r - 0.331264 * g + 0.5 * b;
      planes[2][i] = 0.5 * r - 0.418688 * g - 0.081312 * b;
    }
  }

  const out = new Bits();
  const emit = (map, symbol) => {
    const c = map.get(symbol);
    if (!c) throw new Error(`no Huffman code for ${symbol}`);
    out.put(c[0], c[1]);
  };
  const prevDc = [0, 0, 0];
  const block = new Float64Array(64), coef = new Float64Array(64);
  for (let by = 0; by < height; by += 8) {
    for (let bx = 0; bx < width; bx += 8) {
      for (let c = 0; c < 3; c++) {
        // Past the edge, repeat the last row and column.
        for (let y = 0; y < 8; y++) {
          for (let x = 0; x < 8; x++) {
            block[y * 8 + x] = planes[c][Math.min(by + y, height - 1) * width + Math.min(bx + x, width - 1)];
          }
        }
        fdct(block, coef);
        const t = tables[c];
        const zz = ZIGZAG.map((n) => Math.round(coef[n] / t.q[n]));
        const [dcSize, dcBits] = category(zz[0] - prevDc[c]);
        prevDc[c] = zz[0];
        emit(t.dc, dcSize);
        if (dcSize) out.put(dcBits, dcSize);
        let run = 0;
        for (let k = 1; k < 64; k++) {
          if (zz[k] === 0) {
            run++;
            continue;
          }
          while (run > 15) {
            emit(t.ac, 0xf0);
            run -= 16;
          }
          const [size, bits] = category(zz[k]);
          emit(t.ac, (run << 4) | size);
          out.put(bits, size);
          run = 0;
        }
        if (run > 0) emit(t.ac, 0x00);
      }
    }
  }
  const data = out.finish();

  const bytes = [];
  const u16 = (n) => bytes.push(n >> 8, n & 0xff);
  const segment = (marker, body) => {
    bytes.push(0xff, marker);
    u16(body.length + 2);
    bytes.push(...body);
  };
  bytes.push(0xff, 0xd8); // start of image
  segment(0xe0, [0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]); // JFIF
  segment(0xdb, [0, ...ZIGZAG.map((n) => lq[n]), 1, ...ZIGZAG.map((n) => cq[n])]);
  segment(0xc0, [8, height >> 8, height & 0xff, width >> 8, width & 0xff, 3, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1]);
  const dht = [];
  for (const [id, t] of [[0x00, DC_LUMA], [0x10, AC_LUMA], [0x01, DC_CHROMA], [0x11, AC_CHROMA]]) dht.push(id, ...t.bits, ...t.vals);
  segment(0xc4, dht);
  segment(0xda, [3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0]);
  for (const b of data) bytes.push(b);
  bytes.push(0xff, 0xd9); // end of image
  return Uint8Array.from(bytes);
}
