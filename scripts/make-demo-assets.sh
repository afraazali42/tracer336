#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# make-demo-assets.sh — Convert a screen recording into optimized demo assets
# ─────────────────────────────────────────────────────────────────────────────
#
# Takes a .mov (typically from macOS ⌘⇧5 screen recording) and produces:
#   docs/assets/demo.gif  — optimized GIF for README + GitHub previews
#   docs/assets/demo.mp4  — small h264 MP4 for the website (autoplay/loop)
#
# Usage:
#   scripts/make-demo-assets.sh ~/Desktop/tracer-raw.mov
#   scripts/make-demo-assets.sh ~/Desktop/tracer-raw.mov 600   # custom width
#
# Requires: ffmpeg (brew install ffmpeg)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

INPUT="${1:?Usage: $0 <input.mov> [width=600]}"
WIDTH="${2:-600}"

if [ ! -f "$INPUT" ]; then
  echo "error: input file not found: $INPUT" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/docs/assets"
mkdir -p "$OUT_DIR"

GIF_OUT="$OUT_DIR/demo.gif"
MP4_OUT="$OUT_DIR/demo.mp4"

echo "→ Input:  $INPUT"
echo "→ Width:  ${WIDTH}px (height preserves aspect ratio)"
echo "→ Output: $OUT_DIR/demo.{gif,mp4}"
echo

# ─── MP4 (web-optimized) ──────────────────────────────────────────────────────
# H.264, web-streaming friendly (faststart), no audio, 30fps capped.
echo "→ Encoding MP4..."
ffmpeg -y -loglevel error -stats \
  -i "$INPUT" \
  -vf "scale=${WIDTH}:-2:flags=lanczos,fps=30" \
  -c:v libx264 -pix_fmt yuv420p \
  -preset slow -crf 23 \
  -movflags +faststart \
  -an \
  "$MP4_OUT"

# ─── GIF (palette-optimized two-pass) ─────────────────────────────────────────
# Single-command palettegen + paletteuse via split — much better quality than
# default GIF encoding. Dithers to reduce banding on smooth animations.
echo "→ Encoding GIF (two-pass palette)..."
ffmpeg -y -loglevel error -stats \
  -i "$INPUT" \
  -vf "fps=20,scale=${WIDTH}:-2:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer:bayer_scale=4" \
  "$GIF_OUT"

# ─── Report ──────────────────────────────────────────────────────────────────
gif_size=$(stat -f%z "$GIF_OUT" 2>/dev/null || stat -c%s "$GIF_OUT")
mp4_size=$(stat -f%z "$MP4_OUT" 2>/dev/null || stat -c%s "$MP4_OUT")

echo
echo "Done."
printf "  %-15s  %6.2f MB\n" "demo.gif" "$(echo "scale=2; $gif_size/1048576" | bc)"
printf "  %-15s  %6.2f MB\n" "demo.mp4" "$(echo "scale=2; $mp4_size/1048576" | bc)"
echo
echo "If demo.gif is over ~5 MB, re-run with a smaller width (e.g. 500)."
