#!/usr/bin/env bash
#
# Render every screen of the web UI to a PNG, without a device or a Mac.
#
# The UI is a single self-contained HTML file whose screens are switched by
# window.bfgNativeGo(name) — the same entry point the iOS WKWebView calls. That
# function is global, so a small injected script can drive it from headless
# Chrome and every screen can be inspected as an image.
#
# Screens render with placeholder values because no native layer feeds them
# state; this validates layout, spacing and safe-area behaviour, not data.
#
# Requires: google-chrome (or chromium), and a CJK font (fonts-noto-cjk),
# otherwise Chinese text renders as tofu boxes.
#
# Usage: Tools/render-screens.sh [output-dir] [width] [height]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HTML="$ROOT/ios/BFGCalibration/Resources/bfg-calibration-flow.html"
OUT="${1:-$ROOT/build/screenshots}"
WIDTH="${2:-390}"
HEIGHT="${3:-844}"

CHROME="${CHROME:-google-chrome}"
command -v "$CHROME" >/dev/null || CHROME=chromium
command -v "$CHROME" >/dev/null || { echo "no chrome/chromium found" >&2; exit 1; }

mkdir -p "$OUT" /tmp/bfg-screens

# Every value bfgNativeGo accepts in the render() switch.
SCREENS=(
  home review write vehicles settings
  pair-list pair-ready connect-ready
  pair-progress connect-progress write-progress
  post-write-check scan-progress scan-result
)

for screen in "${SCREENS[@]}"; do
  page="/tmp/bfg-screens/$screen.html"
  python3 - "$HTML" "$page" "$screen" <<'PY'
import sys
src, dest, screen = sys.argv[1], sys.argv[2], sys.argv[3]
inject = (
    '<script>window.addEventListener("load",function(){'
    f'window.bfgNativeGo && window.bfgNativeGo("{screen}");'
    '});</script>'
)
with open(src, encoding='utf-8') as handle:
    html = handle.read()
with open(dest, 'w', encoding='utf-8') as handle:
    handle.write(html.replace('</body>', inject + '</body>'))
PY

  "$CHROME" --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
    --virtual-time-budget=4000 \
    --window-size="$WIDTH,$HEIGHT" \
    --screenshot="$OUT/$screen.png" \
    "file://$page" >/dev/null 2>&1 || true

  if [ -s "$OUT/$screen.png" ]; then
    printf '  %-18s %s\n' "$screen" "$OUT/$screen.png"
  else
    printf '  %-18s FAILED\n' "$screen"
  fi
done

echo
echo "Rendered ${#SCREENS[@]} screens at ${WIDTH}x${HEIGHT} into $OUT"
