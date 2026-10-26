#!/bin/zsh
# Build a release of the Mac app for direct download: archive, sign with Developer ID, notarize and
# staple the app, package it as a DMG (signed, notarized, stapled), and write the Sparkle appcast.
#
#   scripts/release-mac.sh [ref]      (default HEAD)
#
# Builds from a clean, temporary worktree of the commit, so uncommitted edits in this checkout never
# end up in a release.
# The version is MARKETING_VERSION / CURRENT_PROJECT_VERSION in App/project.yml; bump
# CURRENT_PROJECT_VERSION for every release (Sparkle compares it). Output in App/build/release/:
# OpenDispatch-<version>.dmg and appcast.xml, both attached to the GitHub release v<version>
# (SUFeedURL points at the latest release's appcast.xml). Release notes: put
# OpenDispatch-<version>.md next to the DMG before running generate_appcast, or edit the release.
#
# Needs: the "Developer ID Application" certificate and Sparkle's EdDSA private key in the login
# keychain, and ~/.appstoreconnect/opendispatch.env (ASC_KEY_ID, ASC_ISSUER, ASC_KEY) for notarization.
set -euo pipefail
ROOT=${0:A:h:h}
APP_DIR=$ROOT/App
DD=$APP_DIR/build/rel
OUT=$APP_DIR/build/release
source ~/.appstoreconnect/opendispatch.env
AUTH=(-authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER")
NOTARY=(--key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER")
IDENTITY="Developer ID Application"

REF=${1:-HEAD}
SRC=$(mktemp -d)/opendispatch
git -C $ROOT worktree add --detach --quiet $SRC $REF
trap 'git -C $ROOT worktree remove --force $SRC' EXIT
cd $SRC/App

# Run a step up to three times (stapler and hdiutil fail now and then on a dropped connection or a busy file).
retry() {
  for attempt in 1 2 3; do
    "$@" && return 0
    [[ $attempt == 3 ]] && return 1
    sleep 5
  done
}
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)
echo "== OpenDispatch $VERSION ($BUILD) from $(git -C $SRC log -1 --format='%h %s')"
rm -rf $OUT && mkdir -p $OUT/updates

xcodegen generate --quiet
xcodebuild archive -project OpenDispatch.xcodeproj -scheme OpenDispatch -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath $DD -archivePath $OUT/OpenDispatch.xcarchive \
  -allowProvisioningUpdates $AUTH -quiet

cat > $OUT/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>26TVJ92MLZ</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath $OUT/OpenDispatch.xcarchive -exportPath $OUT/export \
  -exportOptionsPlist $OUT/ExportOptions.plist -allowProvisioningUpdates $AUTH -quiet
APP=$OUT/export/OpenDispatch.app
codesign --verify --deep --strict $APP

echo "== Notarizing the app"
ditto -c -k --keepParent $APP $OUT/OpenDispatch.zip
xcrun notarytool submit $OUT/OpenDispatch.zip $NOTARY --wait
retry xcrun stapler staple $APP

echo "== Building the DMG"
DMG=$OUT/updates/OpenDispatch-$VERSION.dmg
mkdir -p $OUT/dmg && ditto $APP $OUT/dmg/OpenDispatch.app && ln -s /Applications $OUT/dmg/Applications
retry hdiutil create -volname OpenDispatch -srcfolder $OUT/dmg -ov -format UDZO $DMG -quiet
codesign --sign "$IDENTITY" --timestamp $DMG
xcrun notarytool submit $DMG $NOTARY --wait
retry xcrun stapler staple $DMG
spctl --assess --type open --context context:primary-signature -v $DMG

echo "== Writing the appcast"
$DD/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/gautham-v/opendispatch/releases/download/v$VERSION/" \
  --link https://github.com/gautham-v/opendispatch --maximum-versions 1 \
  -o $OUT/appcast.xml $OUT/updates
cp $DMG $OUT/
echo "== Done: $OUT/OpenDispatch-$VERSION.dmg, $OUT/appcast.xml"
echo "   Publish: gh release create v$VERSION $OUT/OpenDispatch-$VERSION.dmg $OUT/appcast.xml --title \"OpenDispatch $VERSION\""
