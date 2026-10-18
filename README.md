# calmdoo

Called Booster until 2026-10-18. The Swift package, this folder and the module names still say
Booster; everything a user sees (app name, ID `com.calmdoo.app`, menu, permission prompt, website) says calmdoo.

A menu bar app for macOS 15+: one volume slider per app (Safari at 40%, Chrome at 100%),
boost up to 400%, and a "Boost everything" slider on top. Each app also gets its own 5-band EQ and a
compressor (quiet parts up, loud parts down). A limiter stops boosted sound from crackling.
No driver to install.

## Use it

Click the speaker icon in the menu bar. Apps show up once they play sound.

- Slider middle = 100%. Left = quieter, right (orange) = boost.
- Click the percentage to reset to 100%. Click the speaker to mute that app.
- The sliders button on a row opens that app's compressor (Off / Light / Strong) and EQ
  (Bass 100 Hz, Warmth 250, Mid 1k, Clarity 3.5k, Treble 10k; ±12 dB; presets).
- Settings are remembered per app.

## Build

```bash
./build.sh install                 # builds, copies to ~/Applications/calmdoo.app, starts it
./build.sh install --test-hooks    # test build: obeys tools/ctl.sh, logs every event. Never share it.
swift test                         # engine tests
```

The first start asks for **System Audio Recording** permission. The app is signed ad hoc with the
default requirement and hardened runtime under the ID `com.calmdoo.app`, so the permission is pinned to that exact build: macOS asks
again after every rebuild. A public release needs a Developer ID signature and notarization. Security
review and status: `SECURITY.md`.

## Website

`site/index.html` is the one-page download site: a single self-contained file (fonts from Google Fonts),
ready for any static host. The download buttons stay inactive until `DOWNLOAD_URL` near the top of
its script is set to the hosted release; until then they show "The download opens with the first
public release". Only set it for a Developer ID signed, notarized build. `site/privacy.html` is the privacy policy. Before any deploy, run `python3 site/build.py`: it checks the pages and writes `site/vercel.json` with the security headers (see SECURITY.md, "Website and accounts"). Local preview: the
`booster-site` entry in `~/Money/.claude/launch.json` serves it at http://localhost:8781.

## How it works

`Sources/BoosterCore/AppTap.swift`: for an app that is not at 100%, Booster creates a Core Audio
process tap (macOS 14.2+) that mutes the app's normal output, then plays the same sound through a
private aggregate device on the current output, through EQ -> compressor -> volume -> limiter
(`GainProcessor.swift`, `Equalizer.swift`, `Compressor.swift`). An app at 100%, with a flat EQ,
the compressor off and the master at 100%, is never touched.

On an output with inputs of its own (an audio interface like a Scarlett, a headset), the aggregate
device also carries that device's mic streams. Booster finds the tap's stream by counting the
device's input streams, reads only that, and switches the device's inputs off.

The panel is an `NSPopover` rather than SwiftUI's `MenuBarExtra`, because `MenuBarExtra` did not
grow when an app's EQ opened.

Helper processes are grouped under their app with the system's "responsible process" lookup:
Safari plays through `com.apple.WebKit.GPU`, Chrome through `com.google.Chrome.helper`.

If Booster quits or crashes, every app plays at its own normal volume again, because macOS removes a
private tap and device along with the process that made them (inferred from Apple's header comments,
not documented `[unverified]`). A turned-down app jumps back to full volume when that happens.

If Booster cannot positively find the app's sound among the device's inputs, and confirm the
device's own inputs are off, it refuses to start the tap and shows an error instead.

## Testing without clicking (test builds only)

These work only with `./build.sh install --test-hooks`; release builds do not listen.
`tools/ctl.sh dump`, `tools/ctl.sh debug=on`, `tools/ctl.sh com.apple.Safari=0.5`,
`tools/ctl.sh comp=com.apple.Safari:strong`, `tools/ctl.sh eq=com.apple.Safari:6,0,0,0,-3`,
`tools/ctl.sh open`, `tools/ctl.sh expand=com.apple.Safari`, `tools/ctl.sh snapshot` (logs the panel's
size and saves `~/Library/Logs/calmdoo-panel.png`; its text comes out invisible, the layout is right).
Output goes to `~/Library/Logs/calmdoo.log`.

## Known limits

- Sound always goes to the Mac's current default output. An app set to a different output device
  inside its own settings gets moved to the default while Booster changes its volume.
- When an app starts playing from silence, the first fraction of a second can be at its normal
  level before Booster takes over. Paused apps stay held for 30 seconds to avoid this on resume.
- Taking over an app adds a few milliseconds of delay.
- App volume times "Boost everything" is capped at 400% in total.
- When the output device changes, boosts above 100% go back to 100% (turned-down apps stay down),
  so a boost meant for quiet speakers never lands in headphones.
- Release builds log problems only, never which apps played.
- Only real apps are listed and adjusted (Dock apps, plus other companies' menu bar apps). macOS's own
  sounds, like the charging chime, alerts, Siri and Control Centre, are never touched. One side effect:
  FaceTime and phone-call audio is played by a macOS service, so it cannot be adjusted.
- One app for Apple silicon and Intel (`lipo -archs`: x86_64 arm64), macOS 15+. The Intel half is
  built but untested: the build Mac has no Rosetta.
