# Ledger: lane `video`

Branch `lane/video`, started from `b082f4f` (Video frames: the real notch UI for every step of the guide).
Environment: Ubuntu 24.04 cloud VM, node 22.22.0, go 1.24.7, ffmpeg 6.1.1, Claude Code 2.1.296, Chromium headless shell 1194 (pre-installed).

## DONE

1. **Setup** `bash launch/video/setup.sh` → tail `setup: ok`, exit 0. Installed ttyd, asciinema, fonts, VHS (go install), pillow/numpy/pyte, Playwright 1.48.2 + xterm 5.5.0 + fontsource. Playwright 1.48.2's own Chromium is not downloaded; the renderer passes `executablePath` = `/opt/pw-browsers/chromium_headless_shell-1194/...` (the full `chromium` binary refused `--headless=old`: "Old Headless mode has been removed", so the headless shell is used).
2. **Demo world** `bash launch/video/demo/build-world.sh` → `world: ok`, exit 0. `/Users/dev/shop` (11 files, 3 commits; the bug lands in "Set session cookie on sign-in"), `/Users/dev/blog` (8 files, 2 commits, no RSS), `/work/monotask-home` with `agent-context.md` (`cmp` against the fixture: identical) and empty `inbox/`.
   - Red first: on the built shop, `node --test` → `# pass 1 # fail 2` (the redirect test fails as intended; the digest test is the flaky one).
   - Flakiness measured: `for i in $(seq 20); do node --test test/email-digest.test.js || f=$((f+1)); done` → `fails=8/20`.
3. **Recorder** `launch/video/record/rec.py`: real pty, every output byte recorded verbatim to asciicast v2; the script only types keys (55 ms/char) and waits on a pyte screen model. Claude Code's permission prompts are approved by pressing Return after a visible 1.6–2.2 s pause. User `dev`, `HOME=/Users/dev`, prompt `~/shop ❯`, only the API/proxy variables passed through (never printed).
4. **R1 takes** `bash launch/video/record/take.sh r1 r1-takeN` (N = 1, 2, 3) → each `take r1-takeN: exit 0`.
   - take 1 (41 s): scoped one-line fix, tests run, "The "Done when" line (...) isn't met yet, because the fix isn't deployed", "What's left", then offers `monotask add "Fix failing email digest test"`; `yes` → Claude Code permission prompt → approved → "I added "Fix failing email digest test" to your Do Next list." Inbox file written (`20261011T152431Z-4583-f95999a9.txt`). **Chosen.**
   - take 2: Claude ended its first turn asking about a commit; `yes` committed (failed: no git identity) and it then proposed adding an `/auth/google` route. No Do Next offer. Rejected.
   - take 3: same pattern as take 2 (`yes` went to a commit). No Do Next offer. Rejected.
5. **R2 (Codex)**: `env | cut -d= -f1 | grep -i openai` → no output (no `OPENAI_API_KEY`); `which codex` → not found. Skipped per charter; beat 6 is the 4-second card.
6. **Film** `launch/video/work/film/` (index.html + film.js, `window.renderFrame(n)`, closed-form springs), data bundle `python3 work/build-data.py` → `r1 r1-take1 398 events; rows {'finishLine': 6, 'offer': 19}`. Renderer `node work/render.mjs <guide|short> <out.mp4>` pipes PNG frames into ffmpeg (libx264 High, CRF 18, yuv420p, faststart, no audio).
7. **Renders** `node work/render.mjs guide ../out/monotask-guide.mp4` → `done ../out/monotask-guide.mp4`, exit 0 (2120 frames, ~6 min); `node work/render.mjs short ../out/monotask-short.mp4` → `done ../out/monotask-short.mp4`, exit 0 (903 frames). Second render after moving the pointer off the chin text (beats 1, 4) and off the "Done" check (beat 7).
8. **Poster + GIF** `bash work/finish.sh` → `poster at 60.380 s; gif 41.647..49.247`, `readme.gif` 4,295,965 bytes, exit 0.
9. **BEATS.md** written from the rendered timelines (`work/tmp/timeline-*.json`).

## PROOF

1. ffprobe (`ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,profile,width,height,r_frame_rate,pix_fmt,nb_frames -show_entries format=duration,size -of compact <file>`), exit 0:
   ```
   == out/monotask-guide.mp4
   stream|codec_name=h264|profile=High|width=1920|height=1080|pix_fmt=yuv420p|r_frame_rate=30/1|nb_frames=2120
   format|duration=70.666667|size=7710007
   == out/monotask-short.mp4
   stream|codec_name=h264|profile=High|width=1920|height=1080|pix_fmt=yuv420p|r_frame_rate=30/1|nb_frames=903
   format|duration=30.100000|size=5825325
   ```
   Audio streams: none (`ffprobe -show_entries stream=codec_type` → `1 video`). Guide 70.67 s (60–80 ✓), 7.7 MB (<80 ✓). Short 30.10 s (28–35 ✓), 5.8 MB (<40 ✓). `+faststart`, CRF 18 set in `render.mjs`.
   **Verdict: PASS.**
2. Check frames `out/check/guide-beat{1..8}-*.png` (2.0, 7.5, 16.0, 23.5, 37.5, 52.3, 59.0, 67.0 s), extracted from the MP4 with `ffmpeg -ss <t> -frames:v 1`, all looked at. Captions readable, nothing clipped, notch centred horizontally in every frame, terminal text sharp (DOM-rendered, rasterised at final scale).
   One soft spot: in beat 5's push-in (37.5 s) the caption pill sits over the terminal's bottom rows (the "Brewed" line and input box); the finish-line sentence and the offer stay clear.
   **Verdict: PASS (with the note above).**
3. GIF: `ffprobe out/readme.gif` → `width=960|height=540|r_frame_rate=15/1|nb_frames=105`, `duration=7.000000|size=4295965`; PIL `loop=0` (infinite). Frames 0 and 104 compared: the tail cross-fades into the head, no jump. Short cut frame 0 (`out/check/short-frame0.png`) is the v09 chin close-up. **Verdict: PASS.**
4. BEATS.md lists the takes used (r1-take1), why takes 2 and 3 were rejected, that R2 was skipped (no key), and what the used take lacks (item title differs from the v10/v11 frames; Claude Code's own prompt suggestion and an em dash in its permission-prompt tip are on screen). **Verdict: PASS.**
5. `git diff --name-only origin/work/main...HEAD | grep -v '^launch/video/' | wc -l` → `0`. **Verdict: PASS.**

## OPEN

- Item-title mismatch: Claude parked "Fix failing email digest test"; the notch frames v10/v11 (and so the film's Do Next list and the poster) show "Fix flaky auth test". Fix needs a Mac: re-render v10/v11/v12*/v13/v14 with the real title (`Monotask --snapshot <dir> --scenario video`), then `node work/render.mjs` again (no other change needed).
- R2 (Codex) not recorded: no `OPENAI_API_KEY` and no `codex` in this VM. Beat 6 is the card. With a key, add an `r2` entry to `record/takes.py` and `record/chosen.json` and a window in `guideTimeline()`.
- On-screen em dashes in real Claude Code UI (permission-prompt tip line "…prompts for you — choose…", and the "Tip: … artifact — a polished web page" line during the add). Not editable without editing the recording, which the charter forbids. Window title uses "shop – claude" (en dash) to honour "no em dashes anywhere on screen" over the literal "shop — claude" in the charter.
- VHS was installed but not used; recordings are asciicast v2 from `record/rec.py` (own pty recorder, verbatim bytes) played through xterm.js 5.5.0 in the film page.

## CLOSE

| command | verdict | exit |
|---|---|---|
| `bash launch/video/setup.sh` | setup: ok | 0 |
| `bash launch/video/demo/build-world.sh` | world: ok | 0 |
| `bash launch/video/record/take.sh r1 r1-take{1,2,3}` | 3 takes recorded; take 1 shows all R1 behaviours | 0 |
| `node launch/video/work/render.mjs guide …/out/monotask-guide.mp4` | 1920×1080, 30 fps, H.264 High, yuv420p, 70.67 s, 7.7 MB | 0 |
| `node launch/video/work/render.mjs short …/out/monotask-short.mp4` | 1920×1080, 30 fps, H.264 High, yuv420p, 30.10 s, 5.8 MB | 0 |
| `bash launch/video/work/finish.sh` | poster 1920×1080; GIF 960 px, 15 fps, 7.0 s, 4.3 MB, loops | 0 |
| proof 1–5 (above) | PASS (proof 2 with the caption-over-terminal note) | 0 |

Files changed (`git diff --stat origin/work/main...HEAD`):
```
launch/video/.gitignore                            |   7 +
launch/video/demo/blog/README.md                   |   5 +
launch/video/demo/blog/build.js                    |  33 ++
launch/video/demo/blog/package.json                |   7 +
.../demo/blog/posts/2026-08-14-small-tools.md      |   7 +
.../video/demo/blog/posts/2026-09-02-one-thing.md  |   7 +
launch/video/demo/blog/templates/layout.html       |   5 +
launch/video/demo/build-world.sh                   |  36 ++
launch/video/demo/shop/README.md                   |   8 +
launch/video/demo/shop/package.json                |  10 +
launch/video/demo/shop/src/auth/callback.js        |  18 +
launch/video/demo/shop/src/auth/google.js          |  11 +
launch/video/demo/shop/src/auth/session.js         |  13 +
launch/video/demo/shop/src/dashboard.js            |   4 +
launch/video/demo/shop/src/email/digest.js         |  17 +
launch/video/demo/shop/src/server.js               |  15 +
launch/video/demo/shop/test/auth.test.js           |  27 ++
launch/video/demo/shop/test/email-digest.test.js   |  12 +
launch/video/ledger/video.md                       |  18 +
launch/video/out/BEATS.md                          |  44 ++
launch/video/out/check/guide-beat1-2.0s.png        | Bin 0 -> 212566 bytes
launch/video/out/check/guide-beat2-7.5s.png        | Bin 0 -> 181555 bytes
launch/video/out/check/guide-beat3-16.0s.png       | Bin 0 -> 296849 bytes
launch/video/out/check/guide-beat4-23.5s.png       | Bin 0 -> 169423 bytes
launch/video/out/check/guide-beat5-37.5s.png       | Bin 0 -> 605431 bytes
launch/video/out/check/guide-beat6-52.3s.png       | Bin 0 -> 250891 bytes
launch/video/out/check/guide-beat7-59.0s.png       | Bin 0 -> 367451 bytes
launch/video/out/check/guide-beat8-67.0s.png       | Bin 0 -> 293574 bytes
launch/video/out/check/short-frame0.png            | Bin 0 -> 57364 bytes
launch/video/out/monotask-guide.mp4                | Bin 0 -> 7710007 bytes
launch/video/out/monotask-short.mp4                | Bin 0 -> 5825325 bytes
launch/video/out/poster.png                        | Bin 0 -> 205994 bytes
launch/video/out/readme.gif                        | Bin 0 -> 4295965 bytes
launch/video/record/chosen.json                    |   9 +
launch/video/record/env.py                         |  31 ++
launch/video/record/probe.py                       |   9 +
launch/video/record/rec.py                         | 141 ++++++
launch/video/record/take.sh                        |  11 +
launch/video/record/takes.py                       |  39 ++
launch/video/record/takes/r1-take1.cast            | 399 ++++++++++++++++
launch/video/record/takes/r1-take2.cast            | 402 +++++++++++++++++
launch/video/record/takes/r1-take3.cast            | 499 +++++++++++++++++++++
launch/video/setup.sh                              |  33 ++
launch/video/work/analyze.py                       |  34 ++
launch/video/work/build-data.py                    |  30 ++
launch/video/work/castdump.py                      |  16 +
launch/video/work/film/data.js                     |   1 +
launch/video/work/film/film.js                     | 483 ++++++++++++++++++++
launch/video/work/film/index.html                  | 104 +++++
launch/video/work/film/notch.json                  | 367 +++++++++++++++
launch/video/work/finish.sh                        |  28 ++
launch/video/work/package-lock.json                |  80 ++++
launch/video/work/package.json                     |   1 +
launch/video/work/render.mjs                       |  55 +++
54 files changed, 3076 insertions(+)
```
(plus this ledger update in the closing commit)

OPEN: item-title mismatch with v10/v11 (needs Mac re-snapshot); R2 not recorded (no OPENAI_API_KEY, no codex); em dashes inside real Claude Code UI; caption overlaps terminal bottom rows during the beat-5 push-in.

CLOSE: video
