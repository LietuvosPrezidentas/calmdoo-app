# calmdoo

**Every app on your Mac gets its own volume.** Turn Safari down, keep Spotify up, and boost a quiet
video to 400%, right from the menu bar.

Website: [calmdoo.com](https://calmdoo.com)

## What it does

macOS has one volume for everything. calmdoo adds a slider for each app that is playing sound.

- **Per-app volume.** Safari at 40%, Chrome at 100%, Spotify muted. Settings are remembered per app.
- **Boost to 400%.** Up to +12 dB for quiet videos and weak laptop speakers. A limiter stops the
  boosted sound from crackling.
- **"Boost everything".** One master slider on top of the per-app ones.
- **An EQ for each app.** Five bands (Bass 100 Hz, Warmth 250, Mid 1k, Clarity 3.5k, Treble 10k,
  ±12 dB each) with presets, so music gets more bass and calls get clearer voices.
- **A compressor for films.** Quiet dialogue comes up, explosions come down. Off, Light or Strong.
- **Safe on headphones.** When the output device changes, boosts above 100% go back to 100%, so a
  boost meant for quiet speakers never lands in your ears.

No driver to install, no account, and sound never leaves your Mac: calmdoo does not save or send it.

## Using it

Click the speaker icon in the menu bar. Apps show up once they play sound.

- The middle of a slider is 100%. Left is quieter, right (orange) is boost.
- Click the percentage to reset to 100%. Click the speaker to mute that app.
- The sliders button on a row opens that app's EQ and compressor.

On first launch, macOS asks once for **System Audio Recording** permission. That is what lets
calmdoo change other apps' sound.

## Getting it

There is no signed download yet: the first public release needs Apple's Developer ID signature and
notarization, and will be linked from [calmdoo.com](https://calmdoo.com). Until then you can build it
yourself. You need macOS 15 or later and Xcode (or its command line tools, Swift 6).

```bash
git clone https://github.com/LietuvosPrezidentas/calmdoo-app.git
cd calmdoo-app
./build.sh install      # builds, copies to ~/Applications/calmdoo.app, starts it
swift test              # engine tests
```

A home-built copy is signed ad hoc, so macOS asks for the permission again after every rebuild.

## How it works

For an app that is not at 100%, calmdoo creates a Core Audio process tap (a macOS 14.2+ feature)
that mutes the app's normal output, then plays the same sound through a private device on your
current output, passing it through EQ, compressor, volume and limiter. An app left at 100%, with a
flat EQ and the compressor off, is never touched.

- `Sources/BoosterCore/AppTap.swift`: the tap and the private device.
- `GainProcessor.swift`, `Equalizer.swift`, `Compressor.swift`: the sound processing.
- `AppFilter.swift`: only real apps are listed; macOS's own sounds are left alone.
- Helper processes are grouped under their app (Safari plays through `com.apple.WebKit.GPU`,
  Chrome through `com.google.Chrome.helper`).

On an output with inputs of its own (an audio interface or a headset), calmdoo reads only the
tapped app's sound and switches the device's microphone inputs off. If it cannot confirm both, it
refuses to start and shows an error instead.

If calmdoo quits or crashes, macOS removes its taps and every app plays at its normal volume again.
A turned-down app jumps back to full volume when that happens.

The project was called Booster before it was named calmdoo, so the Swift package and module names
still say Booster. The security review and its status are in [SECURITY.md](SECURITY.md).

## Known limits

- Sound always goes to the Mac's current default output. An app set to a different output inside
  its own settings is moved to the default while calmdoo changes its volume.
- When an app starts playing from silence, the first fraction of a second can be at its normal
  level before calmdoo takes over. Paused apps stay held for 30 seconds to avoid this on resume.
- Taking over an app adds a few milliseconds of delay.
- App volume times "Boost everything" is capped at 400% in total.
- FaceTime and phone-call audio is played by a macOS service, so it cannot be adjusted.
- One app for Apple silicon and Intel, macOS 15+. The Intel half is built but untested.

## For contributors

`site/` is the website at calmdoo.com: `index.html`, `privacy.html`, and `build.py`, which checks
the pages and writes `vercel.json` with the security headers. Run `python3 site/build.py` before any
change to the site.

Test builds can be driven from the command line, for checking changes without clicking:

```bash
./build.sh install --test-hooks   # never share this build: any app on the Mac can control it
tools/ctl.sh dump                 # also: com.apple.Safari=0.5, eq=com.apple.Safari:6,0,0,0,-3, open, snapshot
```

Output goes to `~/Library/Logs/calmdoo.log`. Release builds ignore these commands and log problems
only, never which apps played.
