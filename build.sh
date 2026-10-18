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
# One app for both Apple silicon and Intel Macs (Intel ones top out at macOS 26; calmdoo needs 15+).
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c release "${ARCHS[@]}" ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)/Booster"
[ "$(lipo -archs "$BIN")" = "x86_64 arm64" ] || { echo "expected an arm64 + x86_64 app, got: $(lipo -archs "$BIN")"; exit 1; }

APP=build/calmdoo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/calmdoo"
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
