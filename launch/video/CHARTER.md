# Charter: the Monotask launch video (cloud lane `video`)

## WHY

Monotask launches on Reddit and X with one video. It has to be a **usage guide**, not a hype reel: in about 70 seconds a developer should see exactly how to use it, and see the real Claude Code and Codex interfaces working with the real Monotask notch. Most viewers watch muted on autoplay, so every step is captioned.

Monotask in one breath: a MacBook-notch app that holds exactly one task (the **Do Now**) with a **finish line** (what done means). Everything else waits in **Do Next**. Only the user marks a task done, by holding a button. Its plugin gives Claude Code and Codex the Do Now and finish line automatically, so the agent stays on that one thing, says plainly whether the finish line is met, and parks side work in Do Next only after the user says yes. Information flows one way: from Monotask into the agent. Nothing from the agent appears in the notch except the usual "Added to Do Next" flash.

## MISSION

Render, from real material only:

| Output | Spec |
|---|---|
| `launch/video/out/monotask-guide.mp4` | 1920×1080, 30 fps, H.264 High, yuv420p, `-movflags +faststart`, CRF ≈ 18, silent, 60–80 s, under 80 MB |
| `launch/video/out/poster.png` | 1920×1080 still from beat 7 (the Done moment) |
| `launch/video/out/readme.gif` | ≤ 8 MB, 960 px wide, 6–9 s loop of beat 5 (Claude Code + notch), 15 fps, good palette |
| `launch/video/out/BEATS.md` | the final timing table (beat, start, end, captions, sources), plus which recording take was used and why |

## FENCE

Write only inside `launch/video/` (and temp folders outside the repo). Never edit the app (`Sources/`), the plugin (`plugins/`), the README or anything else. Push only your lane branch.

## INPUTS (in the repo)

1. **Notch frames:** `launch/video/assets/notch/*.png`, the real app UI rendered by the app itself (`Monotask --snapshot <dir> --scenario video` on a Mac).
   - Every frame is a 1720×1200 px canvas (860×600 pt at 2×), transparent outside the black notch body.
   - The canvas top edge is the screen's top edge, and the notch is centred horizontally. Composite the frames as-is: never repaint, retype or recolour app UI.
   - At native size the closed notch body is about 370 px wide. On a 1920-wide desktop, a real 14″ MacBook notch is about 12 % of the width, so the closed state should sit around 0.6–0.65× scale in wide shots. Go up to 1.0× (never above) for close-ups, since the frames are 2× sources.

   | Frame | Shows |
   |---|---|
   | v01-closed-idle | the notch at rest, no task |
   | v02-capture-empty / v03a / v03b / v03-capture-typed | ⌥Space capture bar: empty, "Fix log", "Fix login red", "Fix login redirect" |
   | v04-flash-added | closed notch with the green "Added to Do Next" chin |
   | v05-open-list / v05b-open-row-hover | open panel, Do Now empty; then the "Fix login redirect" row hovered (start control visible) |
   | v06a / v06b / v06-start-form | start form, finish line typed: "Google sign-in lands", "…on the dashboard", "…, in production" |
   | v07-open-now | the Do Now card: task, finish line, "Hold to mark done" |
   | v08-closed-wings | closed: amber live dot and timer either side of the camera |
   | v09-peek-chin | hover: the chin with the task and finish line |
   | v10-flash-added-side | closed with wings and the "Added to Do Next" chin (after the agent parks the side task) |
   | v11-open-side-task | open: Do Now card, Do Next now includes "Fix flaky auth test" |
   | v12a-holding-start / v12-holding / v12b-holding-full | the hold button pressed at 0 %, 60 % and 100 % (label "Keep holding…", finish line highlighted) |
   | v13-done | the button turns green: "Done" |
   | v14-open-finished | Do Now empty, header "1 done this week" |

   **Animating between frames.** Open/close and size changes are one black shape morphing. Animate a black rounded shape between the two frames' notch-body bounding boxes with a spring (see Motion), and cross-fade the content in the last 60 % of the morph. Get each body's bounds from the alpha channel.
   - **The hold fill:** v12a and v12b differ only inside the button. Find that rectangle by diffing them, then reveal v12b over v12a through a capsule-shaped mask that grows left to right, linearly, over exactly 1.1 s (the app's real hold duration and timing). Then spring to v13.
   - The timer reads "<1m" in every frame. That's true to the story's timescale; don't fake other times.

2. **Agent context fixture:** `launch/video/fixtures/agent-context.md`, byte-identical to what the app writes for the demo Do Now ("Fix login redirect"; done when "Google sign-in lands on the dashboard, in production").
3. **The plugin:** `plugins/monotask/`, the real one users install, documented in `plugins/monotask/README.md`. Use it for real in the recordings, with `MONOTASK_HOME` pointing at a demo folder that holds the fixture. There's no Mac app in the VM, so the inbox isn't imported there. The film shows the matching real notch frame (v10) at the moment the add command succeeds.

## DEMO WORLD (build it in the VM; keep the sources in `launch/video/demo/` so takes are reproducible)

- `shop/` is a tiny Node web app with no dependencies, using `node:test`.
  - `src/auth/callback.js` has a real bug: after Google sign-in it redirects to `/` instead of `/dashboard`.
  - `test/auth.test.js` covers it.
  - `test/email-digest.test.js` holds one genuinely flaky, unrelated test (timing-dependent, fails about half the time).
  - Keep it small and believable: 6–10 files, a README, `git init` with two or three commits.
- `blog/` is a tiny static blog generator (markdown posts to HTML) with no RSS.
- Demo home is `export MONOTASK_HOME=/work/monotask-home`, containing `agent-context.md` copied from the fixture and an empty `inbox/`.
- Prompt and window chrome: user `dev`, short prompt `~/shop ❯`, no noisy shell plugins. Hide anything from the VM that a Mac user wouldn't see: root, `/home/user`, proxy env and similar.

## RECORDINGS: real sessions, never edited text

- Record the real terminal UIs (TUIs) with **VHS** (`go install github.com/charmbracelet/vhs@latest`, plus `apt-get install -y ttyd`; point it at Playwright's Chromium if its own browser download is blocked) or with **asciinema** rendered through xterm.js in Playwright. Pick whichever you can make reliable.
  - Font: JetBrains Mono (apt `fonts-jetbrains-mono` or the npm `@fontsource` package), about 20–22 px.
  - Theme: dark, close to macOS Terminal's default dark profile.
  - Size: about 110×30.
  - Type at human speed, about 55 ms a character.
- **R1, Claude Code in `shop/`:** `claude --plugin-dir <repo>/plugins/monotask`, then the user types `fix the login redirect`, then waits.
  - What we hope to see: Claude keeps the fix scoped, says plainly whether the finish line is met (it can't be met without a production deploy), and offers to put the flaky test in Do Next.
  - The user types `yes`, Claude runs `monotask add "…"`, and Claude Code's own permission prompt appears. Approve it on camera: that prompt is the user's yes.
  - Record up to **3 takes**. Pick the one that shows these behaviours most clearly. If none does, use the best take and report exactly what was missing. **Never** type, edit or overlay words into Claude's replies.
- **R2, Codex in `blog/`:** only if a variable named `OPENAI_API_KEY` exists (check the name, never print it). Install the plugin into the VM's Codex the documented way (`codex plugin marketplace add <repo path>`, then `codex plugin add monotask@monotask`). Trust its hooks in a hidden pre-roll (`/hooks`), which a real user does once. Then record: the user types `add an RSS feed`, and we hope Codex gives a one-line heads-up that this isn't the Do Now ("Fix login redirect") before helping.
  - **If there's no key:** skip R2. Beat 6 becomes a 4-second card: "Codex: same plugin, same one task." plus the two Codex install commands. Say so in your report.
- Long waits: speed up only the stretches where nothing changes on screen, by 2–8×, and show a small "8×"-style badge while sped up. Never speed up the moment text appears.

## FILM

- Build an HTML/CSS/JS film page in `launch/video/work/film/`, where everything on screen is a pure function of the frame number (`window.renderFrame(n)`).
- Render it with Playwright at 1920×1080 by stepping frames and screenshotting, or with Remotion if you prefer and it works offline. Encode with ffmpeg.
- **Desktop:**
  - Wallpaper: a soft vertical gradient from #6B85AD (top) to #DBC2A8 (bottom), the same backdrop the app uses for its own screenshots.
  - Menu bar: a translucent 24 px bar (white at 22 % over the wallpaper). Menu titles in the left third: "Terminal  Shell  Edit  View  Window  Help". A clock on the right reading "Sun 10:41". No Apple logo, no other trademarks.
  - The notch frames sit on top at the centre, over the menu bar.
- **Terminal windows:** macOS-style chrome with grey traffic lights, title "shop — claude" (or "blog — codex"), corner radius 10, and a soft shadow. The recording plays inside.
- **Cursor:** a standard macOS-style arrow drawn in SVG. It moves on critically damped springs, and a click dips it to 0.92 scale for 120 ms.
- **Keys:** when ⌥Space or Return is pressed, show small rounded keycaps bottom-centre for 0.7 s.
- **Captions:** one at a time, bottom-centre, on a dark glass pill (rgba(10,10,12,0.62) with a 20 px backdrop blur, radius 18).
  - A small step label in amber (#FFA33D), uppercase, letter-spaced, for example "1 · CAPTURE".
  - Below it, one line in white, Inter SemiBold about 34 px, wrapping to 2 lines at most.
  - Fade in plus an 8 px rise over 250 ms. Hold each caption at least 2.2 s.

### Motion (Apple-like, calm)

- Notch morphs use a spring with response 0.45 s and damping 0.84, a whisper of overshoot.
- Camera moves are critically damped (damping 1.0, response 0.6 s).
- Cross-fades take 200–300 ms.
- No whip-pans, shakes, glitches, zoom-punches or particle effects.
- The camera moves only when something changes: push in when the notch is the subject, pull back when the terminal and notch must be seen together, and push gently onto the line where the agent states the finish-line status.

## STORYBOARD (target 72 s, ±8 s)

| # | Time | What we see | Caption |
|---|---|---|---|
| 1 | 0–4 s | Desktop, idle notch (v01). A slow push toward the notch. The wordmark "Monotask" with "One task at a time. Your coding agents know it too." fades in at centre, then out as the push lands. | none |
| 2 | 4–11 s | ⌥Space keycaps; the notch morphs into the capture bar (v02); typing v03a → v03b → v03; Return keycap; it collapses to v04 (green "Added to Do Next"). | **1 · CAPTURE**: ⌥Space from any app. Type it, press Return. It waits in Do Next. |
| 3 | 11–21 s | The cursor clicks the notch, giving the open panel (v05). It hovers the row (v05b) and clicks start, giving the start form (v06a → v06b → v06). Return, then v07. | **2 · START ONE TASK**: Write what done means. That's your finish line. |
| 4 | 21–25 s | The panel closes to v08 (dot and timer). The cursor rests on the notch, giving v09 (chin). | It sits in your notch. Hover to see the task and its finish line. |
| 5 | 25–45 s | The terminal window (R1) rises into the lower part of the desktop, with the notch (v08) still visible above. The real Claude Code session plays. When the finish-line sentence appears, a gentle push-in onto it. On "yes", the permission prompt is approved; when the add command completes, the notch cuts to v10. | **3 · CLAUDE CODE KNOWS IT**: Your task and finish line reach every session. Nothing to paste. Then: It stops at your finish line and says what's left. Then: Side work goes to Do Next, only with your yes. |
| 6 | 45–55 s | The second terminal (R2, Codex in `blog/`) slides in from the right. The real session plays. (Or the no-key card.) | **4 · CODEX TOO**: Same task in every project. Wander off and it tells you once, then helps. |
| 7 | 55–64 s | The terminals glide away. The cursor clicks the notch (v11) and presses the hold button. The camera pushes in on the button: v12a, then the capsule fill grows linearly over 1.1 s to v12b. A 3-frame pause, then the spring to v13 (green "Done"), then v14 ("1 done this week"). | **5 · ONLY YOU FINISH IT**: Hold to mark it done, once it's done end to end. |
| 8 | 64–72 s | The notch closes to v01 and the camera pulls back. The end card fades in over the desktop: "Monotask", "Free and open source · MIT", then three lines in monospace: `github.com/Avi130805/monotask`, `/plugin marketplace add Avi130805/monotask`, `codex plugin marketplace add Avi130805/monotask`. Final image: the quiet notch and the card. | none |

Rhythm: beats 2–4 are brisk (2–3 s per step). Beat 5 breathes (the reply is the point). Beat 7 holds its pause before the Done; the pause matters more than speed. Every shot does a job: it shows a step, a consequence, or the agent behaving.

## SETUP

Write `launch/video/setup.sh` (idempotent; it runs as root on Ubuntu 24.04 with node 22, go 1.24, python 3.11 and ffmpeg 6 present). Install Playwright 1.48.2 with Chromium (verified working there), ttyd, VHS, asciinema and the fonts. Measured on this environment: npm, PyPI, the Go proxy and apt are reachable, and GitHub release downloads are not.

## PROOF

1. `ffprobe` on the MP4 reports 1920×1080, 30 fps, H.264, the duration and the size. Paste it into the ledger.
2. Extract one frame from the middle of every beat into `launch/video/out/check/` and **look at each one**. Check that captions are readable, nothing is clipped, the notch is centred, and the terminal text is sharp.
3. The GIF is ≤ 8 MB and loops cleanly.
4. `BEATS.md` lists the takes used. If any take misses a behaviour from R1 or R2, say exactly what is missing.
5. `git diff --stat origin/work/main...HEAD` touches only `launch/video/`.

## FINISH LINE

The MP4, poster, GIF and BEATS.md are committed and pushed on your lane branch, and every proof step has been recorded in the ledger. Large binaries are fine (each under 90 MB). Don't commit `node_modules` or Chromium: add a `.gitignore` inside `launch/video/`.
