#!/bin/sh
# Scores copies kept by RealClipsTests (PIXELPARE_TEST_OUTPUT) against their originals with ffmpeg's SSIM.
# SSIM ≥ 0.98 (PSNR ≥ 40 dB) is visually indistinguishable for most footage. Usage: scripts/score-test-videos.sh [videos] [output]
set -eu
SRC=${1:-.scratch/videos}; OUT=${2:-.scratch/video-output}
# Give both inputs identical colour tags: otherwise ffmpeg converts one of them before comparing and the score
# measures that conversion, not the encode (untagged sources scored ~0.95 instead of ~0.996).
P="setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709"
for copy in "$OUT"/*.mov; do
  base=$(basename "$copy"); clip=${base#*-}; preset=${base%%-*}
  ref="$SRC/$clip"
  # Scale the (display-rotated) reference to the copy's frames so "smallerResolution" is scored as delivered.
  ssim=$(ffmpeg -hide_banner -nostats -i "$copy" -i "$ref" -lavfi "[0:v]$P[c0];[1:v]$P[r0];[r0][c0]scale2ref=flags=bicubic[r][c];[c][r]ssim" \
         -f null - 2>&1 | sed -n 's/.*All:\([0-9.]*\).*/\1/p' | tail -1)
  printf "%-18s %-34s SSIM %s\n" "$preset" "$clip" "$ssim"
done
