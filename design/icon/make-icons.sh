#!/bin/bash
# Renders the PixelPare icon SVGs into Xcode asset catalogs and a macOS .icns.
# Usage: ./make-icons.sh   (needs Google Chrome; uses macOS sips + iconutil)
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
python3 gen-macos-svg.py
OUT=build; rm -rf "$OUT"; mkdir -p "$OUT"

render() { # svg -> 1024 png with transparent background
  cat > "$OUT/_r.html" <<HTML
<html><body style="margin:0;background:transparent"><img src="../$1" width="1024" height="1024" style="display:block"></body></html>
HTML
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --default-background-color=00000000 --window-size=1024,1024 \
    --screenshot="$PWD/$OUT/$2" "file://$PWD/$OUT/_r.html" 2>/dev/null
  rm "$OUT/_r.html"
}
render pixelpare-icon.svg ios-1024.png
render pixelpare-icon-macos.svg macos-1024.png

# iOS: single 1024 universal icon (Xcode 14+); iOS applies its own mask. Must be opaque.
IOS=$OUT/AppIcon-iOS.appiconset; mkdir -p "$IOS"
sips -s format jpeg "$OUT/ios-1024.png" --out "$OUT/_o.jpg" >/dev/null   # flatten alpha
sips -s format png "$OUT/_o.jpg" --out "$IOS/icon-1024.png" >/dev/null; rm "$OUT/_o.jpg"
cat > "$IOS/Contents.json" <<JSON
{ "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 } }
JSON

# macOS: 16..512 @1x/@2x, plus .icns
MAC=$OUT/AppIcon-macOS.appiconset; ICONSET=$OUT/PixelPare.iconset; mkdir -p "$MAC" "$ICONSET"
entries=""
for s in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((s*scale)); name="icon_${s}x${s}"; [ $scale = 2 ] && name="${name}@2x"
    sips -z $px $px "$OUT/macos-1024.png" --out "$MAC/$name.png" >/dev/null
    cp "$MAC/$name.png" "$ICONSET/$name.png"
    entries="$entries{ \"filename\" : \"$name.png\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${s}x${s}\" },"
  done
done
echo "{ \"images\" : [ ${entries%,} ], \"info\" : { \"author\" : \"xcode\", \"version\" : 1 } }" > "$MAC/Contents.json"
iconutil -c icns "$ICONSET" -o "$OUT/PixelPare.icns"
rm -rf "$ICONSET"
echo "Built: $(ls $OUT)"
