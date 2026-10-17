import Foundation

/// Volume is stored as a number from 0 to 4 (0% to 400%).
public enum GainCurve {
    public static let maxVolume = 4.0
    /// App volume times "Boost everything" never goes past this (+12 dB), whatever the two sliders say.
    public static let maxTotalGain: Float = 4

    /// Volume -> amplitude multiplier.
    /// Below 100% the curve is squared, so the lower half of the slider still sounds even.
    /// Above 100% it is linear: 200% = +6 dB, 400% = +12 dB.
    public static func gain(volume: Double) -> Float {
        guard volume.isFinite else { return 1 } // NaN slips through min/max, so reject it first
        let v = min(max(volume, 0), maxVolume)
        return Float(v <= 1 ? v * v : v)
    }

    /// Values within 4% of 100% become exactly 100%, so "leave this app alone" is easy to hit.
    public static func snap(_ volume: Double) -> Double {
        guard volume.isFinite else { return 1 }
        return abs(volume - 1) < 0.04 ? 1 : min(max(volume, 0), maxVolume)
    }

    /// The gain an app actually gets: its own volume times the master, capped at `maxTotalGain`.
    public static func combined(app: Double, master: Double) -> Float {
        min(gain(volume: app) * gain(volume: master), maxTotalGain)
    }
}

/// Slider track position (0...1) <-> volume, with 100% in the middle of the track.
/// Left half: 0% to 100%. Right half: 100% to 400%.
public enum SliderScale {
    public static func volume(position: Double) -> Double {
        guard position.isFinite else { return 1 }
        let p = min(max(position, 0), 1)
        return p <= 0.5 ? p * 2 : 1 + (p - 0.5) * 6
    }

    public static func position(volume: Double) -> Double {
        guard volume.isFinite else { return 0.5 }
        let v = min(max(volume, 0), GainCurve.maxVolume)
        return v <= 1 ? v / 2 : 0.5 + (v - 1) / 6
    }
}
