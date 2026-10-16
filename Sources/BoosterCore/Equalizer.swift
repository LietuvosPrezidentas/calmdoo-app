import Foundation

/// One EQ filter, stereo. Formulas from the RBJ "Audio EQ Cookbook"; transposed direct form II.
struct Biquad {
    enum Kind { case lowShelf, peak, highShelf }

    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var l1 = 0.0, l2 = 0.0, r1 = 0.0, r2 = 0.0
    var isOn = false

    mutating func design(_ kind: Kind, frequency: Double, q: Double, gainDB: Double, sampleRate: Double) {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let sqrtA2alpha = 2 * sqrt(a) * alpha
        var n0, n1, n2, d0, d1, d2: Double
        switch kind {
        case .peak:
            n0 = 1 + alpha * a; n1 = -2 * cosw; n2 = 1 - alpha * a
            d0 = 1 + alpha / a; d1 = -2 * cosw; d2 = 1 - alpha / a
        case .lowShelf:
            n0 = a * ((a + 1) - (a - 1) * cosw + sqrtA2alpha)
            n1 = 2 * a * ((a - 1) - (a + 1) * cosw)
            n2 = a * ((a + 1) - (a - 1) * cosw - sqrtA2alpha)
            d0 = (a + 1) + (a - 1) * cosw + sqrtA2alpha
            d1 = -2 * ((a - 1) + (a + 1) * cosw)
            d2 = (a + 1) + (a - 1) * cosw - sqrtA2alpha
        case .highShelf:
            n0 = a * ((a + 1) + (a - 1) * cosw + sqrtA2alpha)
            n1 = -2 * a * ((a - 1) + (a + 1) * cosw)
            n2 = a * ((a + 1) + (a - 1) * cosw - sqrtA2alpha)
            d0 = (a + 1) - (a - 1) * cosw + sqrtA2alpha
            d1 = 2 * ((a - 1) - (a + 1) * cosw)
            d2 = (a + 1) - (a - 1) * cosw - sqrtA2alpha
        }
        b0 = n0 / d0; b1 = n1 / d0; b2 = n2 / d0; a1 = d1 / d0; a2 = d2 / d0
    }

    mutating func reset() { l1 = 0; l2 = 0; r1 = 0; r2 = 0 }

    @inline(__always) mutating func process(_ l: inout Float, _ r: inout Float) {
        let xl = Double(l), xr = Double(r)
        let yl = b0 * xl + l1
        l1 = b1 * xl - a1 * yl + l2
        l2 = b2 * xl - a2 * yl
        let yr = b0 * xr + r1
        r1 = b1 * xr - a1 * yr + r2
        r2 = b2 * xr - a2 * yr
        l = Float(yl)
        r = Float(yr)
    }
}

/// Five bands: bass shelf, three bells, treble shelf. A band at 0 dB is skipped entirely.
/// Owned by the audio thread; `configure` runs there when the settings word changes.
final class Equalizer {
    private let filters: UnsafeMutablePointer<Biquad>
    private(set) var isActive = false

    init() {
        filters = .allocate(capacity: EffectSettings.bandCount)
        filters.initialize(repeating: Biquad(), count: EffectSettings.bandCount)
    }

    deinit {
        filters.deinitialize(count: EffectSettings.bandCount)
        filters.deallocate()
    }

    /// No arrays here: this runs on the audio thread.
    private static func band(_ i: Int) -> (Biquad.Kind, Double, Double) {
        switch i {
        case 0: (.lowShelf, 100, 0.707)
        case 1: (.peak, 250, 0.9)
        case 2: (.peak, 1000, 0.9)
        case 3: (.peak, 3500, 0.9)
        default: (.highShelf, 10_000, 0.707)
        }
    }

    func configure(packed: UInt64, sampleRate: Double) {
        var any = false
        for i in 0..<EffectSettings.bandCount {
            let db = Double(EffectSettings.bandDB(packed, i))
            let wasOn = filters[i].isOn
            filters[i].isOn = db != 0
            guard db != 0 else { continue }
            any = true
            if !wasOn { filters[i].reset() } // stale memory from an old setting would pop
            let (kind, frequency, q) = Self.band(i)
            filters[i].design(kind, frequency: frequency, q: q, gainDB: db, sampleRate: sampleRate)
        }
        isActive = any
    }

    @inline(__always) func process(_ l: inout Float, _ r: inout Float) {
        for i in 0..<EffectSettings.bandCount where filters[i].isOn {
            filters[i].process(&l, &r)
        }
    }
}
