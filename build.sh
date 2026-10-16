#!/bin/bash
# Builds Booster.app. "./build.sh install" also copies it to ~/Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Booster.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Booster "$APP/Contents/MacOS/Booster"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature: this Mac has no developer certificate. The explicit requirement makes macOS
# recognise the app by its identifier rather than by this exact build, so the audio permission
# survives rebuilds. Trade-off: anything signed with this identifier on this Mac would match.
codesign --force --sign - --identifier local.booster.Booster \
  -r='designated => identifier "local.booster.Booster"' "$APP"
echo "built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x Booster || true
  sleep 0.5
  mkdir -p ~/Applications
  rm -rf ~/Applications/Booster.app
  ditto "$APP" ~/Applications/Booster.app
  open ~/Applications/Booster.app
  echo "installed and started ~/Applications/Booster.app"
fi
