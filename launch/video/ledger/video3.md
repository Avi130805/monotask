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

### 3. Green: framing fix in `work/film/film.js`
- Push-in: frame top 6 px above terminal row 0 (inside the window's top padding); zoom = min(1.38 guide / 1.45 short, captionTop / rowsSpan), giving 1.235× (guide) and 1.275× (short). Every row stays inside the frame and above the caption pill.
- Ease-back: 1.12× / 1.2× kept, with the frame top as low as keeps every row above the caption.
- Caption top is measured from the real caption pill (every caption shown while the terminal is up).
- Terminal entry: an 8 px rise, fading in at the first frame where the camera pull-back keeps all rows inside the frame and above the caption (guide 25.83 s, was 25.0; short 3.33 s, was 3.0). Exit: a fade over 0.3 s with an 8 px drop (was a 220 px slide down through the caption). The cast plays at the same film times as before.
- Menu titles and the clock also fade when the camera's top edge would cut them vertically (the new push-in frames the window below the menu bar).

`node launch/video/work/check-layout.mjs guide 1 25-52` (every frame of beat 5 and into the Codex card) → `layout: PASS` | exit 0
`node launch/video/work/check-layout.mjs short 1 2.5-19` (every frame of the R1 stretch) → `layout: PASS` | exit 0

`node launch/video/work/check-layout.mjs guide 3` (after fix) | exit 0
```
cut=guide frames checked=716 (terminal frames 247)
  caption @0.60s: One task. One finish line. / Your coding agents know both.
  caption @4.50s: ⌥Space from any app. / Type it, press Return. It waits in Do Next.
  caption @11.30s: Write what done means. That's your finish line.
  caption @21.30s: It sits in your notch. / Hover to see the task and its finish line.
  caption @25.40s: Your task and finish line reach / every session. Nothing to paste.
  caption @36.20s: It stops at your finish line and says what's left.
  caption @41.80s: Side work goes to Do Next, only with your yes.
  caption @50.30s: Same plugin, same one task. / Trust its hooks once with /hooks.
  caption @55.60s: Hold to mark it done, once it's done end to end.
layout: PASS
```

`node launch/video/work/check-layout.mjs short 3` (after fix) | exit 0
```
cut=short frames checked=304 (terminal frames 158)
  caption @0.20s: One task. One finish line. / Your coding agents know both.
  caption @3.30s: Claude Code gets your task and finish line.
  caption @11.10s: Side work waits in Do Next. Only with your yes.
  caption @19.50s: Only you mark it done.
layout: PASS
```

### 4. Re-render
`bash work/tmp/run.sh` (render guide, render short, `bash work/finish.sh`) → tail `RUN EXIT 0` | exit 0
```
poster at 60.380 s; gif 41.647..49.247
-rw-r--r-- 1 root root 4063759 Oct 11 16:38 .../out/readme.gif
```

### 5. Proof
1. `ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,profile,width,height,r_frame_rate,pix_fmt -show_entries format=duration,size -of default=nw=1 <mp4>` | exit 0
```
== out/monotask-guide.mp4 (output lines joined with spaces)
codec_name=h264 profile=High width=1920 height=1080 pix_fmt=yuv420p r_frame_rate=30/1 duration=70.666667 size=6837967
== out/monotask-short.mp4
codec_name=h264 profile=High width=1920 height=1080 pix_fmt=yuv420p r_frame_rate=30/1 duration=30.100000 size=4869842
```
2. One frame per beat: `ffmpeg -ss <t> -i out/monotask-guide.mp4 -frames:v 1 out/check/guide-beat<N>-<t>s.png` at 2.0, 7.5, 16.0, 23.5, 37.5, 52.3, 59.0, 67.0 s, plus `out/check/short-frame0.png`, plus extra terminal frames (guide 26.2, 41.0, 44.0, 49.6 s; short 3.5, 9.0, 11.5, 14.0 s). I looked at all of them. Captions are readable, nothing is clipped, the notch is centred, and the terminal text is sharp. In beat 5's push-in (37.5 s) row 0 sits at the top edge, the input row and status line are fully inside the frame, and the caption sits below the window. In the permission prompt (guide 44.0 s, short 14.0 s) the whole window is above the caption.
3. GIF: `ffprobe out/readme.gif` → 960×540, 15 fps, 105 frames (7.0 s), 4,063,759 bytes (≤ 8 MB). The loop uses the same cross-fade as round 2. The short is 30.10 s and opens on the v09 chin (short-frame0.png). The poster is 1920×1080 and byte-identical to round 2 (beat 7 is unchanged).
4. BEATS.md: the take is still r1-take1. It now has a Round 3 note and the new beat-5 numbers (zoom, window fade-in times). R2 is still not recorded (no key).
5. `git diff --stat origin/work/main...HEAD` touches only `launch/video/` (see CLOSE).

## NEXT
- none in this lane.

## OPEN
- R2 (Codex) is still not recorded. No `OPENAI_API_KEY` was checked or used this round: the round 3 brief doesn't ask for it, so the Codex card is kept as merged.
- To keep the caption clear, the beat 5 push-in is gentler than before (1.235× / 1.275× instead of 1.38× / 1.45×). During the push-in and ease-back, the notch is out of frame. It is back in the wide shot before the v10 "Added to Do Next" cut.
- The terminal now appears 0.83 s later in the guide (25.83 s) and 0.33 s later in the short (3.33 s). The session itself starts at the same time as before. This is the only timing change, and it was needed so that no row is cut or covered while the camera pulls back from the notch close-up.
- The check frames for beats 6–8 changed in bytes only. That is from the re-encode; the content is the same, and the poster is byte-identical.
- Carried over: em dashes and the "commit this" suggestion inside Claude Code's real UI. They can't be changed without editing the recording.

## CLOSE

| command | verdict | exit |
|---|---|---|
| `bash launch/video/setup.sh` | setup: ok | 0 |
| `node launch/video/work/check-layout.mjs guide 3` (before fix) | layout: FAIL (123): rows cut by frame edge, caption covers terminal text | 1 |
| `node launch/video/work/check-layout.mjs short 3` (before fix) | layout: FAIL (70) | 1 |
| `node launch/video/work/check-layout.mjs guide 3` / `short 3` (after fix) | layout: PASS / layout: PASS | 0 |
| `node launch/video/work/check-layout.mjs guide 1 25-52` / `short 1 2.5-19` (every terminal frame) | layout: PASS / layout: PASS | 0 |
| `node work/render.mjs guide ../out/monotask-guide.mp4` | 1920×1080, 30 fps, H.264 High, yuv420p, 70.67 s, 6.8 MB | 0 |
| `node work/render.mjs short ../out/monotask-short.mp4` | 1920×1080, 30 fps, H.264 High, yuv420p, 30.10 s, 4.9 MB | 0 |
| `bash work/finish.sh` | poster 1920×1080; GIF 960 px, 15 fps, 7.0 s, 4.1 MB | 0 |
| proof 1–5 | PASS | 0 |

Files changed (`git diff --stat origin/work/main...HEAD`, before this CLOSE block was added):
```
 launch/video/ledger/video3.md                | 117 +++++++++++++++++++++++++++
 launch/video/out/BEATS.md                    |   6 +-
 launch/video/out/check/guide-beat5-37.5s.png | Bin 590912 -> 581012 bytes
 launch/video/out/check/guide-beat6-52.3s.png | Bin 241941 -> 232875 bytes
 launch/video/out/check/guide-beat7-59.0s.png | Bin 367438 -> 363752 bytes
 launch/video/out/check/guide-beat8-67.0s.png | Bin 287377 -> 280953 bytes
 launch/video/out/monotask-guide.mp4          | Bin 7637053 -> 6837967 bytes
 launch/video/out/monotask-short.mp4          | Bin 5773830 -> 4869842 bytes
 launch/video/out/readme.gif                  | Bin 4170501 -> 4063759 bytes
 launch/video/work/check-layout.mjs           |  46 ++++++++++-
 launch/video/work/film/film.js               |  61 +++++++++++---
 11 files changed, 215 insertions(+), 15 deletions(-)
```
Everything is under `launch/video/`.

OPEN: R2 (Codex) still not recorded, so the card is kept. The push-in is gentler (1.235× / 1.275×) and the notch is out of frame during it. The terminal fades in 0.83 s later (guide) and 0.33 s later (short), while the session timing is unchanged. The em dashes and prompt suggestion inside the real Claude Code UI carry over.

CLOSE: video3
