import Foundation

/// Which sound sources calmdoo lists and may take over: real apps only.
/// macOS's own background helpers (the charging chime, alert sounds, Siri, Control Centre) are
/// never shown and never tapped, not even by "Boost everything".
public enum AppFilter {
    /// How macOS runs the app that owns the sound (NSApplication.ActivationPolicy, or not an app at all).
    public enum Kind: Sendable {
        case regular     // has a Dock icon: Safari, Spotify, Chrome...
        case accessory   // menu bar only
        case prohibited  // a background helper with no interface
        case notAnApp    // a daemon: no running application at all
    }

    public static func isUserFacing(_ kind: Kind, bundleID: String?) -> Bool {
        switch kind {
        case .regular:
            return true
        case .accessory:
            // Other companies' menu bar apps can play sound people want to control.
            // Apple's menu bar agents (Control Centre, Siri, Notification Centre) are part of macOS.
            return !(bundleID ?? "").hasPrefix("com.apple.")
        case .prohibited, .notAnApp:
            return false
        }
    }
}
