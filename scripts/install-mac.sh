#!/bin/zsh
# Build the Release Mac app from this checkout, replace /Applications/OpenDispatch.app and relaunch it.
# The post-commit hook runs this in the background after every commit on main that touches App/ or
# Core/ (install with scripts/install-hooks.sh). Output goes to App/build/install.log. A commit that
# lands while a build is running queues one more build instead of starting a second.
set -u
ROOT=${0:A:h:h}
BUILD=$ROOT/App/build
LOCK=$BUILD/install.lock
PENDING=$BUILD/install.pending
LOG=$BUILD/install.log
APP=/Applications/OpenDispatch.app
mkdir -p $BUILD

if ! mkdir $LOCK 2>/dev/null; then
  touch $PENDING
  exit 0
fi
trap 'rmdir $LOCK' EXIT

notify() { osascript -e "display notification \"$1\" with title \"OpenDispatch\"" >/dev/null 2>&1 }

while true; do
  rm -f $PENDING
  {
    echo "== $(date '+%F %T') $(git -C $ROOT log -1 --format='%h %s')"
    cd $ROOT/App || exit 1
    xcodegen generate --quiet &&
    xcodebuild -project Openfeed.xcodeproj -scheme Openfeed -configuration Release \
      -destination 'platform=macOS' -derivedDataPath $BUILD build -quiet
  } >> $LOG 2>&1
  if [[ $? -ne 0 ]]; then
    notify "Build failed, see App/build/install.log"
  else
    osascript -e 'tell application id "com.gauthamv.openfeed" to quit' >/dev/null 2>&1
    for i in {1..20}; do pgrep -xq OpenDispatch || break; sleep 0.5; done
    if pgrep -xq OpenDispatch; then
      notify "Could not quit the running app; install skipped"
    else
      rm -rf $APP && ditto $BUILD/Build/Products/Release/OpenDispatch.app $APP && open $APP
      echo "installed $(date '+%T')" >> $LOG
    fi
  fi
  [[ -e $PENDING ]] || break
done
