import AppKit
import Foundation

/// The "System Audio Recording" permission (Privacy & Security -> Screen & System Audio Recording).
/// macOS has no public call to check it, so this uses the TCC framework's own functions, as AudioCap does.
/// Without it a tap returns silence, so Booster never taps an app until this says granted.
enum AudioPermission {
    enum Status { case granted, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static func status() -> Status {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the macOS permission prompt (only if the user has not answered it before).
    static func request(_ done: @escaping (Bool) -> Void) {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else { done(false); return }
        unsafeBitCast(sym, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
