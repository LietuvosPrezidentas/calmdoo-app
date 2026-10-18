#!/bin/bash
# Checks that calmdoo.com is still exactly what was deployed and still locked down.
# Catches: a defaced or swapped page, a changed download link, dropped security headers,
# HTTPS problems, a certificate about to expire, a lost domain lock, changed DNS.
# Sends nothing anywhere: it only fetches the public site and public records. DNS is asked of a
# public resolver (1.1.1.1), not this Mac, so a stale local cache cannot hide a change.
#   tools/site-monitor.sh            exit 0 = all good, 1 = something to look at
set -uo pipefail
cd "$(dirname "$0")/.."

DOMAIN=calmdoo.com
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

headers=$(curl -sSI --max-time 15 "https://$DOMAIN/" 2>&1) || fail "https://$DOMAIN/ did not answer"
echo "$headers" | head -1 | grep -q " 200" && pass "HTTPS answers 200" || fail "HTTPS status: $(echo "$headers" | head -1)"

redirect=$(curl -sSI --max-time 15 "http://$DOMAIN/" 2>&1 | grep -i '^location:' | tr -d '\r')
[[ "$redirect" == *"https://$DOMAIN"* ]] && pass "http:// redirects to https://" || fail "http:// does not redirect to https:// ($redirect)"

for h in "strict-transport-security" "content-security-policy" "x-content-type-options" "x-frame-options" "referrer-policy" "permissions-policy"; do
  echo "$headers" | grep -qi "^$h:" && pass "header $h" || fail "missing header $h"
done
echo "$headers" | grep -qi "^content-security-policy:.*fonts.googleapis" && fail "CSP allows Google Fonts"

# Compare with what was last prepared for deploy (tools/deploy-site.sh writes it into ~/calmdoo).
deployed="$HOME/calmdoo/index.html"; [ -f "$deployed" ] || deployed=site/index.html
live=$(curl -sS --max-time 15 "https://$DOMAIN/" | shasum -a 256 | cut -d' ' -f1)
[ "$live" = "$(shasum -a 256 "$deployed" | cut -d' ' -f1)" ] && pass "live page matches $deployed" || fail "live page differs from $deployed (not deployed yet, or changed by someone)"

end=$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -n "$end" ]; then
  days=$(( ( $(date -j -f "%b %e %T %Y %Z" "$end" +%s) - $(date +%s) ) / 86400 ))
  [ "$days" -gt 14 ] && pass "certificate valid for $days more days" || fail "certificate expires in $days days"
else
  fail "could not read the certificate"
fi

status=$(curl -sS --max-time 15 "https://rdap.verisign.com/com/v1/domain/$DOMAIN" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin).get('status', [])))" 2>/dev/null)
[[ "$status" == *"transfer prohibited"* ]] && pass "domain transfer lock on" || fail "domain transfer lock OFF ($status)"

ns=$(dig +short NS "$DOMAIN" @1.1.1.1 | sort | tr '\n' ' ')
[[ "$ns" == *"vercel-dns.com"* ]] && pass "nameservers: $ns" || fail "nameservers changed: $ns"
caa=$(dig +short CAA "$DOMAIN" @1.1.1.1 | tr '\n' ' ')
[ -n "$caa" ] && pass "CAA limits who can issue certificates" || fail "no CAA record"
spf=$(dig +short TXT "$DOMAIN" @1.1.1.1 | grep -c 'v=spf1')
dmarc=$(dig +short TXT "_dmarc.$DOMAIN" @1.1.1.1 | grep -c 'v=DMARC1')
[ "$spf" -gt 0 ] && [ "$dmarc" -gt 0 ] && pass "SPF and DMARC block fake @$DOMAIN email" || fail "no SPF/DMARC: anyone can send email pretending to be @$DOMAIN"

echo "---"
[ $fails -eq 0 ] && echo "all good" || { echo "$fails thing(s) to look at"; exit 1; }
