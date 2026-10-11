#!/usr/bin/env bash
# After both MP4s exist: poster, README GIF, one check frame per beat, ffprobe report.
set -euo pipefail
W="$(cd "$(dirname "$0")" && pwd)"; V="$(cd "$W/.." && pwd)"; OUT="$V/out"
cd "$W"
# Times come from the rendered timelines.
read POSTER GIF0 GIF1 < <(python3 - <<'PY'
import json
t = json.load(open("tmp/timeline-guide.json"))["timeline"]
done = [float(e[0]) for e in t["notch"] if e[1] == "v13-done"][0]
added = t["r1"]["added"]
print(f"{done + 0.9:.3f} {added - 5.6:.3f} {added + 2.0:.3f}")
PY
)
echo "poster at $POSTER s; gif $GIF0..$GIF1"
node render.mjs guide /dev/null --stills $(python3 -c "print(round($POSTER*30))") --dir tmp/poster >/dev/null
cp tmp/poster/guide-*.png "$OUT/poster.png"

# GIF: 960 px, 15 fps, the tail cross-fades into the head so the loop has no jump.
D=$(python3 -c "print($GIF1-$GIF0)")
ffmpeg -y -loglevel error -ss "$GIF0" -t "$D" -i "$OUT/monotask-guide.mp4" -vf "fps=15,scale=960:-1:flags=lanczos" -c:v libx264 -crf 10 -pix_fmt yuv444p tmp/gifsrc.mp4
X=0.6; L=$(python3 -c "print($D-$X)")
ffmpeg -y -loglevel error -i tmp/gifsrc.mp4 -filter_complex \
 "[0]split[a][b];[a]trim=0:$X,setpts=PTS-STARTPTS[head];[b]trim=$X,setpts=PTS-STARTPTS[body];[body][head]xfade=transition=fade:duration=$X:offset=$(python3 -c "print($L-$X)")[v]" \
 -map "[v]" -c:v libx264 -crf 10 -pix_fmt yuv444p tmp/gifloop.mp4
ffmpeg -y -loglevel error -i tmp/gifloop.mp4 -vf "palettegen=max_colors=192:stats_mode=diff" tmp/palette.png
ffmpeg -y -loglevel error -i tmp/gifloop.mp4 -i tmp/palette.png -lavfi "paletteuse=dither=sierra2_4a:diff_mode=rectangle" -loop 0 "$OUT/readme.gif"
ls -la "$OUT/readme.gif"
