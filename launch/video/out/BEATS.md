# Monotask launch video: beats

Rendered from `launch/video/work/film/` (`window.renderFrame(n)`, 30 fps) by `node launch/video/work/render.mjs`.
Times are film seconds. Notch frames are `launch/video/assets/notch/*.png`, composited as-is.

## Takes used

| Recording | Take | Why |
|---|---|---|
| R1, Claude Code in `shop/` | `record/takes/r1-take1.cast` (41 s real time) | The only take of three that shows every behaviour: a one-line scoped fix, a plain finish-line status ("The "Done when" line (Google sign-in lands on the dashboard, in production) isn't met yet, because the fix isn't deployed."), a "What's left" list, and an offer to park the failing digest test in Do Next; on `yes`, `monotask add "Fix failing email digest test"` raises Claude Code's own permission prompt, which is approved on camera, and the item is added. |
| R1 | `r1-take2`, `r1-take3` (not used) | In both, Claude ended its first turn asking whether to commit, so `yes` meant "commit" (which failed: no git identity in the VM). Neither offered Do Next. |
| R2, Codex in `blog/` | none | No `OPENAI_API_KEY` in the VM in round 1 or round 2 (and no `codex` binary). Beat 6 is the 4-second card with the two Codex install commands, as the charter specifies. |

What the R1 take does not show exactly as storyboarded:
- Claude called the digest test "failing" rather than flaky, and titled the item "Fix failing email digest test". Round 2: the notch frames v11–v14 were re-rendered on a Mac with that title, so the film's Do Next list and the poster now match the take.
- Claude Code's own UI shows a dim prompt suggestion ("commit this", then "commit it") in the input box after each reply, and its permission prompt has a tip line containing an em dash. Both are real UI and were left untouched.

Round 2 (lane `video2`): re-rendered from the same take and timeline (all times below unchanged). New notch frames v11–v14 carry Claude's real side-task title; every two-line caption wraps balanced (`text-wrap: balance`) or at an explicit break, with no single-word line; in close-ups the menu titles and the clock fade out before the frame edge would cut them and return in the wide shots. Checked by `node launch/video/work/check-layout.mjs <guide|short>`.

Round 3 (lane `video3`): same take, frames, captions and timeline; only the terminal-beat framing changed. In beat 5 (and the short cut's R1 stretch) no frame edge ever cuts a terminal row, and the caption pill never covers terminal text: the push-in puts the frame top in the window's top padding (just above row 0) and zooms only as far as keeps the last row above the caption (guide 1.235×, short 1.275×, was 1.38× / 1.45×); the ease-back keeps 1.12× / 1.2× with the frame top as low as keeps every row above the caption. The terminal now fades in with an 8 px rise (was 260 px from below) once the camera has pulled back far enough (guide 25.83 s, was 25.0 s; short 3.33 s, was 3.0 s; the recording itself starts at the same film time as before), and leaves with a fade and an 8 px drop. Checked by `node launch/video/work/check-layout.mjs <guide|short>` (checks 4 and 5).

Speed-ups (shown with an amber "6×"/"4×"/"2×" badge in the window title bar) only cover stretches where Claude is working and only the spinner and tool lines change; every reply plays at 1×.

## Guide (`monotask-guide.mp4`, 70.67 s)

| # | Start | End | What | Caption(s) | Sources |
|---|---|---|---|---|---|
| 1 | 0.00 | 4.00 | Cold open, pointer resting on the notch: chin with task and finish line, close-up (1.0× frame scale), slow pull back | One task. One finish line. / Your coding agents know both. (explicit break) | v09 |
| 2 | 4.00 | 11.00 | Chin retracts; ⌥Space keycaps; capture bar; typing; Return; "Added to Do Next"; back to idle | 1 · CAPTURE: ⌥Space from any app. / Type it, press Return. It waits in Do Next. | v09→v01, v02, v03a, v03b, v03, v04, v01 |
| 3 | 11.00 | 21.00 | Click the notch: panel; hover the row; click start; finish line typed; Return; Do Now card | 2 · START ONE TASK: Write what done means. That's your finish line. | v05, v05b, v06a, v06b, v06, v07 |
| 4 | 21.00 | 25.00 | Panel closes to dot and timer; hover shows the chin | 2 · START ONE TASK: It sits in your notch. / Hover to see the task and its finish line. | v08, v09 |
| 5 | 25.00 | 49.98 | Camera pulls back; terminal fades in (25.83 s); real Claude Code session (R1 take 1). Push in (1.235×, whole terminal above the caption) on the finish-line sentence at 36.7 s, ease back to show the offer; `yes`; permission prompt approved (Return keycap) at 46.5 s; notch shows "Added to Do Next" at 47.25 s | 3 · CLAUDE CODE KNOWS IT: Your task and finish line reach every session. Nothing to paste. / It stops at your finish line and says what's left. (36.2 s) / Side work goes to Do Next, only with your yes. (41.8 s) | r1-take1 cast 1.1–36.9 s; v08, v10, v08 |
| 6 | 50.08 | 54.48 | No-key card slides in: "Codex: same plugin, same one task." + `codex plugin marketplace add Avi130805/monotask`, `codex plugin add monotask@monotask` | 4 · CODEX TOO: Same plugin, same one task. Trust its hooks once with /hooks. | card (no recording) |
| 7 | 55.00 | 63.08 | Click the notch (Do Next now has the side task); push in on the hold button; press at 58.28 s; capsule fill grows linearly for 1.1 s; 3-frame pause; spring to green Done (59.48 s); "1 done this week" (61.18 s) | 5 · ONLY YOU FINISH IT: Hold to mark it done, once it's done end to end. | v11, v12a, v12b (masked), v13, v14 |
| 8 | 63.08 | 70.67 | Notch closes to idle, camera pulls back, end card: Monotask / Free and open source · MIT / three install lines | none | v01, end card |

Poster (`poster.png`): frame at 60.38 s (beat 7, green "Done").
GIF (`readme.gif`): guide 41.65–49.25 s (beat 5: `yes`, the permission prompt, the add, the notch's "Added to Do Next"), 960 px, 15 fps, last 0.6 s cross-faded into the first so the loop has no jump.

## Short cut (`monotask-short.mp4`, 30.10 s)

| Start | End | What | Caption |
|---|---|---|---|
| 0.00 | 3.00 | v09 chin close-up (payoff frame is frame 0) | One task. One finish line. / Your coding agents know both. (explicit break) |
| 3.00 | 18.80 | R1 take 1 condensed (cast 6.0–36.6 s; working stretches at 8×/3×; window fades in at 3.33 s), push in (1.275×) on the finish-line sentence, `yes`, permission prompt, v10 at 16.97 s | Claude Code gets your task and finish line. (3.2 s) / Side work waits in Do Next. Only with your yes. (11.1 s) |
| n/a | n/a | R2 skipped (no key) | n/a |
| 19.20 | 25.50 | Click, v11, hold: v12a, linear fill, v13 Done, v14 | Only you mark it done. |
| 25.50 | 30.10 | Notch closes, end card | none |
