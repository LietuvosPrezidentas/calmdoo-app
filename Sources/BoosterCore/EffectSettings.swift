import Foundation

/// How hard the compressor evens out loud and quiet parts.
public enum Compression: UInt8, CaseIterable, Sendable {
    case off = 0, light, strong
}

/// Per-app sound shaping on top of volume: a 5-band EQ and a compressor.
public struct EffectSettings: Equatable, Sendable {
    public static let bandCount = 5
    public static let maxDB = 12.0
    public static let bandNames = ["Bass", "Warmth", "Mid", "Clarity", "Treble"]
    public static let bandLabels = ["100", "250", "1k", "3.5k", "10k"]

    public static let presets: [(name: String, eq: [Double])] = [
        ("Flat", [0, 0, 0, 0, 0]),
        ("Bass boost", [6, 3, 0, 0, 0]),
        ("Clear voice", [-4, -2, 1, 4, 1]),
        ("Bright", [0, 0, 0, 2, 5]),
    ]

    /// Gain per band in dB, -12...12, in half-dB steps.
    public var eq: [Double]
    public var compression: Compression

    public init(eq: [Double] = [0, 0, 0, 0, 0], compression: Compression = .off) {
        let bands = (eq + Array(repeating: 0, count: Self.bandCount)).prefix(Self.bandCount)
        self.eq = bands.map { (min(max($0, -Self.maxDB), Self.maxDB) * 2).rounded() / 2 }
        self.compression = compression
    }

    public static let neutral = EffectSettings()

    /// True when this changes nothing, so the app need not be tapped for it.
    public var isNeutral: Bool { compression == .off && eq.allSatisfy { $0 == 0 } }

    /// Everything in one 64-bit word, so the audio thread always reads a whole, consistent setting.
    /// Bytes 0-4: band gains in half-dB steps (signed). Byte 5: compression.
    public var packed: UInt64 {
        var word = UInt64(compression.rawValue) << 40
        for (i, db) in eq.enumerated() {
            word |= UInt64(UInt8(bitPattern: Int8((db * 2).rounded()))) << (8 * UInt64(i))
        }
        return word
    }

    public init(packed: UInt64) {
        self.init(eq: (0..<Self.bandCount).map { Double(Self.bandDB(packed, $0)) },
                  compression: Self.compression(packed))
    }

    static func bandDB(_ packed: UInt64, _ band: Int) -> Float {
        Float(Int8(bitPattern: UInt8(truncatingIfNeeded: packed >> (8 * UInt64(band))))) / 2
    }

    static func compression(_ packed: UInt64) -> Compression {
        Compression(rawValue: UInt8(truncatingIfNeeded: packed >> 40)) ?? .off
    }
}
