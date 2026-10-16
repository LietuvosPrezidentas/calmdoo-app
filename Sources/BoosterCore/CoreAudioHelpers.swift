import CoreAudio
import Foundation

/// Small wrappers over AudioObjectGetPropertyData.
enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// For plain value types only (integers, floats, IDs).
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw) == noErr else { return nil }
        return raw.load(as: T.self)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)
}

/// The Mac's current default output (speakers, headphones, AirPods...).
public enum OutputDevice {
    public static func defaultID() -> AudioObjectID? {
        guard let id = CA.value(CA.system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self),
              id != CA.unknown else { return nil }
        return id
    }

    public static func uid(_ id: AudioObjectID) -> String? { CA.string(id, kAudioDevicePropertyDeviceUID) }

    public static func id(uid: String) -> AudioObjectID? {
        var addr = CA.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = CA.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(CA.system, &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != CA.unknown ? device : nil
    }
    public static func name(_ id: AudioObjectID) -> String? { CA.string(id, kAudioObjectPropertyName) }
}
