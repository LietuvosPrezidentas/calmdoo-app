import Foundation
import Testing
@testable import BoosterCore

/// Plays one second of a sine through the processor, 512 frames at a time, as the audio thread would.
/// Returns output peak divided by input peak, both measured on the samples of the last quarter (after settling).
/// Using the sampled input peak, not the nominal amplitude, matters: at 8 kHz / 48 kHz the samples never hit the top.
private func response(_ processor: GainProcessor, frequency: Double, amplitude: Float = 0.05,
                      sampleRate: Double = 48_000) -> Float {
    let total = Int(sampleRate)
    let chunk = 512
    var peak: Float = 0
    var inputPeak: Float = 0
    var frame = 0
    while frame < total {
        let n = min(chunk, total - frame)
        var input = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let v = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame + i) / sampleRate))
            input[2 * i] = v
            input[2 * i + 1] = v
        }
        let out = render(processor, inputs: [input], inputChannels: [2], outputChannels: [2], frames: n)
        if frame >= total * 3 / 4 {
            peak = max(peak, out[0].map(abs).max() ?? 0)
            inputPeak = max(inputPeak, input.map(abs).max() ?? 0)
        }
        frame += n
    }
    return peak / inputPeak
}

private func processor(eq: [Double] = [0, 0, 0, 0, 0], compression: Compression = .off) -> GainProcessor {
    GainProcessor(sampleRate: 48_000, gain: 1, settings: EffectSettings(eq: eq, compression: compression))
}

private func dB(_ ratio: Float) -> Float { 20 * log10f(ratio) }

@Test func flatSettingsChangeNothing() {
    let p = processor()
    let input = (0..<512).map { Float(sin(Double($0) * 0.05)) * 0.3 }
    let out = render(p, inputs: [input], inputChannels: [2], outputChannels: [2], frames: 256)
    #expect(out[0] == input) // bit for bit
}

@Test func bassBoostLiftsBassOnly() {
    #expect(abs(dB(response(processor(eq: [12, 0, 0, 0, 0]), frequency: 40)) - 12) < 1.5)
    #expect(abs(dB(response(processor(eq: [12, 0, 0, 0, 0]), frequency: 8000))) < 0.5)
}

@Test func midBellHitsItsFrequency() {
    #expect(abs(dB(response(processor(eq: [0, 0, 6, 0, 0]), frequency: 1000)) - 6) < 0.3)
    #expect(abs(dB(response(processor(eq: [0, 0, 6, 0, 0]), frequency: 60))) < 0.5)
}

@Test func trebleCutLowersTrebleOnly() {
    #expect(abs(dB(response(processor(eq: [0, 0, 0, 0, -12]), frequency: 18000)) + 12) < 1.5)
    #expect(abs(dB(response(processor(eq: [0, 0, 0, 0, -12]), frequency: 200))) < 0.5)
}

@Test func compressorNarrowsLoudVersusQuiet() {
    // Input gap between an explosion-loud tone (-6 dB) and a quiet one (-40 dB): 34 dB.
    let inputGap: Float = 34
    func gap(_ mode: Compression) -> Float {
        let loud = response(processor(compression: mode), frequency: 997, amplitude: 0.5) * 0.5
        let quiet = response(processor(compression: mode), frequency: 997, amplitude: 0.01) * 0.01
        return dB(loud / quiet)
    }
    let light = gap(.light), strong = gap(.strong)
    #expect(light < inputGap - 6)
    #expect(strong < light - 4)
    #expect(strong > 8) // still louder, just closer together
}

@Test func compressorLiftsQuietSound() {
    // Quiet dialogue gets the makeup gain: about +9 dB on Strong.
    #expect(abs(dB(response(processor(compression: .strong), frequency: 1000, amplitude: 0.005)) - 9) < 1)
}

@Test func settingsChangeWhilePlaying() {
    let p = processor()
    p.settings = EffectSettings(eq: [0, 0, 6, 0, 0])
    #expect(abs(dB(response(p, frequency: 1000)) - 6) < 0.3)
    p.settings = .neutral
    #expect(abs(dB(response(p, frequency: 1000))) < 0.01)
}

@Test func everythingMaxedStaysFiniteAndUnclipped() {
    let p = GainProcessor(sampleRate: 44_100, gain: 4,
                          settings: EffectSettings(eq: [12, 12, 12, 12, 12], compression: .strong))
    let r = response(p, frequency: 100, amplitude: 0.9, sampleRate: 44_100)
    #expect(r.isFinite)
    #expect(r * 0.9 <= GainProcessor.ceiling + 1e-5)
}

@Test func settingsPackRoundTrip() {
    let s = EffectSettings(eq: [12, -12, 0.5, -3.5, 6], compression: .strong)
    #expect(EffectSettings(packed: s.packed) == s)
    #expect(EffectSettings(eq: [20, -30, 0, 0, 0]).eq == [12, -12, 0, 0, 0])
    #expect(EffectSettings.neutral.isNeutral)
    #expect(!EffectSettings(compression: .light).isNeutral)
    #expect(!EffectSettings(eq: [0, 0, 0, 0.5, 0]).isNeutral)
}

// Security review finding 3: a non-number ("nan") used to slip past every clamp, get saved,
// and crash Booster at every launch.
@Test func nonNumbersAreRejectedEverywhere() {
    for bad in [Double.nan, .infinity, -.infinity] {
        #expect(GainCurve.snap(bad) == 1)
        #expect(GainCurve.gain(volume: bad) == 1)
        #expect(SliderScale.volume(position: bad) == 1)
        #expect(SliderScale.position(volume: bad) == 0.5)
        let s = EffectSettings(eq: [bad, bad, 3, bad, bad])
        #expect(s.eq == [0, 0, 3, 0, 0])
        _ = s.packed // used to crash on Int8(nan)
    }
    let p = GainProcessor(sampleRate: 48_000, gain: .nan)
    #expect(p.gain == 1)
    p.gain = .infinity
    #expect(p.gain == 1)
}

// Finding 5: 400% on the app times 400% on the master used to be 16x.
@Test func totalBoostIsCapped() {
    #expect(GainCurve.combined(app: 4, master: 4) == GainCurve.maxTotalGain)
    #expect(GainCurve.combined(app: 2, master: 1.5) == 3)
    #expect(GainCurve.combined(app: 0.5, master: 1) == 0.25)
}

// The charging chime and other parts of macOS used to show up as "apps" and get boosted.
@Test func onlyRealAppsAreListed() {
    #expect(AppFilter.isUserFacing(.regular, bundleID: "com.apple.Safari"))
    #expect(AppFilter.isUserFacing(.regular, bundleID: "com.spotify.client"))
    #expect(AppFilter.isUserFacing(.accessory, bundleID: "com.example.menubarplayer"))
    #expect(!AppFilter.isUserFacing(.accessory, bundleID: "com.apple.controlcenter"))
    #expect(!AppFilter.isUserFacing(.prohibited, bundleID: "com.apple.PowerChime"))
    #expect(!AppFilter.isUserFacing(.notAnApp, bundleID: "systemsoundserverd"))
    #expect(!AppFilter.isUserFacing(.notAnApp, bundleID: nil))
}
