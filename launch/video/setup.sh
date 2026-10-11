#!/usr/bin/env bash
# Idempotent toolchain for the launch-video lane (Ubuntu 24.04, run as root).
# node 22, go 1.24, python 3.11 and ffmpeg 6 are expected to be present already.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

export DEBIAN_FRONTEND=noninteractive
need_apt=()
command -v ttyd >/dev/null || need_apt+=(ttyd)
command -v asciinema >/dev/null || need_apt+=(asciinema)
fc-list | grep -qi "JetBrains Mono" || need_apt+=(fonts-jetbrains-mono)
fc-list | grep -qi "Inter" || need_apt+=(fonts-inter)
if [ ${#need_apt[@]} -gt 0 ]; then
  apt-get update -qq || true
  apt-get install -y -qq "${need_apt[@]}"
fi

# VHS (optional; the film uses the asciicast recorder below, VHS is kept for ad-hoc takes)
if ! command -v vhs >/dev/null && [ ! -x "$HOME/go/bin/vhs" ]; then
  GOFLAGS=-mod=mod go install github.com/charmbracelet/vhs@latest || echo "vhs: install failed (optional)"
fi

# Python: notch-frame analysis (pillow, numpy) and the recorder's screen model (pyte)
python3 -c "import PIL, numpy, pyte" 2>/dev/null || python3 -m pip install -q pillow numpy pyte

# Playwright 1.48.2 + xterm.js for the film page. Chromium is pre-installed at /opt/pw-browsers;
# the film renderer passes executablePath explicitly so no browser download is needed.
cd "$HERE/work"
if [ ! -d node_modules/playwright ] || [ ! -d node_modules/@xterm/xterm ]; then
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund --silent \
    playwright@1.48.2 @xterm/xterm@5.5.0 @fontsource/jetbrains-mono@5.1.1 @fontsource/inter@5.1.1
fi
echo "setup: ok"
