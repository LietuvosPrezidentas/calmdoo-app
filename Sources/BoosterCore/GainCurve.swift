import Foundation

/// Volume is stored as a number from 0 to 4 (0% to 400%).
public enum GainCurve {
    public static let maxVolume = 4.0

    /// Volume -> amplitude multiplier.
    /// Below 100% the curve is squared, so the lower half of the slider still sounds even.
    /// Above 100% it is linear: 200% = +6 dB, 400% = +12 dB.
    public static func gain(volume: Double) -> Float {
        let v = min(max(volume, 0), maxVolume)
        return Float(v <= 1 ? v * v : v)
    }

    /// Values within 4% of 100% become exactly 100%, so "leave this app alone" is easy to hit.
    public static func snap(_ volume: Double) -> Double {
        abs(volume - 1) < 0.04 ? 1 : min(max(volume, 0), maxVolume)
    }
}

/// Slider track position (0...1) <-> volume, with 100% in the middle of the track.
/// Left half: 0% to 100%. Right half: 100% to 400%.
public enum SliderScale {
    public static func volume(position: Double) -> Double {
        let p = min(max(position, 0), 1)
        return p <= 0.5 ? p * 2 : 1 + (p - 0.5) * 6
    }

    public static func position(volume: Double) -> Double {
        let v = min(max(volume, 0), GainCurve.maxVolume)
        return v <= 1 ? v / 2 : 0.5 + (v - 1) / 6
    }
}
