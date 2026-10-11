# Ledger: lane `video2` (Round 2 re-render)

Branch `lane/video2`, started from `cb544a6` (Video round 2: frames match Claude's real side-task title; brief for the re-render).
Scope: CHARTER.md "Round 2". R1 not re-recorded; take `r1-take1` kept verbatim.

## DONE

1. **Setup** `bash launch/video/setup.sh` → tail `setup: ok`, `EXIT 0`.
2. **New frames measured** `python3 launch/video/work/analyze.py` → exit 0, e.g. `v13-done 360 0 1000 769 r=59`, `hold {'x': 416, 'y': 285, 'w': 702, 'h': 68}`. `diff` of `film/notch.json` old vs new: empty (bodies and the hold rect are unchanged; only the content inside v02/v03*/v11–v14 changed). v10 is unchanged in the brief commit and shows no item title (looked at it).
   `python3 launch/video/work/build-data.py` → `r1 r1-take1 398 events; rows {'finishLine': 6, 'offer': 19}`, exit 0.
3. **Red test** `node launch/video/work/check-layout.mjs guide 3` (new: every 3rd frame plus each caption midpoint; caption ≤ 2 lines, no single-word line, opening caption breaks after "One finish line.", menu titles and clock never partly outside the frame while visible) → `layout: FAIL (3030)`, exit 1, e.g.
   ```
   caption @0.60s: One task. One finish line. Your coding agents know / both.
   FAIL 0.00s menu "Terminal" clipped (-559..-465) at opacity 1.00
   ```
   `node … short 3` → `layout: FAIL (1326)`, exit 1 (same orphan "both.", same menu clipping).
4. **Fix** `work/film/index.html`: caption line `white-space: pre-line; text-wrap: balance`. `work/film/film.js`: opening caption with an explicit break in both cuts ("One task. One finish line." / "Your coding agents know both."), sentence breaks for the beat 2 and beat 4 captions; menu titles and clock each fade with `smooth((margin - 4) / 36)` where margin is the group's screen distance to the nearer frame edge, measured after fonts load.
5. **Green** `node work/check-layout.mjs guide 3` → `layout: PASS`, exit 0; `… short 3` → `layout: PASS`, exit 0. Captions as wrapped:
   ```
   One task. One finish line. / Your coding agents know both.
   ⌥Space from any app. / Type it, press Return. It waits in Do Next.
   Write what done means. That's your finish line.
   It sits in your notch. / Hover to see the task and its finish line.
   Your task and finish line reach / every session. Nothing to paste.
   It stops at your finish line and says what's left.
   Side work goes to Do Next, only with your yes.
   Same plugin, same one task. / Trust its hooks once with /hooks.
   Hold to mark it done, once it's done end to end.
   (short) Claude Code gets your task and finish line. / Side work waits in Do Next. Only with your yes. / Only you mark it done.
   ```
   Commit `d551a17`, pushed.
6. **Codex** `env | cut -d= -f1 | grep -c '^OPENAI_API_KEY$'` → `0`; `which codex` → exit 1. No key: R2 not recorded, the Codex card stays in the guide (the short cut skips R2, as in round 1).
7. **Renders** `cd launch/video/work && node render.mjs guide ../out/monotask-guide.mp4 && node render.mjs short ../out/monotask-short.mp4 && bash finish.sh` → tail:
   ```
   frame 900/902 171s
   done ../out/monotask-short.mp4
   poster at 60.380 s; gif 41.647..49.247
   -rw-r--r-- 1 root root 4170501 Oct 11 16:10 …/out/readme.gif
   EXIT 0
   ```
   Timeline is identical to round 1 (guide 2120 frames, short 903), so BEATS.md times stand; BEATS.md updated for the frames, caption breaks, menu-bar fade and the no-key Codex card.

## PROOF

1. ffprobe (`ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,profile,width,height,r_frame_rate,pix_fmt,nb_frames -show_entries format=duration,size -of compact <file>`), exit 0:
   ```
   == out/monotask-guide.mp4
   stream|codec_name=h264|profile=High|width=1920|height=1080|pix_fmt=yuv420p|r_frame_rate=30/1|nb_frames=2120
   format|duration=70.666667|size=7637053
   == out/monotask-short.mp4
   stream|codec_name=h264|profile=High|width=1920|height=1080|pix_fmt=yuv420p|r_frame_rate=30/1|nb_frames=903
   format|duration=30.100000|size=5773830
   ```
   Streams: `1 video`, no audio. Guide 70.67 s (60–80), 7.6 MB (< 80). Short 30.10 s (28–35), 5.8 MB (< 40). Poster `PNG 1920x1080`. **Verdict: PASS.**
2. One frame per beat, `ffmpeg -ss <t> -i out/monotask-guide.mp4 -frames:v 1 out/check/guide-beat<N>-<t>s.png` at 2.0, 7.5, 16.0, 23.5, 37.5, 52.3, 59.0, 67.0 s, plus `out/check/short-frame0.png` and extra close-ups at 0.3, 12.5, 58.8 s; all looked at.
   - beat 1: opening caption on two lines, "One task. One finish line." / "Your coding agents know both."; menu titles and clock faded (the bar's empty translucent strip stays); notch centred.
   - beats 2, 3, 4, 7: close-ups, no menu text at the frame edges; captions balanced (beat 2 and 4 break at the sentence).
   - beat 6 and 8 (wide): menu titles and clock back, uncut.
   - beat 7 and poster: Do Next lists "3 Fix failing email digest test", which matches what Claude parked in r1-take1. Poster shows the green "Done".
   - beat 5 (push-in on the finish-line sentence): terminal text sharp. Two things carry over from round 1: the caption pill still sits over the "Brewed for 14s · done" row, and the input row ("❯ commit this") is cut through by the bottom edge of the frame. The finish-line sentence and the offer are clear. See OPEN.
   - `node work/check-layout.mjs guide 3` / `short 3` → `layout: PASS` both, exit 0 (716 / 304 frames).
   **Verdict: PASS for round 2's items; beat 5's bottom-edge crop is noted under OPEN.**
3. GIF `ffprobe out/readme.gif` → `width=960|height=540|r_frame_rate=15/1|nb_frames=105`, `duration=7.000000|size=4170501` (4.2 MB ≤ 8 MB); PIL `loop 0`. Seam check: last→first mean pixel diff 3.31, while the largest in-loop steps are 12.8 / 10.8 / 10.4 (terminal scrolling), so no jump stands out. Short cut 30.10 s, and frame 0 is the v09 chin close-up. **Verdict: PASS.**
4. BEATS.md: take r1-take1 (unchanged), takes 2 and 3 rejected, R2 not recorded (no key in round 1 or round 2), and what the take lacks. **Verdict: PASS.**
5. `git diff --name-only origin/work/main...HEAD | grep -v '^launch/video/' | wc -l` → `0`. **Verdict: PASS.**

## OPEN

- R2 (Codex) still not recorded: `OPENAI_API_KEY` is absent (count 0) and there is no `codex` binary. This is a cloud-environment gap, not a failure. The guide keeps the Codex card, and the short cut skips R2.
- Beat 5 push-in: at zoom 1.38 the terminal's input row is cut by the bottom edge of the frame, and the caption covers the "Brewed … done" row. This was present in round 1 too, and it is not the menu-bar case that Round 2 item 3 names. I left it alone because "change nothing else". A fix would key the push-in camera so the frame edge falls between rows, or make it zoom less.
- These carry over from round 1 and can't change without editing the recording, which is forbidden: em dashes inside Claude Code's own UI, and its dim prompt suggestion ("commit this").
- v10 is unchanged in `cb544a6`. It shows only "Added to Do Next", so it carries no title and doesn't need updating.

## CLOSE

| command | verdict | exit |
|---|---|---|
| `bash launch/video/setup.sh` | setup: ok | 0 |
| `python3 launch/video/work/analyze.py` + `build-data.py` | notch.json unchanged; r1-take1 rows {finishLine: 6, offer: 19} | 0 |
| `node launch/video/work/check-layout.mjs guide 3` (before fix) | layout: FAIL (3030), orphan "both.", menu clipped | 1 |
| `node launch/video/work/check-layout.mjs short 3` (before fix) | layout: FAIL (1326) | 1 |
| `node launch/video/work/check-layout.mjs guide 3` / `short 3` (after fix) | layout: PASS / layout: PASS | 0 |
| `node work/render.mjs guide …` | 1920×1080, 30 fps, H.264 High, yuv420p, 70.67 s, 7.6 MB | 0 |
| `node work/render.mjs short …` | 1920×1080, 30 fps, H.264 High, yuv420p, 30.10 s, 5.8 MB | 0 |
| `bash work/finish.sh` | poster 1920×1080; GIF 960 px, 15 fps, 7.0 s, 4.2 MB, loop 0 | 0 |
| proof 1–5 | PASS (proof 2: beat 5 bottom-edge crop noted in OPEN) | 0 |
| `env \| cut -d= -f1 \| grep -c '^OPENAI_API_KEY$'` | 0: no key, Codex card kept (environment gap) | 1 |

Files changed (`git diff --stat origin/work/main...HEAD`):
```
 launch/video/ledger/video2.md                |  32 ++++++++++
 launch/video/out/BEATS.md                    |  14 +++--
 launch/video/out/check/guide-beat{1..8}-*.png, short-frame0.png | Bin (re-extracted)
 launch/video/out/monotask-guide.mp4          | Bin 7710007 -> 7637053 bytes
 launch/video/out/monotask-short.mp4          | Bin 5825325 -> 5773830 bytes
 launch/video/out/poster.png                  | Bin 205994 -> 207618 bytes
 launch/video/out/readme.gif                  | Bin 4295965 -> 4170501 bytes
 launch/video/work/check-layout.mjs           |  86 +++++++++++++++++++++++++++
 launch/video/work/film/film.js               |  21 +++++--
 launch/video/work/film/index.html            |   2 +-
 18 files changed, 144 insertions(+), 11 deletions(-)
```
(plus this CLOSE block in the closing commit). Everything is under `launch/video/`.

OPEN: R2 (Codex) not recorded, because there is no OPENAI_API_KEY and no codex (environment gap). The beat 5 push-in crops the terminal's input row at the bottom edge, and the caption covers the "Brewed" row (carried over from round 1; not changed under "change nothing else"). Em dashes and the prompt suggestion inside the real Claude Code UI (can't change without editing the recording).

CLOSE: video2
