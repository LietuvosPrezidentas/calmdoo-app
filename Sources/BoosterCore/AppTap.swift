import CoreAudio
import Foundation

public enum TapError: Error, CustomStringConvertible {
    case createTap(OSStatus), createAggregate(OSStatus), ioProc(OSStatus), start(OSStatus), inputs(String)

    public var description: String {
        switch self {
        case .createTap(let s): "could not tap the app (\(s))"
        case .createAggregate(let s): "could not open the output device (\(s))"
        case .ioProc(let s): "could not attach to the audio thread (\(s))"
        case .start(let s): "could not start audio (\(s))"
        case .inputs(let why): "could not keep the output device's mic out of it (\(why))"
        }
    }
}

/// Takes over one app's sound: mutes its normal output, and plays it again,
/// louder or quieter, through a private aggregate device on the chosen output.
///
/// If Booster quits or crashes, macOS removes the tap and the app plays normally again.
public final class AppTap {
    public let processObjects: Set<AudioObjectID>
    public let outputUID: String
    public let processor: GainProcessor
    /// How the input side was wired, for the log.
    public private(set) var diagnostics = ""

    private var tapID: AudioObjectID
    private var aggregateID: AudioObjectID
    private var ioProc: AudioDeviceIOProcID?

    private init(processObjects: Set<AudioObjectID>, outputUID: String, processor: GainProcessor,
                 tapID: AudioObjectID, aggregateID: AudioObjectID, ioProc: AudioDeviceIOProcID?) {
        self.processObjects = processObjects
        self.outputUID = outputUID
        self.processor = processor
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.ioProc = ioProc
    }

    public static func make(processObjects: Set<AudioObjectID>, outputUID: String, gain: Float,
                            settings: EffectSettings) throws -> AppTap {
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processObjects))
        description.uuid = UUID()
        description.name = "Booster"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tapID = CA.unknown
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.createTap(status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Booster",
            kAudioAggregateDeviceUIDKey: "booster-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateID = CA.unknown
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.createAggregate(status)
        }

        let rate = CA.value(aggregateID, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48_000
        let processor = GainProcessor(sampleRate: rate, gain: gain, settings: settings)

        var ioProc: AudioDeviceIOProcID?
        // No dispatch queue: the block runs straight on the device's real-time thread.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { _, input, _, output, _ in
            processor.render(input: input, output: output)
        }
        guard status == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.ioProc(status)
        }

        let tap = AppTap(processObjects: processObjects, outputUID: outputUID, processor: processor,
                         tapID: tapID, aggregateID: aggregateID, ioProc: ioProc)
        do {
            tap.diagnostics = try wireInputs(aggregateID: aggregateID, tapID: tapID, outputUID: outputUID,
                                             ioProc: ioProc, processor: processor)
        } catch {
            tap.invalidate() // fail closed: never start with the device's mic on or the source unknown
            throw error
        }
        status = AudioDeviceStart(aggregateID, ioProc)
        guard status == noErr else {
            tap.invalidate()
            throw TapError.start(status)
        }
        return tap
    }

    /// An output device with inputs (an audio interface, a headset) brings its mic channels into the
    /// aggregate device too. Find the stream that really is the tap, point the processor at it, and
    /// switch every other input stream off so the device's mics are never read.
    /// Throws, so the tap is never started, unless the tap is positively found and every other input
    /// is confirmed off.
    private static func wireInputs(aggregateID: AudioObjectID, tapID: AudioObjectID, outputUID: String,
                                   ioProc: AudioDeviceIOProcID?, processor: GainProcessor) throws -> String {
        let streams = CA.objectList(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let tapUID = CA.string(tapID, kAudioTapPropertyUID)
        var notes: [String] = []
        var tapIndex: Int?
        for (i, stream) in streams.enumerated() {
            let owner = CA.value(stream, kAudioObjectPropertyOwner, as: AudioObjectID.self) ?? 0
            let format = CA.value(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self)
            let ownerUID = CA.string(owner, kAudioDevicePropertyDeviceUID) ?? CA.string(owner, kAudioTapPropertyUID)
            let isTap = owner == tapID || (tapUID != nil && ownerUID == tapUID)
            if isTap && tapIndex == nil { tapIndex = i }
            notes.append("in[\(i)] owner \(owner)\(isTap ? " (tap)" : "") \(format?.mChannelsPerFrame ?? 0)ch")
        }
        // The streams' owner is usually the aggregate itself, so that rarely settles it. The aggregate lists
        // its sub-device's input streams first and the tap after them: count the sub-device's streams.
        if tapIndex == nil, let device = OutputDevice.id(uid: outputUID) {
            let deviceInputs = CA.objectList(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
            notes.append("device has \(deviceInputs) input streams")
            if streams.count == deviceInputs + 1 { tapIndex = deviceInputs }
        }
        guard let tapIndex else {
            throw TapError.inputs("app's sound not found among \(streams.count) input streams")
        }
        notes.append("tap = in[\(tapIndex)]")
        processor.tapBufferIndex = tapIndex
        guard streams.count > 1 else { return notes.joined(separator: ", ") }
        guard let ioProc else { throw TapError.inputs("no audio callback") }

        // AudioHardwareIOProcStreamUsage: { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[n] }
        var addr = CA.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size) == noErr, size >= 16 else {
            throw TapError.inputs("stream switch unavailable")
        }
        let usage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { usage.deallocate() }
        let capacity = (Int(size) - 12) / 4 // how many stream flags actually fit in the buffer

        func read() -> Int? {
            usage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
            usage.storeBytes(of: unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
            var readSize = size
            guard AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &readSize, usage) == noErr else { return nil }
            return Int(usage.load(fromByteOffset: 8, as: UInt32.self))
        }

        guard let count = read(), count == streams.count, count <= capacity else {
            throw TapError.inputs("stream switch reports an unexpected layout")
        }
        for i in 0..<count {
            usage.storeBytes(of: UInt32(i == tapIndex ? 1 : 0), toByteOffset: 12 + 4 * i, as: UInt32.self)
        }
        let status = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, size, usage)
        guard status == noErr else { throw TapError.inputs("switching inputs off failed (\(status))") }

        // Read it back: only start if the system confirms exactly the tap is on.
        guard read() == count else { throw TapError.inputs("could not confirm the inputs are off") }
        for i in 0..<count where usage.load(fromByteOffset: 12 + 4 * i, as: UInt32.self) != (i == tapIndex ? 1 : 0) {
            throw TapError.inputs("input \(i) is still on")
        }
        return notes.joined(separator: ", ") + ", other inputs confirmed off"
    }

    /// Stops the tap. The app's own sound comes back at its normal level.
    public func invalidate() {
        if aggregateID != CA.unknown {
            if let ioProc {
                AudioDeviceStop(aggregateID, ioProc)
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != CA.unknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProc = nil
        aggregateID = CA.unknown
        tapID = CA.unknown
    }

    deinit { invalidate() }
}
