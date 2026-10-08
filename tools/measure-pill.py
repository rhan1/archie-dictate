#!/usr/bin/env python3
"""G2 gate: measure the pill capsule in a `screencapture -R` crop.

usage: measure-pill.py <png> <backingScaleFactor> [expect_w expect_h tol]
The capsule is the block of dark NEUTRAL pixels (max-min <= 4, max <= 45) —
Warp's background is blue-tinted, so it never counts. Rows/columns qualify when
at least 40% (rows) / 10% (columns, so the rounded ends count) of the densest is capsule. Prints the size in points and
PASS/FAIL against the expected size (default 100x28 +/- 2).
"""
import sys
from PIL import Image

path, scale = sys.argv[1], float(sys.argv[2])
ew, eh, tol = (float(a) for a in (sys.argv[3:6] if len(sys.argv) >= 6 else (100, 28, 2)))
im = Image.open(path).convert("RGB")
w, h = im.size
px = im.load()

def dark_neutral(p):
    return max(p) - min(p) <= 4 and max(p) <= 45

mask = [[dark_neutral(px[x, y]) for x in range(w)] for y in range(h)]
rows = [sum(r) for r in mask]
peak_row = max(rows) or 1
ys = [y for y, c in enumerate(rows) if c >= 0.4 * peak_row]
cols = [sum(mask[y][x] for y in ys) for x in range(w)]
peak_col = max(cols) or 1
xs = [x for x, c in enumerate(cols) if c >= 0.1 * peak_col]
if not xs or not ys or max(rows) == 0:
    print(f"capsule: none found in {w}x{h}px  -> FAIL")
    sys.exit(1)
bw, bh = xs[-1] - xs[0] + 1, ys[-1] - ys[0] + 1
pw, ph = bw / scale, bh / scale
ok = abs(pw - ew) <= tol and abs(ph - eh) <= tol
print(f"capsule bbox {bw}x{bh}px @{scale:g}x = {pw:.1f}x{ph:.1f}pt (expect {ew:g}x{eh:g}±{tol:g}) -> {'PASS' if ok else 'FAIL'}")
sys.exit(0 if ok else 1)
