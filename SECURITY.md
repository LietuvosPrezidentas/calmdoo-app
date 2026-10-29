# Booster security review, 2026-10-17

Hostile review before any public release: the author's own pass plus an independent critic that read
every file. Every finding below was checked against the code. "Verified" means the code, a run, or a
fetched Apple source shows it; `[unverified]` means reasoning only.

Booster holds the macOS **System Audio Recording** permission (it can capture any app's sound). That
is why the first two findings matter: they let other code borrow or steer that power.

## Status, 2026-10-18

| # | Finding | Status | Checked by |
|---|---|---|---|
| 1 | Permission can be borrowed | **Fixed on this Mac (2026-10-18).** The default ad-hoc requirement (pinned to the exact build) plus hardened runtime. The old loose permission entry was reset by the owner (`tccutil reset AudioCapture local.booster.Booster`), then the current build was allowed again. Public release still needs Developer ID and notarization | `codesign -dv`: `flags=0x10002(adhoc,runtime)`, `designated => cdhash H"..."`. An impostor (same identifier, different build) asked macOS: **granted** under the old entry, "not granted" right after the reset, and still "not granted" after the real Booster was allowed again. Not run: a real capture attempt by the impostor (it could pop a prompt naming Booster) |
| 2 | Any app can control Booster | **Fixed.** The channel exists only in `--test-hooks` builds | Release binary: 0 matches for `local.booster.command`. `dump` and `master=4` changed nothing and logged nothing |
| 3 | `nan` crashes it at every launch | **Fixed.** Non-numbers rejected in snap, gain, slider scale, EffectSettings, GainProcessor, the settings loader and the panel | Test `nonNumbersAreRejectedEverywhere`. Live on the test build: `master=nan`, `Safari=nan`, `eq=...nan,inf,...,-inf`, `Safari=inf`; Booster stayed up, all values safe |
| 4 | Mic fails open | **Fixed.** Fails closed: no tap unless the tap stream is found and every other input is read back as off. The stream-flag count is bounded by the buffer size | Live on the Scarlett: `tap = in[1], other inputs confirmed off`. The failure path has not been run (it needs a device that breaks the rule) |
| 5 | Hearing | **Fixed in code.** Total capped at 400%, and boosts reset to 100% when the output changes, with a note in the panel. Open: no first-use headphone warning | Test `totalBoostIsCapped`. Live: Safari and master at 110%, simulated output change, both back to 100% and the note shown. A real AirPods switch has not been tested |
| 6 | Crash puts apps back to full volume | **Documented** in the README. The deliberate trigger (3) is gone | |
| 7 | Log is a listening history | **Fixed.** Release logs problems only, one line each, newlines stripped, 400 characters max, rotated at 1 MB on write. Older logs from earlier builds stay until deleted | Release build start-up and commands wrote 0 lines |
| 8 | Settings flooding | **Fixed.** Settings are kept only for apps that have played, and the channel is gone | Live: `com.fake.flood=4` saved 0 keys |

## Findings, most severe first

### 1. HIGH: other code can borrow Booster's audio-recording permission
`build.sh:15-16`. The signature requirement is `identifier "local.booster.Booster"`, ad hoc, no team ID,
no hardened runtime (`codesign -dv` shows `flags=0x2(adhoc)`, `TeamIdentifier=not set`).
- Any program can sign itself with the same identifier and pass macOS's check. It then records
  calls and media with no prompt. Apple TN3127: "the signer can set the code signing identifier to
  whatever value they want".
- Without the hardened runtime, the dynamic loader still honours injected libraries
  (DYLD_INSERT_LIBRARIES), so code injected into Booster runs with its permission.
- The app sits in user-writable `~/Applications`.
- This applies to this Mac today, not only to a public release. The full attack was not run
  `[unverified]`, but the permission surviving rebuilds (seen 2026-10-17) is consistent with it.

**Fix:** For public release, sign with Developer ID, hardened runtime on (`--options runtime`), the
default requirement (tied to the team ID), and notarize. Until then, drop the custom `-r=` and accept
one permission prompt per rebuild.

### 2. HIGH: any app on the Mac can control Booster
`Mixer.swift:147-152, 309-335`, `BoosterApp.swift:46-51, 80-91`. The test channel
`local.booster.command` (a system-wide broadcast) has no authentication. Apple: DistributedNotificationCenter
"does not implement a secure communications protocol".
- A sender can set `master=4` and every app to 400%, max the EQ, unmute muted apps, and pop the
  panel. All of it is saved and comes back after restart.
- Sandboxed senders can probably do it too: only `userInfo` is blocked for them, and Booster reads
  `object` `[unverified]`.

**Fix:** Compile the channel out of release builds (`#if DEBUG`). If a control interface is ever
needed, use XPC with a code-signing check on the caller.

### 3. HIGH: one bad number crashes Booster at every launch and breaks the sound
`Mixer.swift:322/331/334` parse with `Double(...)`; `GainCurve.swift:17`, `Mixer.swift:87` and
`EffectSettings.swift:28` clamp with `min`/`max`; `EffectSettings.swift:42` does `Int8(...)`;
`MixerView.swift:294` does `Int(...)`; `Mixer.swift:51-57` reloads saved values unchecked.
- Verified in an isolated run: `Double("nan")` is NaN, `min(max(nan, 0), 4)` is still NaN, NaN
  survives a UserDefaults save and reload, and `Int8(nan)` crashes (exit 133).
- `master=nan` taps and mutes every playing app and outputs NaN samples, so you hear silence or noise
  `[unverified]` (the limiter never triggers on NaN). Opening the panel then crashes. `eq=<app>:nan`
  crashes the next time that app plays. With "Open at login" on, this repeats every session. The only way
  out is `defaults delete local.booster.Booster`.

**Fix:** Reject non-finite numbers everywhere a number comes in (snap, master clamp, EffectSettings,
the settings loader). Add a NaN test.

### 4. MEDIUM: the microphone protection fails open
`AppTap.swift:119-151`. When the output device has inputs (the Scarlett, a headset), the virtual device
carries its mic. If Booster cannot identify the tap stream, or switching the other inputs off fails, it
starts anyway with the mic on and reads "the last stream".
- If that guess is ever wrong, Booster mutes the app and plays the mic into your ears, at up to
  400%: feedback and a hearing hazard `[unverified]`.
- The test `readsTheTapNotTheDeviceMicrophone` builds its own buffer order, so it cannot catch this.

**Fix:** Fail closed. If the tap is not positively identified and the other inputs confirmed off,
tear down and show an error.

### 5. MEDIUM: hearing safety
- Total boost can reach 16x (+24 dB): 400% app × 400% master (`Mixer.swift:128-131`). The limiter
  keeps it under clipping, so it does not exceed full scale, but everything sits at full scale.
- Boosts are per app, not per output (`Mixer.swift:224-258`). A 400% boost set for quiet laptop
  speakers carries straight into AirPods when they connect.

**Fix:** Cap the combined gain (for example 400% total). Reset boosts above 100% when the output
device changes, or store them per device. For a public release, warn the first time someone boosts
on headphones.

### 6. LOW: quitting or crashing puts every app back to full volume at once
Inherent to the design. Also, "macOS removes the taps when Booster dies" is inferred from Apple's
header comments, not documented `[unverified]`, and a hung but alive Booster may leave apps muted
`[unverified]`.

**Fix:** Fixing 3 removes the crash someone can trigger on purpose. Say this in the docs.

### 7. LOW: the log is a listening history
`Log.swift`, `Mixer.swift:259, 275, 310`. It records which app played and when, the output device's
UID (which includes the Scarlett's serial number), and every command verbatim, newlines included, so
fake lines can be written into it. The 1 MB cap is checked only at launch.

**Fix:** In release, log errors only. Rotate at write time. Strip newlines from anything logged.

### 8. LOW: the settings can be flooded
Any sender over finding 2's channel can create unlimited `volume.<anything>` keys, all scanned at launch.

**Fix:** Same as 2. Save settings only for apps that have actually played.

## Launch blockers that are not security
- Private APIs (`TCCAccessPreflight`/`TCCAccessRequest`, `responsibility_get_pid_responsible_for_pid`)
  rule out the Mac App Store and can break in any macOS update. If they disappear, Booster fails safe:
  no permission means no taps, and no responsibility lookup means helpers are listed on their own.
- Without Developer ID signing and notarization, Gatekeeper blocks the app for anyone who downloads it.
- ~~The bundle ID `local.booster.Booster` should become reverse-DNS on a domain you own.~~ Done 2026-10-18: the app is calmdoo, ID `com.calmdoo.app` (calmdoo.com is owned). The new ID got its own permission entry, pinned to the build. The old `local.booster.Booster` entry is pinned to an old build that is now in the Trash, so nothing can use it; `tccutil reset AudioCapture local.booster.Booster` clears it.
- `tools/ctl.sh` pastes its argument into JavaScript unescaped. That's fine as a hand-run dev tool, but
  it must never ship.

## Checked and cleared
- No network code, and no audio is written to disk. A search of `Sources/` finds no URLSession, socket
  or audio-file writer. Samples only go from the input buffer to the output buffer in memory. Booster
  writes the log and the panel snapshot PNG, nothing else. (Finding 1 still means *installing* Booster
  can let other code record.)
- The audio thread takes no locks and allocates no memory. Settings cross threads through atomics.
  Buffer access stays in bounds for any layout the system reports. Broken input samples are zeroed.
- Booster never taps itself. Teardown order is right, and the error paths clean up.
- The permission prompt text is accurate.

## Website and accounts, 2026-10-18

Audit of calmdoo.com, its DNS and its accounts before the download goes public.

| Item | Found | Status |
|---|---|---|
| HTTPS | Forced (308 redirect), HSTS `max-age=63072000` | OK. `site/vercel.json` adds `includeSubDomains` |
| Security headers on calmdoo.com | No CSP, X-Frame-Options, nosniff, Referrer-Policy or Permissions-Policy (placeholder page) | Ready in `site/vercel.json`, written by `site/build.py`; live after deploy |
| Third parties on the site | Google Fonts: every visitor's IP goes to Google. LG München I, 20 Jan 2022 (3 O 17493/20) awarded €100 for exactly this | Fix ready once the two font files are self-hosted (Hanken Grotesk 34,664 B, Mona Sans 98,064 B, latin subsets) |
| Script/style injection | Strict CSP: only the page's own files and its exact inline `<style>`/`<script>` (by hash) run | Tested with the policy on: page works, only Google Fonts blocked |
| Registrar | `client transfer prohibited` (RDAP, 2026-10-18) | OK |
| DNSSEC | Not signed (`delegationSigned: false`) | Open, low priority |
| Certificate authorities | CAA allows letsencrypt.org, pki.goog, sectigo.com | OK |
| Email spoofing | No MX, SPF or DMARC: anyone can send mail "from" @calmdoo.com | Open: add `TXT @ "v=spf1 -all"` and `TXT _dmarc "v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s"` (needs the owner's go-ahead) |
| `~/calmdoo/.env.local` | Short-lived Vercel OIDC token; gitignored (`.env*`), never committed; was world-readable | Now `chmod 600` |
| GitHub `LietuvosPrezidentas/calmdoo` | Private | OK |
| Download integrity | No release yet | `tools/release-check.sh` refuses any zip that is not Developer ID signed, hardened, notarized and stapled; `tools/deploy-site.sh` will not add the link without it. The on-page checksum was dropped (same page as the link, so it protected no one) |

Account steps only the owner can take: two-factor sign-in (authenticator app or passkey, not SMS) on the Gmail account that receives password resets, Apple ID, GitHub, Vercel and Spaceship; keep the backup codes offline.

Deploy rule: only through `tools/deploy-site.sh`. It runs `site/build.py` (blanks, Google Fonts, any outside address not on the allowed list, inline styles or handlers, outside scripts or frames, the secret scan), copies the site into `~/calmdoo`, and re-checks there. Vercel runs `python3 build.py --verify --out public` on every deploy and fails if the pages and `vercel.json` disagree; only `public/` (pages, fonts, a verified zip) is served. Proven on the first deploy, 2026-10-18: the first three attempts were refused by this check, because Vercel adds `name` and `version` to `vercel.json` on its build machine; once those two were allowed, the deploy went live. Then `tools/site-monitor.sh`.

## Site review, 2026-10-18

Independent hostile review of `site/`. No injection path found. Five gaps, all fixed the same day:
1. Checksum on the same page as the link protected no one: replaced by `tools/release-check.sh` (signature + notarization).
2. `build.py` ran only if remembered: now `tools/deploy-site.sh` plus Vercel's `buildCommand`; the download link is written into the HTML, so the pinned script never changes.
3. "Boosts reset when you plug in headphones" was untested on real devices: reworded to "when you switch output device", which is what the code does. Still to test: real AirPods and the wired jack.
4. The check only caught Google: now any outside address not on `ALLOWED_OUTSIDE` fails.
5. "Nothing is saved or sent" contradicted the saved settings: now "Sound is never saved or sent".

Guards tested to say no: planted outside links, tracking image, `onclick`, inline style and iframe all caught; an ad-hoc zip and a non-calmdoo.com download address refused; deploy stops before touching `~/calmdoo`; `--verify` catches a one-character script edit.

## The vibe-coding security checklist, applied (2026-10-18)

| Advice | Applies to calmdoo? | Status |
|---|---|---|
| Secrets in `.env`, never in code or the frontend | Yes | No secrets in the app or site. `tools/secret-scan.sh`: both repos clean, every file and commit; `build.sh` and `site/build.py` stop on a hit. `~/calmdoo/.env.local` gitignored, never committed, `chmod 600` |
| Don't collect what you don't need | Yes | Nothing collected: no accounts, analytics or network code. `site/privacy.html` says exactly what is stored, on the Mac only |
| Security review before shipping | Yes | App: hostile review + fixes (findings 1-8). Site: review above |
| Sanitize user input | Partly | No forms, server or database. The one input channel is test-builds only; non-numbers rejected everywhere |
| Block bots (reCAPTCHA) | No | Nothing to sign up for. reCAPTCHA would send every visitor to Google, breaking the privacy promise. If downloads get hammered: Vercel's firewall |
| HTTPS | Yes | Forced + HSTS; watched by `tools/site-monitor.sh` |
| Sentry / Datadog monitoring | Swapped | An error tracker would make the app phone home. `tools/site-monitor.sh` watches for a swapped page, dropped headers, certificate expiry, a lost domain lock and changed DNS |
| Row-level security | No | No database |
| Keep dependencies updated (npm audit) | No | Zero third-party packages in the app and the site. Keep Xcode and macOS updated |
| Backups | Yes | MISSING: no Time Machine disk, no remote copy of this repo. Needs the owner |
| Don't build auth or payments yourself | Later | None today. If calmdoo is sold: Paddle or Lemon Squeezy (they handle EU VAT) or Stripe |

## Live, 2026-10-18

calmdoo.com serves the new site (deployment `calmdoo-8pciqdqip`). `tools/site-monitor.sh`: all 14 checks pass (HTTPS, redirect, HSTS, CSP, nosniff, frame, referrer and permissions headers, live page = deployed copy, certificate 85 days, transfer lock, nameservers, CAA, SPF + DMARC). Probes: `/.env.local`, `/.env`, `/build.py`, `/vercel.json`, `/.vercelignore`, `/.git/config`, `/.vercel/project.json` all 404. In a browser: the page contacts only calmdoo.com, sets no cookies, and logs no blocked code.

## Follow-ups, 2026-10-18

- **System sounds no longer touched.** The app listed and, with "Boost everything" above 100%, tapped macOS's own helpers (PowerChime showed up as "Charging sound"). Now only real apps are listed or tapped (`AppFilter`, tested). On this Mac: Safari, Chrome, Spotify, Telegram, WhatsApp and Wispr Flow listed; PowerChime, Control Centre, Siri, call services and 16 daemons hidden.
- **Intel build.** One app, x86_64 + arm64, both `minos 15.0`; build.sh refuses a single-chip result. Intel half untested (no Rosetta here). Note: macOS 27 drops Intel, so Intel users are on macOS 15-26.
- **Deploy folder recorded.** `~/calmdoo` commit 958cd74 holds the files serving calmdoo.com (local only, not pushed).
- **Vercel CLI** 54.18.6 -> 64.5.0. npm 11 held back esbuild's install script (its supply-chain default); left held back.
- **DNSSEC: not available.** Vercel staff, Jan and Apr 2026: not supported on Vercel nameservers, no timeline (community.vercel.com/t/17968). Would need moving DNS elsewhere; not worth it now.
- **HSTS preload: not requested.** Hard to undo (months) and adds little over the existing HSTS.
