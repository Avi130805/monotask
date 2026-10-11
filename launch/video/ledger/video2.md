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
