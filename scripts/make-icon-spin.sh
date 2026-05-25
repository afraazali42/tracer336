#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# make-icon-spin.sh — Generate docs/assets/icon-spin.gif from the app's SVGs
# ─────────────────────────────────────────────────────────────────────────────
#
# Composites the three menu bar icon layers (outer ring, middle ring, center)
# into a looping animated GIF that mimics the app's drag-spin animation:
#   - Outer ring rotates counter-clockwise
#   - Middle ring rotates clockwise (opposite direction)
#   - Center dot stays static
#
# The original SVGs use white fill (designed for template rendering inside the
# menu bar). For README use we re-tint to a neutral grey stack (matches the
# site's favicon) so it's readable on both light and dark README backgrounds.
#
# Usage:
#   scripts/make-icon-spin.sh
#
# Requires: sips (macOS built-in), ffmpeg
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_SRC="$REPO_ROOT/TRACER336/Assets.xcassets"
OUT_DIR="$REPO_ROOT/docs/assets"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$OUT_DIR"

SIZE=400        # Final GIF size in px
DURATION=2.0    # Seconds of ffmpeg-rendered motion per full rotation
FPS=30          # Source frame rate (kept smooth — playback speed is set below)
PLAYBACK_DELAY=10 # Centiseconds per frame in final GIF (gifsicle --delay).
                  # Higher = slower spin. 10 ≈ 10fps display, so a 2s source
                  # animation plays back over ~5.9s per rotation (calm).

OUTER_SVG="$ASSETS_SRC/MenuBarOuterRing.imageset/OuterRing.svg"
MIDDLE_SVG="$ASSETS_SRC/MenuBarMiddleRing.imageset/MiddleRing.svg"
CENTER_SVG="$ASSETS_SRC/MenuBarCenter.imageset/Center.svg"

# ─── Re-tint SVGs to grey ─────────────────────────────────────────────────────
# Original SVGs use fill="#fff" — swap to greys that work on light + dark.
sed 's/fill="#fff"/fill="#bbbbbb"/g' "$OUTER_SVG"  > "$TMP_DIR/outer.svg"
sed 's/fill="#fff"/fill="#999999"/g' "$MIDDLE_SVG" > "$TMP_DIR/middle.svg"
sed 's/fill="#fff"/fill="#777777"/g' "$CENTER_SVG" > "$TMP_DIR/center.svg"

# ─── SVG → PNG via sips ───────────────────────────────────────────────────────
echo "→ Rendering SVG layers at ${SIZE}x${SIZE}..."
for layer in outer middle center; do
  sips -s format png -Z "$SIZE" "$TMP_DIR/${layer}.svg" \
       --out "$TMP_DIR/${layer}.png" > /dev/null 2>&1
done

# ─── Compose rotating animation with ffmpeg ───────────────────────────────────
# Each layer is rotated independently using ffmpeg's rotate filter. For a
# seamless loop we need a full 2π rotation by t=DURATION, so angular rate is
# 2π/DURATION rad/sec → expression t*2*PI/D.
# Outer goes CCW (negative angle), middle goes CW (positive), center is static.
echo "→ Compositing animation..."
RATE_EXPR="2*PI/${DURATION}"
ffmpeg -y -loglevel error -stats \
  -loop 1 -t "$DURATION" -i "$TMP_DIR/outer.png"  \
  -loop 1 -t "$DURATION" -i "$TMP_DIR/middle.png" \
  -loop 1 -t "$DURATION" -i "$TMP_DIR/center.png" \
  -filter_complex "
    [0:v]format=rgba,rotate=-t*${RATE_EXPR}:c=none:ow=${SIZE}:oh=${SIZE}[outer];
    [1:v]format=rgba,rotate=t*${RATE_EXPR}:c=none:ow=${SIZE}:oh=${SIZE}[middle];
    [2:v]format=rgba[center];
    color=c=black@0:s=${SIZE}x${SIZE}:r=${FPS},format=rgba[bg];
    [bg][outer]overlay=shortest=1[a];
    [a][middle]overlay[b];
    [b][center]overlay,fps=${FPS},split[s0][s1];
    [s0]palettegen=stats_mode=full:reserve_transparent=1[p];
    [s1][p]paletteuse=dither=bayer:bayer_scale=4:alpha_threshold=128
  " \
  -loop 0 \
  "$OUT_DIR/icon-spin.gif"

# ─── Slow playback + lossless optimize with gifsicle ──────────────────────────
# Sets each frame's display delay to PLAYBACK_DELAY centiseconds, then runs
# the maximum lossless optimizer. We deliberately avoid --lossy because it
# softens the crisp grey ring edges in a visible way.
if command -v gifsicle >/dev/null 2>&1; then
  echo "→ Slowing playback + lossless optimizing with gifsicle..."
  gifsicle --delay "$PLAYBACK_DELAY" -O3 -b "$OUT_DIR/icon-spin.gif"
else
  echo "⚠ gifsicle not installed — skipping optimization. brew install gifsicle"
fi

size=$(stat -f%z "$OUT_DIR/icon-spin.gif")
printf "\nDone. icon-spin.gif: %6.1f KB\n" "$(echo "scale=1; $size/1024" | bc)"
