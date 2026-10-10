#!/bin/sh
# Generates phone-like test clips for the real-compression tests, using ffmpeg's software encoders only
# (no VideoToolbox). Usage: scripts/make-test-videos.sh [outdir]   (default .scratch/videos)
set -eu
OUT=${1:-.scratch/videos}
mkdir -p "$OUT"
SRC="testsrc2=size=%s:rate=%s,noise=alls=12:allf=t+u"
AUD="sine=frequency=440:sample_rate=48000"
# Tag like iPhone SDR footage (BT.709, video range).
TAGS="-color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709"
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# 1080p30 H.264 + AAC at ~20 Mbps (typical iPhone "Most Compatible")
ff -f lavfi -i "$(printf "$SRC" 1920x1080 30)" -f lavfi -i "$AUD" -t 12 \
   -c:v libx264 -preset veryfast -b:v 20M -maxrate 22M -bufsize 40M -pix_fmt yuv420p $TAGS \
   -c:a aac -b:a 160k -shortest "$OUT/landscape-1080p30-h264.mov"
# Portrait: 1080p stored landscape with a 90-degree display rotation, like phone footage
ff -f lavfi -i "$(printf "$SRC" 1920x1080 30)" -f lavfi -i "$AUD" -t 10 \
   -c:v libx264 -preset veryfast -b:v 20M -maxrate 22M -bufsize 40M -pix_fmt yuv420p $TAGS \
   -c:a aac -b:a 160k -shortest "$OUT/.portrait-unrotated.mov"
ff -display_rotation 90 -i "$OUT/.portrait-unrotated.mov" -c copy "$OUT/portrait-rotated-1080p-h264.mov"
rm -f "$OUT/.portrait-unrotated.mov"
# 4K60 H.264 at ~55 Mbps, no audio
ff -f lavfi -i "$(printf "$SRC" 3840x2160 60)" -t 5 \
   -c:v libx264 -preset ultrafast -b:v 55M -maxrate 60M -bufsize 110M -pix_fmt yuv420p $TAGS \
   "$OUT/4k60-h264-silent.mov"
# Already-efficient HEVC, big enough to pass the size gate (should be skipped as efficient)
ff -f lavfi -i "$(printf "$SRC" 1920x1080 30)" -t 45 \
   -c:v libx265 -preset ultrafast -b:v 4M -tag:v hvc1 -pix_fmt yuv420p $TAGS -x265-params log-level=error \
   "$OUT/efficient-hevc-1080p.mov"
# Noise-free 1080p (random grain is incompressible and makes SSIM meaningless; score quality on this one)
ff -f lavfi -i "testsrc2=size=1920x1080:rate=30" -f lavfi -i "$AUD" -t 15 \
   -c:v libx264 -preset veryfast -b:v 17M -maxrate 17M -bufsize 34M -pix_fmt yuv420p $TAGS \
   -c:a aac -b:a 160k -shortest "$OUT/clean-1080p30-h264.mov"
# Too short (should be skipped)
ff -f lavfi -i "$(printf "$SRC" 1280x720 30)" -t 2 \
   -c:v libx264 -preset veryfast -b:v 20M -pix_fmt yuv420p $TAGS "$OUT/too-short-2s.mov"
ls -l "$OUT"
