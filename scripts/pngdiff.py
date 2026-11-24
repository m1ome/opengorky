"""pngdiff.py A.png B.png [MAX_PERCENT]: 4×4 blocks whose mean differs by more than 16 in
a channel, as a percent of the blocks; exit 1 when over MAX_PERCENT (default 0.2). Block
means pass texel-level noise (another mip level, a filter) and catch what is missing or
moved. Reads the viewer's shots (src/formats/png.zig: 8-bit RGBA, filter None) — stdlib only."""
import struct
import sys
import zlib

BLOCK = 4


def load(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path}: not a PNG"
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos : pos + 8])
        body = data[pos + 8 : pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, color = struct.unpack(">IIBB", body[:10])
            assert (depth, color) == (8, 6), f"{path}: not 8-bit RGBA"
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    row = w * 4 + 1
    assert all(raw[y * row] == 0 for y in range(h)), f"{path}: filtered rows"
    return w, h, b"".join(raw[y * row + 1 : (y + 1) * row] for y in range(h))


def sums(w, h, px):
    """Per block and channel, the sum of its pixels (blocks over the edge cut)."""
    bw = w // BLOCK
    out = [0] * (bw * (h // BLOCK) * 3)
    for y in range(h // BLOCK * BLOCK):
        base = (y // BLOCK) * bw * 3
        line = y * w * 4
        for x in range(bw * BLOCK):
            i = line + x * 4
            o = base + (x // BLOCK) * 3
            out[o] += px[i]
            out[o + 1] += px[i + 1]
            out[o + 2] += px[i + 2]
    return out


def main():
    wa, ha, a = load(sys.argv[1])
    wb, hb, b = load(sys.argv[2])
    limit = float(sys.argv[3]) if len(sys.argv) > 3 else 0.2
    if (wa, ha) != (wb, hb):
        sys.exit(f"size {wa}x{ha} vs {wb}x{hb}")
    sa, sb = sums(wa, ha, a), sums(wb, hb, b)
    n = len(sa) // 3
    k = 16 * BLOCK * BLOCK
    over = sum(1 for j in range(n) if max(abs(sa[3 * j + c] - sb[3 * j + c]) for c in range(3)) > k)
    pct = 100 * over / n
    print(f"{over} of {n} blocks ({pct:.2f}%) differ by more than 16")
    sys.exit(1 if pct > limit else 0)


main()
