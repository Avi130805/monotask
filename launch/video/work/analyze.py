#!/usr/bin/env python3
"""Measure every notch frame: body bounds from alpha, and the hold-button rect (diff v12a vs v12b).
Writes work/film/notch.json."""
import json, os, glob
import numpy as np
from PIL import Image
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "assets", "notch")
out = {"frames": {}}
for p in sorted(glob.glob(os.path.join(SRC, "*.png"))):
    name = os.path.basename(p)[:-4]
    a = np.array(Image.open(p).convert("RGBA"))
    alpha = a[:, :, 3]
    ys, xs = np.where(alpha > 250)
    x0, x1, y0, y1 = int(xs.min()), int(xs.max()) + 1, int(ys.min()), int(ys.max()) + 1
    # The body proper (without the top ear flares): its extent at mid height.
    mid = np.where(alpha[(y0 + y1) // 2] > 250)[0]
    bx0, bx1 = int(mid.min()), int(mid.max()) + 1
    # Bottom corner radius, estimated from how far in the last row starts.
    row = np.where(alpha[y1 - 1] > 250)[0]
    radius = round((int(row.min()) - bx0) * 1.1)
    out["frames"][name] = {"x": bx0, "y": y0, "w": bx1 - bx0, "h": y1 - y0, "r": radius,
                           "bbox": [x0, y0, x1 - x0, y1 - y0], "size": [a.shape[1], a.shape[0]]}
a = np.array(Image.open(os.path.join(SRC, "v12a-holding-start.png")).convert("RGBA")).astype(int)
b = np.array(Image.open(os.path.join(SRC, "v12b-holding-full.png")).convert("RGBA")).astype(int)
d = np.abs(a - b).sum(axis=2) > 24
ys, xs = np.where(d)
out["hold"] = {"x": int(xs.min()), "y": int(ys.min()), "w": int(xs.max() - xs.min() + 1),
               "h": int(ys.max() - ys.min() + 1)}
os.makedirs(os.path.join(HERE, "film"), exist_ok=True)
json.dump(out, open(os.path.join(HERE, "film", "notch.json"), "w"), indent=1)
for k, v in out["frames"].items():
    print(f"{k:24s} {v['x']:5d} {v['y']:4d} {v['w']:5d} {v['h']:5d} r={v['r']}")
print("hold", out["hold"])
