import CoreAudio
import Foundation
import Synchronization

/// The sound chain for one tapped app: EQ -> compressor -> volume -> peak limiter.
/// `render` runs on the real-time audio thread: no locks, no allocation, no logging.
public final class GainProcessor: @unchecked Sendable {
    /// Output never goes above this, so boosting cannot clip.
    public static let ceiling: Float = 0.98

    private let targetBits: Atomic<UInt32>
    private let settingsBits: Atomic<UInt64>
    private let peakInBits = Atomic<UInt32>(0)
    private let peakOutBits = Atomic<UInt32>(0)

    /// Which input buffer carries the tapped app's sound. Set once before audio starts; -1 = the last one.
    public var tapBufferIndex = -1

    // Touched only by the audio thread.
    private var current: Float
    private var envelope: Float = 0
    private let release: Float
    private let sampleRate: Double
    private var appliedSettings: UInt64
    private let equalizer = Equalizer()
    private var compressor = Compressor()

    public init(sampleRate: Double, gain: Float, settings: EffectSettings = .neutral) {
        let gain = Self.safe(gain)
        targetBits = Atomic(gain.bitPattern)
        settingsBits = Atomic(settings.packed)
        appliedSettings = settings.packed
        self.sampleRate = sampleRate
        current = gain
        equalizer.configure(packed: settings.packed, sampleRate: sampleRate)
        compressor.configure(settings.compression, sampleRate: sampleRate)
        // The limiter lets go over about 150 ms after a loud peak.
        release = Float(exp(-1.0 / (0.15 * max(sampleRate, 8000))))
    }

    /// The gain the audio thread moves towards. Changes are ramped over one buffer, so no clicks.
    public var gain: Float {
        get { Float(bitPattern: targetBits.load(ordering: .relaxed)) }
        set { targetBits.store(Self.safe(newValue).bitPattern, ordering: .relaxed) }
    }

    /// A gain that is not a real number becomes 1 (no change); anything else is held to 0...16.
    private static func safe(_ g: Float) -> Float { g.isFinite ? min(max(g, 0), 16) : 1 }

    /// EQ and compressor. Picked up by the audio thread at the start of the next buffer.
    public var settings: EffectSettings {
        get { EffectSettings(packed: settingsBits.load(ordering: .relaxed)) }
        set { settingsBits.store(newValue.packed, ordering: .relaxed) }
    }

    /// Loudest input and output sample since the last call. Used by the debug log.
    public func takePeaks() -> (input: Float, output: Float) {
        (Float(bitPattern: peakInBits.exchange(0, ordering: .relaxed)),
         Float(bitPattern: peakOutBits.exchange(0, ordering: .relaxed)))
    }

    /// Reads the tapped app's stereo sound from `input` and writes it, louder or quieter, to `output`.
    /// The tap's stream is the last input stream: an aggregate device lists its sub-device inputs first.
    public func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let src = Self.tapStream(ins, index: tapBufferIndex), let dst = Self.outputPair(outs) else { return }
        let frames = min(src.frames, dst.frames)
        guard frames > 0 else { return }
        process(frames: frames, src: src, dst: dst)
    }

    private func process(frames: Int, src: Source, dst: Destination) {
        let packed = settingsBits.load(ordering: .relaxed)
        if packed != appliedSettings {
            appliedSettings = packed
            equalizer.configure(packed: packed, sampleRate: sampleRate)
            compressor.configure(EffectSettings.compression(packed), sampleRate: sampleRate)
        }
        let eqOn = equalizer.isActive
        var comp = compressor // local copy: no per-sample access checks on the class property
        let target = gain
        let step = (target - current) / Float(frames)
        var g = current
        var env = envelope
        var peakIn: Float = 0
        var peakOut: Float = 0

        for i in 0..<frames {
            g += step
            var inL = src.left[i * src.leftStride]
            var inR = src.right[i * src.rightStride]
            if !inL.isFinite { inL = 0 }
            if !inR.isFinite { inR = 0 }
            peakIn = max(peakIn, abs(inL), abs(inR))

            var l = inL
            var r = inR
            if eqOn { equalizer.process(&l, &r) }
            comp.process(&l, &r)
            l *= g
            r *= g
            // Instant attack: the envelope is never below the current peak, so output never passes the ceiling.
            env = max(max(abs(l), abs(r)), env * release)
            if env > Self.ceiling {
                let k = Self.ceiling / env
                l *= k
                r *= k
            }
            if let right = dst.right {
                dst.left[i * dst.leftStride] = l
                right[i * dst.rightStride] = r
            } else {
                dst.left[i * dst.leftStride] = (l + r) * 0.5
            }
            peakOut = max(peakOut, abs(l), abs(r))
        }

        compressor = comp
        current = target
        envelope = (env.isFinite && env > 1e-9) ? env : 0
        if peakIn > Float(bitPattern: peakInBits.load(ordering: .relaxed)) {
            peakInBits.store(peakIn.bitPattern, ordering: .relaxed)
        }
        if peakOut > Float(bitPattern: peakOutBits.load(ordering: .relaxed)) {
            peakOutBits.store(peakOut.bitPattern, ordering: .relaxed)
        }
    }

    struct Source {
        var left: UnsafePointer<Float>, leftStride: Int
        var right: UnsafePointer<Float>, rightStride: Int
        var frames: Int
    }

    struct Destination {
        var left: UnsafeMutablePointer<Float>, leftStride: Int
        var right: UnsafeMutablePointer<Float>?, rightStride: Int
        var frames: Int
    }

    /// The tap's buffer (by index, or the last one), its last two channels. A mono buffer feeds both sides.
    static func tapStream(_ list: UnsafeMutableAudioBufferListPointer, index: Int = -1) -> Source? {
        guard list.count > 0 else { return nil }
        let last = list[index >= 0 && index < list.count ? index : list.count - 1]
        guard let data = last.mData, last.mNumberChannels > 0 else { return nil }
        let n = Int(last.mNumberChannels)
        let p = UnsafePointer(data.assumingMemoryBound(to: Float.self))
        let frames = Int(last.mDataByteSize) / (MemoryLayout<Float>.size * n)
        if n >= 2 {
            return Source(left: p + (n - 2), leftStride: n, right: p + (n - 1), rightStride: n, frames: frames)
        }
        return Source(left: p, leftStride: 1, right: p, rightStride: 1, frames: frames)
    }

    /// The first two output channels: one interleaved buffer, or two mono buffers. Mono devices get one.
    static func outputPair(_ list: UnsafeMutableAudioBufferListPointer) -> Destination? {
        guard let first = list.first, let data = first.mData, first.mNumberChannels > 0 else { return nil }
        let n = Int(first.mNumberChannels)
        let p = data.assumingMemoryBound(to: Float.self)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * n)
        if n >= 2 {
            return Destination(left: p, leftStride: n, right: p + 1, rightStride: n, frames: frames)
        }
        if list.count >= 2, let data2 = list[1].mData, list[1].mNumberChannels > 0 {
            let n2 = Int(list[1].mNumberChannels)
            let frames2 = Int(list[1].mDataByteSize) / (MemoryLayout<Float>.size * n2)
            return Destination(left: p, leftStride: 1,
                               right: data2.assumingMemoryBound(to: Float.self), rightStride: n2,
                               frames: min(frames, frames2))
        }
        return Destination(left: p, leftStride: 1, right: nil, rightStride: 0, frames: frames)
    }
}
