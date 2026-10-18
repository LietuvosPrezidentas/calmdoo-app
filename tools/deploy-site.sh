#!/bin/bash
# Gets the site ready to publish at calmdoo.com: runs every check, copies the site (and, with a
# release, the verified zip) into ~/calmdoo, the folder linked to the calmdoo Vercel project, and
# prints the one command that publishes it. It never publishes by itself: that is the owner's call.
#   tools/deploy-site.sh                                    site only; download says "coming soon"
#   tools/deploy-site.sh https://calmdoo.com/calmdoo.zip    with the download (run tools/release-check.sh first)
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="$HOME/calmdoo"
URL="${1:-}"

python3 site/build.py                      # pages, outside addresses, fonts, blanks, secret scan
[ -d "$DEST/.vercel" ] || { echo "REFUSED: $DEST is not linked to Vercel"; exit 1; }

if [ -n "$URL" ]; then
  grep -qxF "url $URL" release-verified.txt 2>/dev/null \
    || { echo "REFUSED: run tools/release-check.sh on the zip for $URL first"; exit 1; }
  zip=$(sed -n 's/^zip //p' release-verified.txt)
  [ "$(shasum -a 256 "$zip" | cut -d' ' -f1)" = "$(sed -n 's/^sha256 //p' release-verified.txt)" ] \
    || { echo "REFUSED: the zip changed after it was checked"; exit 1; }
fi

# Never upload secrets or tooling: .env* holds a Vercel token. Vercel builds public/ itself.
printf '%s\n' '.env*' '.vercel' 'public' '*.md' '.DS_Store' 'release-verified.txt' > "$DEST/.vercelignore"
for f in index.html privacy.html build.py vercel.json favicon.svg favicon.ico favicon-32.png apple-touch-icon.png; do cp "site/$f" "$DEST/$f"; done
if [ -d site/fonts ]; then rm -rf "$DEST/fonts"; cp -R site/fonts "$DEST/fonts"; fi
if [ -n "$URL" ]; then
  cp "$zip" "$DEST/$(basename "$URL")"
  # The link goes into the HTML itself; the pinned script and style blocks do not change.
  sed -i '' "s|href=\"#get\" data-download|href=\"$URL\" data-download|g" "$DEST/index.html"
fi

# The same build Vercel runs, done here first; then the served folder is checked for anything secret.
(cd "$DEST" && python3 build.py --verify --out public)
leak=$(cd "$DEST/public" && find . -type f ! -name '*.html' ! -path './fonts/*.woff2' ! -path './fonts/OFL-*.txt' ! -path './*.zip' ! -name 'favicon.svg' ! -name 'favicon.ico' ! -name 'favicon-32.png' ! -name 'apple-touch-icon.png')
[ -z "$leak" ] || { echo "REFUSED: unexpected files would be served: $leak"; exit 1; }
rm -rf "$DEST/public"
tools/secret-scan.sh "$DEST"

echo
echo "Ready in $DEST. To publish:   cd ~/calmdoo && vercel deploy --prod"
echo "Afterwards, check it:          tools/site-monitor.sh"
