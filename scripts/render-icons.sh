#!/bin/zsh
# Render the app icons drawn by design/app-icons.mjs (eight designs in nine colorways) into the asset
# catalog: the default (O + D in Glacier) as AppIcon, every other pair as an iOS alternate icon
# (AlternateIcons/AppIcon-<design>-<colorway>), and every pair as a 512 px picture for Settings and the Mac's
# Dock (IconPreviews/icon-<design>-<colorway>). Needs Node, headless Chrome and ImageMagick.
set -eu
ROOT=${0:A:h:h}
ASSETS=$ROOT/App/OpenDispatch/Resources/Assets.xcassets
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DEFAULT=o-d-glacier
TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT

node $ROOT/design/app-icons.mjs $TMP/svg
cp $TMP/svg/$DEFAULT.svg $ROOT/design/app-icon.svg

# Full-bleed 1024 px renders, four Chrome processes at a time.
render() {
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --user-data-dir=$TMP/chrome-$2 --window-size=1024,1024 \
    --screenshot=$TMP/png/$1.png file://$TMP/svg/$1.svg 2>/dev/null
}
mkdir -p $TMP/png
i=0
for f in $TMP/svg/*.svg; do
  render ${f:t:r} $((i % 4)) &
  i=$((i + 1))
  (( i % 4 == 0 )) && wait
done
wait

contents() { printf '{\n  "images" : [ %s ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' "$1" > $2/Contents.json }
folder() { mkdir -p $1; printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > $1/Contents.json }

rm -rf $ASSETS/AlternateIcons $ASSETS/IconPreviews $ASSETS/AppLogo.imageset
folder $ASSETS/AlternateIcons
folder $ASSETS/IconPreviews
for png in $TMP/png/*.png; do
  id=${png:t:r}
  set=$ASSETS/IconPreviews/icon-$id.imageset
  mkdir -p $set
  magick $png -filter Lanczos -resize 512x512 -strip $set/icon.png
  contents '{ "filename" : "icon.png", "idiom" : "universal" }' $set
  [[ $id == $DEFAULT ]] && continue
  set=$ASSETS/AlternateIcons/AppIcon-$id.appiconset
  mkdir -p $set
  # App Store Connect rejects an iOS icon with an alpha channel.
  magick $png -background black -alpha remove -alpha off -strip $set/icon.png
  contents '{ "filename" : "icon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }' $set
done

# iOS masks the corners itself, so its icon is full bleed. The Mac icon follows Apple's template:
# an 824 px rounded square inset 100 px on a transparent 1024 canvas.
SET=$ASSETS/AppIcon.appiconset
magick $TMP/png/$DEFAULT.png -background black -alpha remove -alpha off -strip $SET/icon-ios-1024.png
cat > $TMP/mac.html <<EOF
<!doctype html><html><body style="margin:0;background:transparent">
<div style="position:absolute;left:100px;top:100px;width:824px;height:824px;border-radius:185px;overflow:hidden">
<img src="svg/$DEFAULT.svg" width="824" height="824" style="display:block"></div></body></html>
EOF
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --user-data-dir=$TMP/chrome-mac \
  --default-background-color=00000000 --window-size=1024,1024 --screenshot=$SET/icon-mac-1024.png file://$TMP/mac.html 2>/dev/null
for size in 512 256 128 64 32 16; do
  magick $SET/icon-mac-1024.png -filter Lanczos -resize ${size}x${size} $SET/icon-mac-$size.png
done
