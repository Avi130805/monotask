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
