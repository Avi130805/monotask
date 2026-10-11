#!/usr/bin/env python3
"""Bundle the film's inputs into work/film/data.js: notch measurements and the chosen take(s).
The cast's output bytes are copied verbatim; only timestamps index into them."""
import json, os, sys
import pyte
HERE = os.path.dirname(os.path.abspath(__file__))
V = os.path.dirname(HERE)

def load_cast(path):
    lines = open(path).read().splitlines()
    return json.loads(lines[0]), [json.loads(l) for l in lines[1:]]

def find_row(header, events, t, needle):
    scr = pyte.Screen(header["width"], header["height"]); st = pyte.Stream(scr)
    for e in events:
        if e[0] > t: break
        if e[1] == "o": st.feed(e[2])
    for i, line in enumerate(scr.display):
        if needle in line: return i
    raise SystemExit(f"{needle!r} not on screen at t={t}")

takes = json.load(open(os.path.join(V, "record", "chosen.json")))
data = {"notch": json.load(open(os.path.join(HERE, "film", "notch.json"))), "casts": {}}
for key, spec in takes.items():
    h, ev = load_cast(os.path.join(V, "record", "takes", spec["take"] + ".cast"))
    rows = {name: find_row(h, ev, q["t"], q["text"]) for name, q in spec.get("rows", {}).items()}
    data["casts"][key] = {"take": spec["take"], "cols": h["width"], "rows": h["height"],
                          "events": [e for e in ev if e[1] in ("o", "i")], "rowsAt": rows}
    print(key, spec["take"], len(ev), "events; rows", rows)
open(os.path.join(HERE, "film", "data.js"), "w").write("window.FILM_DATA = " + json.dumps(data) + ";\n")
