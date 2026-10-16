import CoreAudio
import Darwin
import Foundation

/// One process that Core Audio knows about, playing or not.
public struct AudioProcess: Hashable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isPlaying: Bool
    /// The app this process works for. Safari's sound comes from "com.apple.WebKit.GPU",
    /// Chrome's from "com.google.Chrome.helper"; this points both back at the browser.
    public let ownerPID: pid_t
}

public enum AudioProcesses {
    public static func all() -> [AudioProcess] {
        CA.objectList(CA.system, kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = CA.value(id, kAudioProcessPropertyPID, as: pid_t.self), pid > 0 else { return nil }
            let running = CA.value(id, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0
            let bundle = CA.string(id, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
            let owner = responsiblePID(pid)
            return AudioProcess(objectID: id, pid: pid, bundleID: bundle, isPlaying: running != 0,
                                ownerPID: owner > 0 ? owner : pid)
        }
    }

    /// Short process name from the kernel, for processes that are not apps.
    public static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    // A libsystem function with no public header; the same one Activity Monitor-style tools use.
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t { responsibleFn?(pid) ?? -1 }
}
