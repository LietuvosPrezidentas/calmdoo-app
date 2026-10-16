import CoreAudio
import Testing
@testable import BoosterCore

/// Builds buffer lists the way the audio thread hands them over, runs one render, returns the output.
func render(_ processor: GainProcessor, inputs: [[Float]], inputChannels: [Int],
                    outputChannels: [Int], frames: Int) -> [[Float]] {
    let inList = AudioBufferList.allocate(maximumBuffers: inputs.count)
    let outList = AudioBufferList.allocate(maximumBuffers: outputChannels.count)
    let inBuffers = inputs.map { samples -> UnsafeMutableBufferPointer<Float> in
        let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: samples.count)
        _ = b.initialize(from: samples)
        return b
    }
    // 9 = garbage that render must clear
    let outBuffers = outputChannels.map { UnsafeMutableBufferPointer<Float>.allocate(capacity: frames * $0) }
    for b in outBuffers { b.initialize(repeating: 9) }
    defer {
        (inBuffers + outBuffers).forEach { $0.deallocate() }
        free(inList.unsafeMutablePointer)
        free(outList.unsafeMutablePointer)
    }

    for (i, b) in inBuffers.enumerated() {
        inList[i] = AudioBuffer(mNumberChannels: UInt32(inputChannels[i]), mDataByteSize: UInt32(b.count * 4), mData: b.baseAddress)
    }
    for (i, b) in outBuffers.enumerated() {
        outList[i] = AudioBuffer(mNumberChannels: UInt32(outputChannels[i]), mDataByteSize: UInt32(b.count * 4), mData: b.baseAddress)
    }
    processor.render(input: inList.unsafePointer, output: outList.unsafeMutablePointer)
    return outBuffers.map { Array($0) }
}

@Test func halfVolumeHalvesTheSound() {
    let p = GainProcessor(sampleRate: 48_000, gain: 0.5)
    let out = render(p, inputs: [Array(repeating: 0.4, count: 512)], inputChannels: [2], outputChannels: [2], frames: 256)
    #expect(out[0].allSatisfy { abs($0 - 0.2) < 1e-6 })
}

@Test func boostNeverClips() {
    let p = GainProcessor(sampleRate: 48_000, gain: 4)
    let loud = (0..<1024).map { i in Float(sin(Double(i) * 0.1)) * 0.5 }
    let out = render(p, inputs: [loud], inputChannels: [2], outputChannels: [2], frames: 512)
    let peak = out[0].map(abs).max() ?? 0
    #expect(peak <= GainProcessor.ceiling + 1e-6)
    #expect(peak > 0.9) // still loud, just not clipped
}

@Test func quietBoostIsCleanGain() {
    let p = GainProcessor(sampleRate: 48_000, gain: 2)
    let out = render(p, inputs: [Array(repeating: 0.1, count: 512)], inputChannels: [2], outputChannels: [2], frames: 256)
    #expect(out[0].allSatisfy { abs($0 - 0.2) < 1e-6 })
}

@Test func volumeChangeRampsWithoutAJump() {
    let p = GainProcessor(sampleRate: 48_000, gain: 1)
    p.gain = 0
    let out = render(p, inputs: [Array(repeating: 0.5, count: 512)], inputChannels: [2], outputChannels: [2], frames: 256)
    let left = stride(from: 0, to: 512, by: 2).map { out[0][$0] }
    let biggestStep = zip(left, left.dropFirst()).map { abs($0 - $1) }.max() ?? 0
    #expect(biggestStep < 0.01)
    #expect(left.last! < 0.01)
    let next = render(p, inputs: [Array(repeating: 0.5, count: 512)], inputChannels: [2], outputChannels: [2], frames: 256)
    #expect(next[0].allSatisfy { $0 == 0 })
}

@Test func readsTheTapNotTheDeviceMicrophone() {
    // A headset: its mono mic comes first, the tapped app's stereo sound comes last.
    let p = GainProcessor(sampleRate: 48_000, gain: 1)
    let mic = [Float](repeating: 0.9, count: 256)
    let app = [Float](repeating: 0.1, count: 512)
    let out = render(p, inputs: [mic, app], inputChannels: [1, 2], outputChannels: [2], frames: 256)
    #expect(out[0].allSatisfy { abs($0 - 0.1) < 1e-6 })
}

@Test func monoOutputGetsBothSides() {
    let p = GainProcessor(sampleRate: 48_000, gain: 1)
    let stereo = (0..<512).map { $0 % 2 == 0 ? Float(0.2) : Float(0.4) }
    let out = render(p, inputs: [stereo], inputChannels: [2], outputChannels: [1], frames: 256)
    #expect(out[0].allSatisfy { abs($0 - 0.3) < 1e-6 })
}

@Test func extraOutputChannelsAreSilent() {
    let p = GainProcessor(sampleRate: 48_000, gain: 1)
    let out = render(p, inputs: [Array(repeating: 0.25, count: 256)], inputChannels: [2], outputChannels: [4], frames: 128)
    for frame in 0..<128 {
        #expect(out[0][frame * 4] == 0.25 && out[0][frame * 4 + 1] == 0.25)
        #expect(out[0][frame * 4 + 2] == 0 && out[0][frame * 4 + 3] == 0)
    }
}

@Test func brokenSamplesBecomeSilence() {
    let p = GainProcessor(sampleRate: 48_000, gain: 2)
    let bad: [Float] = [.nan, .infinity, -.infinity, 0.1] + Array(repeating: 0.1, count: 252)
    let out = render(p, inputs: [bad], inputChannels: [2], outputChannels: [2], frames: 128)
    #expect(out[0].allSatisfy { $0.isFinite })
}

@Test func peaksAreReported() {
    let p = GainProcessor(sampleRate: 48_000, gain: 0.5)
    _ = render(p, inputs: [Array(repeating: 0.8, count: 256)], inputChannels: [2], outputChannels: [2], frames: 128)
    let peaks = p.takePeaks()
    #expect(abs(peaks.input - 0.8) < 1e-6)
    #expect(abs(peaks.output - 0.4) < 1e-6)
    #expect(p.takePeaks().input == 0)
}

@Test func curveAndSlider() {
    #expect(GainCurve.gain(volume: 1) == 1)
    #expect(GainCurve.gain(volume: 0.5) == 0.25)
    #expect(GainCurve.gain(volume: 2) == 2)
    #expect(GainCurve.gain(volume: 9) == 4)
    #expect(GainCurve.snap(1.03) == 1)
    #expect(GainCurve.snap(1.2) == 1.2)
    #expect(SliderScale.volume(position: 0.5) == 1)
    #expect(SliderScale.volume(position: 1) == 4)
    #expect(SliderScale.volume(position: 0) == 0)
    for v in stride(from: 0.0, through: 4.0, by: 0.25) {
        #expect(abs(SliderScale.volume(position: SliderScale.position(volume: v)) - v) < 1e-9)
    }
}
