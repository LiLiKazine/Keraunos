#!/bin/bash
# Render every out/*.html poster to out/png/<name>.png at exact WxH.
set -u
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p out/png
pids=()
i=0
for f in out/*.html; do
  base="$(basename "$f" .html)"
  wh="${base##*__}"            # e.g. 1320x2868
  W="${wh%x*}"; H="${wh#*x}"
  prof="$PWD/.chrome/$i"; mkdir -p "$prof"
  "$CHROME" --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --no-first-run --no-default-browser-check --disable-background-networking \
    --disable-extensions --user-data-dir="$prof" \
    --force-device-scale-factor=1 --window-size="$W,$H" \
    --screenshot="$PWD/out/png/$base.png" "file://$PWD/$f" >/dev/null 2>&1 &
  pids+=($!)
  i=$((i+1))
done
# Wait for all PNGs to appear (up to 40s), then kill lingering Chromes.
for t in $(seq 1 40); do
  done=1
  for f in out/*.html; do b="$(basename "$f" .html)"; [ -s "out/png/$b.png" ] || done=0; done
  [ "$done" = 1 ] && break
  sleep 1
done
for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null; done
pkill -f "$PWD/.chrome" 2>/dev/null
echo "rendered after ${t}s:"
for f in out/png/*.png; do printf "%s  " "$(basename "$f")"; sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | tail -2 | tr '\n' ' '; echo; done
