# How qr.js works

[`server/static/qr.js`](../server/static/qr.js) turns an invite link into a QR code, entirely in the browser. It's about 300 lines and has no dependencies. This walks through it top to bottom; read it with the file open.

## Why napsack has its own

The web app's security policy only lets the page run napsack's own scripts: no CDNs, no third-party code (see Code standards in [CLAUDE.md](../CLAUDE.md)). A QR library would have to be copied in and reviewed anyway, and a QR encoder for one job (a short link) is small. So it's written here, and checked against an independent encoder (see [How we know it's right](#how-we-know-its-right)).

It does exactly what invite links need and no more:

| | |
|---|---|
| QR flavor | Model 2 (the normal one every phone camera reads) |
| Encoding | Byte mode: the text as UTF-8 bytes |
| Error correction | Level M (about 15% of the code can be damaged or covered and it still scans) |
| Sizes | Versions 1 to 10: 21 × 21 up to 57 × 57 modules, up to 213 bytes |

An invite link like `https://napsack.getattr.com/i/` plus a 22-character token is 52 bytes, which lands on **version 4: 33 × 33 modules**.

## What a QR code is made of

A QR code is a square grid of **modules** (the black and white squares). Some modules are fixed patterns that help a camera find and straighten the code; the rest carry data.

```
 ███████ . . . . . . . ███████      finder patterns (three corners): "this is a QR code,
 █     █ . . . . . . . █     █      and it's this way up"
 █ ███ █ . . data. . . █ ███ █
 █ ███ █ . . . . . . . █ ███ █      timing patterns (row 6 and column 6): alternating
 █     █ . . . . . . . █     █      dark/light, so the camera can count columns
 ███████ █ █ █ █ █ █ █ ███████
         . . . . . . . . . . .      alignment patterns (small squares, version 2 and up):
 . . . . . . data . . . . . .       help with bent or angled photos
 . . . . . . . . . . . ▣ . . .
 ███████ . . . . . . . . . . .      format info (beside the finders): which error
 █     █ . . . . . . . . . . .      correction level and which mask (below)
 █ ███ █ . . . data. . . . . .
 ███████ . . . . . . . . . . .      version info (version 7 and up)
```

Everything else is data: your text, plus error correction codewords that let a phone recover from smudges, glare, or a bad angle.

## The pipeline

`qrMatrix(text)` runs these steps. Each one is a function in the file.

### 1. Pick the smallest version that fits

A version's capacity depends on how many modules are left after the fixed patterns (`rawDataModules`) and how many of those go to error correction at level M (`ECC_PER_BLOCK`, `BLOCKS`). `dataCodewords(ver)` is what's left for data, in bytes. `qrMatrix` tries versions 1, 2, 3, ... until the text, plus a 4-bit header and a length field, fits.

### 2. Turn the text into bits (`dataBits`)

1. `0100`: "byte mode follows".
2. The length in bytes: 8 bits for versions 1 to 9, 16 bits for version 10.
3. The text's UTF-8 bytes.
4. Up to four `0` bits ("end"), then zeros to the next whole byte.
5. Pad bytes `0xEC`, `0x11`, `0xEC`, `0x11`, ... until the version's data capacity is full. (These two values are the standard's: their bit pattern scans well.)

The result is a list of **codewords** (bytes).

### 3. Add error correction (`withErrorCorrection`)

The data is split into **blocks**, and each block gets its own error correction codewords from a **Reed-Solomon** code, the same family of math that lets scratched CDs play.

- **The arithmetic** (`gfMul`) is in a 256-element "Galois field": bytes are multiplied in a way where every non-zero byte has an inverse. That's what makes recovery possible. `0x11D` is the standard's choice of field.
- **The divisor** (`rsDivisor`) is a fixed polynomial for the number of error correction codewords per block.
- **The remainder** (`rsRemainder`) is polynomial long division: the block's data divided by the divisor. The remainder *is* the error correction, appended to the block. A reader can detect and repair errors because a correct block divides evenly.

Bigger versions use several blocks (version 4 at level M uses two), and some blocks are one byte longer than others. The blocks are then **interleaved**: the first byte of each block, then the second of each, and so on. A smudge then damages a little of every block instead of all of one. The placeholder pushed onto short blocks keeps the columns lined up, and is skipped when interleaving.

### 4. Draw the fixed patterns (`draw`, first half)

The grid has two layers: `dark` (the color of each module) and `fixed` (whether it's a pattern, so data must skip it).

- **Timing** patterns along row and column 6.
- **Finder** patterns in three corners: 7 × 7 rings, plus a light separator around each.
- **Alignment** patterns: 5 × 5 rings at positions from `alignmentPositions`, skipping the three that would overlap finders.
- **Format info** is drawn as a placeholder (so its modules are reserved), then drawn for real after masking.
- **Version info** (version 7 and up): the version number with its own error correction (a BCH code), in two 6 × 3 blocks.

### 5. Place the data (`draw`, the zigzag)

The codewords' bits snake through the grid in two-module-wide columns, from the bottom-right corner: up the first column pair, down the next, and so on, skipping fixed modules and the vertical timing column. This exact path is what a reader follows to read the bits back.

### 6. Mask it (`MASKS`, `penalty`)

Raw data can produce patterns that confuse a camera: big solid areas, or shapes that look like a finder pattern. So the data area is XOR-ed with one of eight **masks**, fixed checkerboard-like patterns such as "flip every module where (x + y) is even". `MASKS` lists all eight formulas from the standard.

`qrMatrix` draws the code with each mask and keeps the one with the lowest **penalty**, a score for the standard's four "hard to scan" rules: long runs of one color, 2 × 2 blocks, finder-like sequences, and too much dark or light overall. The score is an approximation; any mask produces a valid code, the penalty just picks one that's easiest on cameras.

### 7. Write the format info (`formatBits`)

Fifteen bits record the error correction level (M is `00`) and the mask number, protected by their own BCH error correction (`0x537`) and XOR-ed with `0x5412` so they're never all zeros. They're written twice, around the finders, so a reader can still find them if one copy is damaged. One module beside the bottom-left finder is always dark.

## Drawing it on screen (`qrSvg`)

`qrSvg(text, label)` turns the grid into an SVG: a white square with a four-module quiet zone (the standard's margin; scanners need it) and one `<path>` containing a small square for every dark module. It's built with DOM calls, so it stays within the page's security policy, and it carries an `aria-label` for screen readers.

**Watch out for the app's icon styles.** `style.css` styles every `<svg>` as a line icon (`fill: none; stroke: currentColor` with rounded joins). Applied to a QR code, that draws pale outlines instead of solid squares, and no phone can scan it. The rules under `.invite-qr svg` in `style.css` undo that. Any new place that shows a QR code needs the same.

## How we know it's right

A QR encoder can look fine and still not scan, so `tests/e2e/test_invites.py` checks it two ways:

1. **Against an independent encoder.** For five texts (from 1 byte to 200, versions 1 to 10) and all eight masks, the grid from `qrMatrix` must match Python's `qrcode` library module for module, and so must the mask `qrMatrix` picks on its own. That checks every step from bits to error correction to placement.
2. **On screen, pixel by pixel.** It screenshots the rendered code in the Friends sheet and checks that every module, and the white quiet zone, is the right color. That's the check that caught the icon-style problem above: the grid was right, but what was on screen wasn't.

## Changing it

- **A longer text** than 213 bytes would need versions above 10: their entries in `ECC_PER_BLOCK` and `BLOCKS`, and nothing else (the 16-bit length field is already handled). The tables for every version are in the standard and in most QR references.
- **A different error correction level** means swapping both tables and `FORMAT_LEVEL_M` (L is `01`, Q is `11`, H is `10`).
- Whatever you change, the comparison test above is the safety net: add your new case to its samples.

## Further reading

- The standard: ISO/IEC 18004 (QR Code). The tables and formulas here come from it.
- Project Nayuki, "Creating a QR Code step by step": an excellent illustrated walkthrough of the same pipeline, and the most readable reference implementation.
- Thonky's QR Code Tutorial: every table, with worked examples.
