#!/bin/bash
# Builds calmdoo.app (the Swift package and folder are still called Booster: internal names only).
#   ./build.sh                       build only
#   ./build.sh install               also copy to ~/Applications and start it
#   ./build.sh install --test-hooks  a test build: listens to tools/ctl.sh and logs every event.
#                                    Never hand that one to anyone: any app on the Mac can drive it.
set -euo pipefail
cd "$(dirname "$0")"

# Never build with a key or token anywhere in the repo or its history.
tools/secret-scan.sh > /dev/null || { tools/secret-scan.sh; exit 1; }

FLAGS=()
if [[ " $* " == *" --test-hooks "* ]]; then FLAGS=(-Xswiftc -DBOOSTER_TEST_HOOKS); fi
swift build -c release ${FLAGS[@]+"${FLAGS[@]}"}

APP=build/calmdoo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Booster "$APP/Contents/MacOS/calmdoo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature (this Mac has no developer certificate) with the default requirement, which pins
# the permission to this exact build: macOS asks again after each rebuild, and nothing else can
# claim calmdoo's permission. Hardened runtime stops code being injected into calmdoo.
# A public release needs a Developer ID signature and notarization instead.
codesign --force --sign - --identifier com.calmdoo.app --options runtime "$APP"
echo "built $APP${FLAGS[@]+ (test hooks on)}"

if [[ " $* " == *" install "* ]]; then
  pkill -x calmdoo || true
  sleep 0.5
  mkdir -p ~/Applications
  rm -rf ~/Applications/calmdoo.app
  ditto "$APP" ~/Applications/calmdoo.app
  open ~/Applications/calmdoo.app
  echo "installed and started ~/Applications/calmdoo.app"
fi
