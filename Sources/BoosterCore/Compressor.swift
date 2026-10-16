import Foundation

/// Evens out loud and quiet: anything above the threshold is turned down by the ratio,
/// then everything is turned up by the makeup gain. Quiet dialogue rises, explosions shrink.
/// Stereo-linked, so the left/right balance never wobbles.
struct Compressor {
    private(set) var mode: Compression = .off
    private var threshold: Float = 0
    private var slope: Float = 0      // 1/ratio - 1: dB removed per dB over the threshold
    private var knee: Float = 1
    private var makeup: Float = 0
    private var attack: Float = 0
    private var release: Float = 0
    private var reductionDB: Float = 0

    mutating func configure(_ newMode: Compression, sampleRate: Double) {
        if newMode != mode && mode == .off { reductionDB = 0 }
        mode = newMode
        let ratio: Float, attackMS: Double, releaseMS: Double
        switch newMode {
        case .off:
            return
        case .light:
            threshold = -20; ratio = 2.5; knee = 6; makeup = 4; attackMS = 10; releaseMS = 250
        case .strong:
            threshold = -30; ratio = 4; knee = 8; makeup = 9; attackMS = 5; releaseMS = 350
        }
        slope = 1 / ratio - 1
        attack = Float(exp(-1 / (attackMS * 0.001 * sampleRate)))
        release = Float(exp(-1 / (releaseMS * 0.001 * sampleRate)))
    }

    @inline(__always) mutating func process(_ l: inout Float, _ r: inout Float) {
        guard mode != .off else { return }
        let level = max(abs(l), abs(r), 1e-6)
        let over = 20 * log10f(level) - threshold
        let target: Float
        if 2 * over <= -knee {
            target = 0
        } else if 2 * over < knee {
            let x = over + knee / 2 // soft knee: ease into compression
            target = slope * x * x / (2 * knee)
        } else {
            target = slope * over
        }
        // Turning down follows the attack time, letting go follows the release time.
        let coefficient = target < reductionDB ? attack : release
        reductionDB = target + coefficient * (reductionDB - target)
        let gain = powf(10, (reductionDB + makeup) / 20)
        l *= gain
        r *= gain
    }
}
