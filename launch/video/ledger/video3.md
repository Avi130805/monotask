# Ledger: video3 (Round 3, framing in the terminal beats)

## DONE

### 1. Setup
`bash launch/video/setup.sh` → tail: `setup: ok` | exit 0 (VHS installed via go toolchain switch; optional)

### 2. Red: extended layout check on the current (round 2) render
`work/check-layout.mjs` now also fails on (4) any terminal row partially inside the frame and (5) any caption/terminal-text overlap, at every sampled frame where a terminal window is visible.

`node launch/video/work/check-layout.mjs guide 3` (before fix) | exit 1
```
cut=guide frames checked=716 (terminal frames 256)
  caption @0.60s: One task. One finish line. / Your coding agents know both.
  caption @4.50s: ⌥Space from any app. / Type it, press Return. It waits in Do Next.
  caption @11.30s: Write what done means. That's your finish line.
  caption @21.30s: It sits in your notch. / Hover to see the task and its finish line.
  caption @25.40s: Your task and finish line reach / every session. Nothing to paste.
  caption @36.20s: It stops at your finish line and says what's left.
  caption @41.80s: Side work goes to Do Next, only with your yes.
  caption @50.30s: Same plugin, same one task. / Trust its hooks once with /hooks.
  caption @55.60s: Hold to mark it done, once it's done end to end.
... 83 more
layout: FAIL (123)
FAIL 25.10s terminal "shop – claude" row 16 cut by frame edge (y 1070.8..1105.3)
FAIL 25.20s terminal "shop – claude" row 24 cut by frame edge (y 1071.5..1102.0)
FAIL 36.90s caption (y 918..1034) covers terminal "shop – claude6×" row 28 text "──────────────────────────────────────────────────────────────────────────────────────────────────────────────"
FAIL 37.00s caption (y 918..1034) covers terminal "shop – claude6×" row 26 text "──────────────────────────────────────────────────────────────────────────────────────────────────────────────"
FAIL 37.10s terminal "shop – claude6×" row 29 cut by frame edge (y 1056.9..1086.7)
FAIL 37.10s caption (y 918..1034) covers terminal "shop – claude6×" row 24 text "3:24"
FAIL 37.20s terminal "shop – claude6×" row 28 cut by frame edge (y 1059.2..1089.8)
FAIL 37.20s caption (y 918..1034) covers terminal "shop – claude6×" row 24 text "3:24"
```

`node launch/video/work/check-layout.mjs short 3` (before fix) | exit 1
```
cut=short frames checked=304 (terminal frames 163)
  caption @0.20s: One task. One finish line. / Your coding agents know both.
  caption @3.30s: Claude Code gets your task and finish line.
  caption @11.10s: Side work waits in Do Next. Only with your yes.
  caption @19.50s: Only you mark it done.
... 30 more
layout: FAIL (70)
FAIL 3.10s terminal "shop – claude" row 20 cut by frame edge (y 1063.2..1093.4)
FAIL 3.30s caption (y 948..1036) covers terminal "shop – claude" row 28 text "──────────────────────────────────────────────────────────────────────────────────────────────────────────────"
FAIL 8.70s terminal "shop – claude8×" row 28 cut by frame edge (y 1056.9..1087.6)
FAIL 8.80s terminal "shop – claude8×" row 27 cut by frame edge (y 1067.2..1099.0)
FAIL 8.90s terminal "shop – claude8×" row 26 cut by frame edge (y 1060.7..1093.1)
FAIL 9.00s terminal "shop – claude8×" row 26 cut by frame edge (y 1076.0..1108.8)
FAIL 9.10s terminal "shop – claude8×" row 25 cut by frame edge (y 1051.8..1084.9)
FAIL 9.20s terminal "shop – claude8×" row 25 cut by frame edge (y 1056.7..1089.9)
```
