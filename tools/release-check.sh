#!/bin/bash
# Refuses a release unless the app in the zip is signed with a Developer ID, has hardened runtime,
# and is notarized by Apple with the ticket stapled. That, not a checksum on the website, is what
# protects people: macOS itself checks Apple's signature before the app opens.
# On success it records the zip, its SHA-256 and the Team ID in release-verified.txt, which
# tools/deploy-site.sh requires before it puts a download link on the site.
#   tools/release-check.sh path/to/calmdoo.zip https://calmdoo.com/calmdoo.zip
set -uo pipefail
cd "$(dirname "$0")/.."

ZIP="${1:?usage: tools/release-check.sh calmdoo.zip https://calmdoo.com/calmdoo.zip}"
URL="${2:?give the address the zip will be downloaded from}"
refuse() { echo "REFUSED: $1"; exit 1; }

[[ "$URL" == https://calmdoo.com/* ]] || refuse "the download must come from https://calmdoo.com/ (the privacy policy says files come from calmdoo.com)"
[ -f "$ZIP" ] || refuse "no file at $ZIP"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$ZIP" "$WORK" 2>/dev/null || refuse "not a readable zip"
APP=$(find "$WORK" -maxdepth 2 -name "*.app" | head -1)
[ -n "$APP" ] || refuse "no .app inside the zip"

info=$(codesign -dv --verbose=2 "$APP" 2>&1)
team=$(echo "$info" | sed -n 's/^TeamIdentifier=//p')
echo "$info" | grep -q "^Authority=Developer ID Application" \
  || refuse "not signed with a Developer ID ($(echo "$info" | grep -m1 -E '^(Signature|Authority)='))"
[ -n "$team" ] && [ "$team" != "not set" ] || refuse "no Team ID in the signature"
echo "$info" | grep -q "^CodeDirectory.*flags=.*runtime" || refuse "hardened runtime is off"
codesign --verify --deep --strict "$APP" 2>/dev/null || refuse "the signature does not verify (file changed after signing?)"
spctl -a -t exec -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" || refuse "Gatekeeper does not accept it as notarized"
xcrun stapler validate "$APP" >/dev/null 2>&1 || refuse "no notarization ticket stapled to the app"

sum=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
printf 'url %s\nzip %s\nsha256 %s\nteam %s\nchecked %s\n' \
  "$URL" "$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")" "$sum" "$team" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > release-verified.txt
echo "ACCEPTED: Developer ID team $team, hardened runtime, notarized and stapled."
echo "SHA-256 $sum  (put this and the Team ID in the release notes)"
