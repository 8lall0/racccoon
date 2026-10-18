#!/usr/bin/env python3
"""Turn a camcap /frame.raw (racccoon, docs/camera-plan.md Stage 4) into a PNG.

The CV1800B's CSI bridge write DMA stores 12-bit packed Bayer pixels, two
per 3 bytes (b0 b1 b2 -> p0 = b0<<4 | b2&0xf, p1 = b1<<4 | b2>>4), each line
padded to 16 bytes. The sensor's 10-bit samples sit in the top 10 bits.

  raw_to_png.py frame.raw W H out.png [--bayer RGGB|BGGR|GRBG|GBRG] [--gray]

Default: half-resolution colour, one RGB pixel per 2x2 Bayer quad, grey-world
white balanced. --gray
writes the raw samples at full resolution instead (always correct, whatever
the Bayer order). Stdlib only.
"""
import struct
import sys
import zlib


def stride_of(w):
    return (3 * ((w + 1) // 2) + 0xF) & ~0xF


def unpack(raw, w, h):
    s = stride_of(w)
    rows = []
    for y in range(h):
        line = raw[y * s:y * s + s]
        px = []
        for i in range(0, 3 * ((w + 1) // 2), 3):
            b0, b1, b2 = line[i], line[i + 1], line[i + 2]
            px.append((b0 << 4) | (b2 & 0xF))
            px.append((b1 << 4) | (b2 >> 4))
        rows.append(px[:w])
    return rows


def write_png(path, w, h, channels, rows):
    def chunk(tag, data):
        c = tag + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)
    color_type = 0 if channels == 1 else 2
    body = b''.join(b'\x00' + bytes(r) for r in rows)
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, color_type, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(body, 9))
           + chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)


def stretch(values):
    """Map the raw (linear) range onto 0..255 with a 1/2.2 display gamma —
    raw sensor values are linear light, a PNG is expected gamma-encoded."""
    lo, hi = min(values), max(values)
    span = max(hi - lo, 1)
    lut = {}
    def f(v):
        if v not in lut:
            lut[v] = int(255 * ((max(v - lo, 0) / span) ** (1 / 2.2)) + 0.5)
        return lut[v]
    return f


def main():
    opts = sys.argv[1:]
    bayer = 'RGGB'
    if '--bayer' in opts:
        i = opts.index('--bayer')
        bayer = opts[i + 1].upper()
        del opts[i:i + 2]
    args = [a for a in opts if not a.startswith('--')]
    if len(args) != 4 or sorted(bayer) != sorted('RGGB'):
        sys.exit(__doc__)
    src, w, h, out = args[0], int(args[1]), int(args[2]), args[3]
    raw = open(src, 'rb').read()
    if len(raw) < stride_of(w) * h:
        sys.exit('%s: %d bytes, %dx%d needs %d' % (src, len(raw), w, h, stride_of(w) * h))
    px = unpack(raw, w, h)
    flat = [v for r in px for v in r]
    print('pixels: min %d max %d mean %d' % (min(flat), max(flat), sum(flat) // len(flat)))

    if '--gray' in opts:
        f = stretch(flat)
        write_png(out, w, h, 1, [[f(v) for v in r] for r in px])
        print('wrote %s (%dx%d greyscale)' % (out, w, h))
        return

    pos = {c: [] for c in 'RGB'}
    for i, c in enumerate(bayer):
        pos[c].append((i // 2, i % 2))
    quads = []
    for y in range(0, h - 1, 2):
        row = []
        for x in range(0, w - 1, 2):
            rgb = [sum(px[y + dy][x + dx] for dy, dx in pos[c]) // len(pos[c]) for c in 'RGB']
            row.append(rgb)
        quads.append(row)
    # Grey-world white balance: scale R and B so their means match G's (raw
    # sensor data is green-heavy — green pixels see about twice the light).
    n = sum(len(r) for r in quads)
    mean = [sum(p[c] for r in quads for p in r) / n for c in range(3)]
    gain = [mean[1] / max(m, 1) for m in mean]
    quads = [[[min(int(p[c] * gain[c]), 4095) for c in range(3)] for p in r] for r in quads]
    print('white balance gains R %.2f G 1.00 B %.2f' % (gain[0], gain[2]))
    f = stretch([v for r in quads for p in r for v in p])
    write_png(out, len(quads[0]), len(quads), 3, [[f(v) for p in r for v in p] for r in quads])
    print('wrote %s (%dx%d colour, %s)' % (out, len(quads[0]), len(quads), bayer))


if __name__ == '__main__':
    main()
