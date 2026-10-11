#!/usr/bin/env python3
"""Print the screen of a cast at given times (or every N seconds) using pyte. castdump.py file.cast step|t1,t2"""
import json, sys, pyte
lines = open(sys.argv[1]).read().splitlines()
h = json.loads(lines[0]); ev = [json.loads(l) for l in lines[1:]]
scr = pyte.Screen(h["width"], h["height"]); st = pyte.Stream(scr)
arg = sys.argv[2]
times = [float(x) for x in arg.split(",")] if "," in arg else [i * float(arg) for i in range(int(ev[-1][0] / float(arg)) + 2)]
i = 0
for t in times:
    while i < len(ev) and ev[i][0] <= t:
        if ev[i][1] == "o": st.feed(ev[i][2])
        elif ev[i][1] == "m": print(f"   [mark {ev[i][2]} @ {ev[i][0]:.2f}]")
        i += 1
    print(f"===== t={t:.2f}")
    print("\n".join(l.rstrip() for l in scr.display).rstrip())
