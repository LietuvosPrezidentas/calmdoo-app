#!/bin/bash
# Looks for API keys, tokens and private keys in a repo: every tracked file, every untracked file that
# is not ignored, and every past commit (a key deleted later is still in history).
# Prints only where a hit is and its first characters, never the secret itself.
#   tools/secret-scan.sh                 scan this repo
#   tools/secret-scan.sh ~/calmdoo ...   scan other repos
# Exit 1 if anything is found, so build.sh and site/build.py stop.
set -uo pipefail

PATTERN='AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|gh[ours]_[A-Za-z0-9]{36}|sk-[A-Za-z0-9_-]{20,}|sk_live_[A-Za-z0-9]{16,}|rk_live_[A-Za-z0-9]{16,}|xox[abpr]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{15,}\.|(TOKEN|SECRET|PASSWORD|API_KEY)[A-Z_]*=[^[:space:]$]{8,}'
SELF=':(exclude)tools/secret-scan.sh'

mask() { awk -F: '{ hit=$NF; printf "  %s  %s...\n", substr($0, 1, length($0) - length(hit) - 1), substr(hit, 1, 6) }'; }

found=0
repos=("$@")
[ ${#repos[@]} -eq 0 ] && repos=("$(cd "$(dirname "$0")/.." && pwd)")

for repo in "${repos[@]}"; do
  echo "scanning $repo"
  hits=$(
    { git -C "$repo" grep -nIoE "$PATTERN" -- . "$SELF" 2>/dev/null
      git -C "$repo" ls-files -z --others --exclude-standard | (cd "$repo" && xargs -0 grep -HnIoE "$PATTERN" 2>/dev/null)
      for rev in $(git -C "$repo" rev-list --all 2>/dev/null); do
        git -C "$repo" grep -nIoE "$PATTERN" "$rev" -- . "$SELF" 2>/dev/null
      done
    } | sort -u
  )
  if [ -n "$hits" ]; then
    found=1
    echo "$hits" | mask
  else
    echo "  nothing found (files, untracked files and $(git -C "$repo" rev-list --all 2>/dev/null | wc -l | tr -d ' ') commits)"
  fi
done

[ $found -eq 0 ] || { echo "SECRETS FOUND: remove them and rotate (replace) every key listed."; exit 1; }
