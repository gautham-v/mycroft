#!/bin/zsh
# Render design/app-icon.svg into the app icon and in-app logo PNGs. Uses headless Chrome (the icon
# relies on mix-blend-mode and a blur filter) and ImageMagick for the smaller Mac sizes.
set -eu
ROOT=${0:A:h:h}
SVG=$ROOT/design/app-icon.svg
ASSETS=$ROOT/App/Openfeed/Resources/Assets.xcassets
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT
cp $SVG $TMP/icon.svg

# shot <name> <canvas px> <inset px> <tile px> <corner radius px; 0 = square>
shot() {
  cat > $TMP/$1.html <<EOF
<!doctype html><html><body style="margin:0;background:transparent">
<div style="position:absolute;left:$3px;top:$3px;width:$4px;height:$4px;border-radius:$5px;overflow:hidden">
<img src="icon.svg" width="$4" height="$4" style="display:block"></div></body></html>
EOF
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size=$2,$2 \
    --screenshot=$TMP/$1.png file://$TMP/$1.html 2>/dev/null
}

# iOS masks the corners itself, so its icon is full bleed. The Mac icon follows Apple's template:
# an 824 px rounded square inset 100 px on a transparent 1024 canvas.
shot ios 1024 0 1024 0
shot mac 1024 100 824 185
shot logo 512 0 512 115

# App Store Connect rejects an iOS icon with an alpha channel.
magick $TMP/ios.png -background black -alpha remove -alpha off $ASSETS/AppIcon.appiconset/icon-ios-1024.png
cp $TMP/mac.png $ASSETS/AppIcon.appiconset/icon-mac-1024.png
for size in 512 256 128 64 32 16; do
  magick $TMP/mac.png -filter Lanczos -resize ${size}x${size} $ASSETS/AppIcon.appiconset/icon-mac-$size.png
done
cp $TMP/logo.png $ASSETS/AppLogo.imageset/icon-512.png
