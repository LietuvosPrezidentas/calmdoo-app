#!/bin/bash
# Builds Booster.app.
#   ./build.sh                       build only
#   ./build.sh install               also copy to ~/Applications and start it
#   ./build.sh install --test-hooks  a test build: listens to tools/ctl.sh and logs every event.
#                                    Never hand that one to anyone: any app on the Mac can drive it.
set -euo pipefail
cd "$(dirname "$0")"

FLAGS=()
if [[ " $* " == *" --test-hooks "* ]]; then FLAGS=(-Xswiftc -DBOOSTER_TEST_HOOKS); fi
swift build -c release ${FLAGS[@]+"${FLAGS[@]}"}

APP=build/Booster.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Booster "$APP/Contents/MacOS/Booster"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature (this Mac has no developer certificate) with the default requirement, which pins
# the permission to this exact build: macOS asks again after each rebuild, and nothing else can
# claim Booster's permission. Hardened runtime stops code being injected into Booster.
# A public release needs a Developer ID signature and notarization instead.
codesign --force --sign - --identifier local.booster.Booster --options runtime "$APP"
echo "built $APP${FLAGS[@]+ (test hooks on)}"

if [[ " $* " == *" install "* ]]; then
  pkill -x Booster || true
  sleep 0.5
  mkdir -p ~/Applications
  rm -rf ~/Applications/Booster.app
  ditto "$APP" ~/Applications/Booster.app
  open ~/Applications/Booster.app
  echo "installed and started ~/Applications/Booster.app"
fi
