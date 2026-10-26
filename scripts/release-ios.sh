#!/bin/zsh
# Build the iOS app and put it on TestFlight: archive, upload to App Store Connect, wait for processing,
# then hand the build to the Internal group (scripts/asc-distribute.swift) so it shows up on the phone.
#
#   scripts/release-ios.sh [ref]      (default HEAD)
#
# Builds from a clean, temporary worktree of the commit, like release-mac.sh. The build number is
# CURRENT_PROJECT_VERSION in App/project.yml and must be new to App Store Connect.
#
# Needs ~/.appstoreconnect/opendispatch.env (ASC_KEY_ID, ASC_ISSUER, ASC_KEY).
set -euo pipefail
ROOT=${0:A:h:h}
OUT=$ROOT/App/build/ios-release
source ~/.appstoreconnect/opendispatch.env
export ASC_KEY ASC_KEY_ID ASC_ISSUER
AUTH=(-authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER")

REF=${1:-HEAD}
SRC=$(mktemp -d)/opendispatch
git -C $ROOT worktree add --detach --quiet $SRC $REF
trap 'git -C $ROOT worktree remove --force $SRC' EXIT
cd $SRC/App

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)
echo "== OpenDispatch iOS $VERSION ($BUILD) from $(git -C $SRC log -1 --format='%h %s')"
rm -rf $OUT && mkdir -p $OUT

xcodegen generate --quiet
xcodebuild archive -project OpenDispatch.xcodeproj -scheme OpenDispatch -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath $ROOT/App/build/ios-rel -archivePath $OUT/OpenDispatch-ios.xcarchive \
  -allowProvisioningUpdates $AUTH -quiet

cat > $OUT/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>26TVJ92MLZ</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
echo "== Uploading to App Store Connect"
xcodebuild -exportArchive -archivePath $OUT/OpenDispatch-ios.xcarchive -exportPath $OUT/export \
  -exportOptionsPlist $OUT/ExportOptions.plist -allowProvisioningUpdates $AUTH -quiet

echo "== Waiting for processing, then adding the build to the Internal group"
swift $ROOT/scripts/asc-distribute.swift $BUILD
