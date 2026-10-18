#!/usr/bin/env python3
"""Checks the calmdoo site and writes vercel.json with its security headers.

    python3 site/build.py           check the pages, write vercel.json
    python3 site/build.py --verify  check only, and fail if vercel.json is missing or out of date
    python3 build.py --verify --out public
                                    what Vercel runs on every deploy (see "buildCommand" below): check,
                                    then copy only the pages and fonts into public/, the one folder served

It exits non-zero, and writes nothing, while anything is wrong. Never deploy on a failure; use
tools/deploy-site.sh, which runs every check first.

What the Content-Security-Policy does: the browser runs only this site's own files plus the exact
inline <style> and <script> blocks of these pages (matched by hash). Script injected into a page,
through a bug or a compromised third party, does not run. What it cannot do: protect against someone
who controls this repo or the Vercel account, because they can change the pages and this file together.
Account security (two-factor sign-in) and Apple's notarization of the app cover that.
"""
import base64
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

SITE = Path(__file__).resolve().parent
VERIFY = "--verify" in sys.argv
OUT = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None

# The only outside addresses a page may link to or load. Anything else is refused, because the
# privacy policy promises that no other company is contacted.
ALLOWED_OUTSIDE = (
    "https://vercel.com/legal/privacy-notice",  # linked from the privacy policy
    "https://vdai.lrv.lt/en/",                    # Lithuania's data protection authority, ditto
    "https://calmdoo.com/",                       # the download, once a release exists
)


def sha256(text: str) -> str:
    return "'sha256-" + base64.b64encode(hashlib.sha256(text.encode()).digest()).decode() + "'"


problems, scripts, styles = [], set(), set()
pages = sorted(SITE.glob("*.html"))
for page in pages:
    html = page.read_text(encoding="utf-8")
    if "[FILL" in html:
        problems.append(f"{page.name}: blanks still to fill ([FILL ...])")
    if re.search(r"fonts\.(googleapis|gstatic)\.com", html):
        problems.append(f"{page.name}: loads Google Fonts, which sends every visitor's IP address to Google. Self-host the fonts in site/fonts/")
    for url in re.findall(r"""(?:src|href|srcset|action)\s*=\s*["']?(https?://[^"'\s>]+)""", html, re.I):
        if "fonts.g" in url:
            continue  # reported above
        if not url.startswith(ALLOWED_OUTSIDE):
            problems.append(f"{page.name}: outside address not on the allowed list: {url}")
    if re.search(r"<[a-z][^>]*\sstyle\s*=", html, re.I):
        problems.append(f"{page.name}: an inline style attribute, which the security policy blocks")
    if re.search(r"<[a-z][^>]*\son[a-z]+\s*=", html, re.I):
        problems.append(f"{page.name}: an inline event handler (onclick=...), which the security policy blocks")
    if re.search(r"<(script|iframe|object|embed)[^>]*\ssrc\s*=", html, re.I):
        problems.append(f"{page.name}: loads a script or frame from a file; inline it or remove it")
    scripts.update(sha256(m) for m in re.findall(r"<script>(.*?)</script>", html, re.S))
    styles.update(sha256(m) for m in re.findall(r"<style>(.*?)</style>", html, re.S))

for font in re.findall(r"url\(['\"]?/?(fonts/[^)'\"]+)", "".join(p.read_text(encoding="utf-8") for p in pages)):
    if not (SITE / font).is_file():
        problems.append(f"missing font file {font}")

scanner = SITE.parent / "tools" / "secret-scan.sh"
if scanner.is_file():  # absent in the deploy copy, which only holds the site
    if subprocess.run([str(scanner)], capture_output=True).returncode != 0:
        problems.append("the secret scan found a key or token in the repo: run tools/secret-scan.sh")

csp = "; ".join([
    "default-src 'none'",
    "script-src " + " ".join(sorted(scripts)),
    "style-src " + " ".join(sorted(styles)),
    "font-src 'self'",
    "img-src 'self' data:",
    "connect-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
])

headers = [
    {"key": "Content-Security-Policy", "value": csp},
    # Browsers remember for two years to use HTTPS only, for calmdoo.com and every subdomain.
    {"key": "Strict-Transport-Security", "value": "max-age=63072000; includeSubDomains"},
    {"key": "X-Content-Type-Options", "value": "nosniff"},
    {"key": "X-Frame-Options", "value": "DENY"},
    {"key": "Referrer-Policy", "value": "no-referrer"},
    {"key": "Cross-Origin-Opener-Policy", "value": "same-origin"},
    {"key": "Cross-Origin-Resource-Policy", "value": "same-origin"},
    {"key": "Permissions-Policy", "value": "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()"},
]

config = {
    # Vercel runs the check on every deploy and refuses to publish if the pages and these headers disagree.
    # Only public/ is served: this script, vercel.json and anything else in the folder never are.
    "buildCommand": "python3 build.py --verify --out public",
    "outputDirectory": "public",
    "cleanUrls": True,
    "headers": [{"source": "/(.*)", "headers": headers}],
}
expected = json.dumps(config, indent=2) + "\n"
target = SITE / "vercel.json"

VERCEL_ADDS = ("name", "version")


def same_config() -> bool:
    # Compared by meaning, not layout: Vercel may reformat vercel.json on its build machine.
    try:
        found = json.loads(target.read_text(encoding="utf-8"))
        # Vercel adds these two on its build machine (seen in its build log, 2026-10-18); everything else must match.
        return {k: v for k, v in found.items() if k not in VERCEL_ADDS} == config
    except (OSError, ValueError):
        return False


if VERIFY and not same_config():
    problems.append("vercel.json is missing or out of date: run python3 build.py and redeploy")
    # Say exactly what differs, so a failure on Vercel's build machine can be read from its log.
    print(f"python {sys.version.split()[0]}, filesystem encoding {sys.getfilesystemencoding()}")
    try:
        found_config = json.loads(target.read_text(encoding="utf-8"))
        for key in sorted(set(found_config) | set(config)):
            if key != "headers" and key not in VERCEL_ADDS and found_config.get(key) != config.get(key):
                print(f"  setting {key} differs: expected {config.get(key)!r}, found {found_config.get(key)!r}")
        found = {h["key"]: h["value"] for h in found_config["headers"][0]["headers"]}
        for h in headers:
            if found.get(h["key"]) != h["value"]:
                print(f"  {h['key']} differs:\n    expected {h['value'][:300]}\n    found    {str(found.get(h['key']))[:300]}")
    except Exception as e:
        print(f"  could not read vercel.json: {e}")

if problems:
    print("NOT READY TO DEPLOY:")
    for p in problems:
        print("  -", p)
    sys.exit(1)

if VERIFY:
    print(f"OK: {len(pages)} pages match vercel.json")
    if OUT:
        out = SITE / OUT
        shutil.rmtree(out, ignore_errors=True)
        out.mkdir()
        for page in pages:
            shutil.copy2(page, out / page.name)
        if (SITE / "fonts").is_dir():
            shutil.copytree(SITE / "fonts", out / "fonts")
        for release in SITE.glob("*.zip"):  # the app download, placed here by tools/deploy-site.sh
            shutil.copy2(release, out / release.name)
        print(f"Copied {len(pages)} pages and fonts/ into {OUT}/, the only folder served")
else:
    target.write_text(expected, encoding="utf-8")
    print(f"OK: {len(pages)} pages, {len(scripts)} script(s) and {len(styles)} style block(s) pinned. Wrote site/vercel.json")
