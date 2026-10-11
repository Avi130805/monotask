#!/usr/bin/env bash
# One reproducible take: rebuild the demo world, then record.  take.sh r1 <name>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; V="$(cd "$HERE/.." && pwd)"
bash "$V/demo/build-world.sh"
mkdir -p /Users/dev/monotask/plugins && rm -rf /Users/dev/monotask/plugins/monotask
cp -r "$V/../../plugins/monotask" /Users/dev/monotask/plugins/monotask
mkdir -p "$V/record/takes"
python3 "$HERE/takes.py" "$1" "$V/work/tmp/$2.json"
python3 "$HERE/rec.py" "$V/work/tmp/$2.json" "$V/record/takes/$2.cast"
echo "take $2: exit $?"; ls /work/monotask-home/inbox
