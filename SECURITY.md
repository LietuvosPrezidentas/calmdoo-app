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
