#!/bin/bash
# Rasterizes App/Resources/BannyAssets/svg/*.svg → App/Resources/BannyAssets/png/*.png with transparent backgrounds
# using headless Chrome (the only SVG rasterizer with reliable alpha on a stock Mac).
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Chrome not found at $CHROME" >&2; exit 1; }

mkdir -p App/Resources/BannyAssets/png
count=0
for svg in App/Resources/BannyAssets/svg/*.svg; do
  name=$(basename "$svg" .svg)
  png="App/Resources/BannyAssets/png/$name.png"
  [ "$png" -nt "$svg" ] && continue  # incremental
  # width/height attrs are set by the extractor; read them for the window size.
  dims=$(head -c 300 "$svg" | sed -n 's/<svg[^>]* width="\([0-9]*\)" height="\([0-9]*\)".*/\1,\2/p')
  "$CHROME" --headless --disable-gpu --default-background-color=00000000 \
    --window-size="$dims" --screenshot="$png" "file://$PWD/$svg" 2>/dev/null
  count=$((count+1))
done
echo "baked $count PNGs → App/Resources/BannyAssets/png ($(ls App/Resources/BannyAssets/png | wc -l | tr -d ' ') total)"
