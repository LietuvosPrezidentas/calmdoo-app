import AppKit
import Observation
import SwiftUI

@main
enum BoosterApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Which app's EQ is open. Only one at a time, so the panel stays short.
@MainActor
@Observable
final class PanelState {
    var expanded: String?
}

/// Menu bar icon + popover. A plain NSPopover is used instead of SwiftUI's MenuBarExtra because
/// MenuBarExtra's window does not grow when the content does (the EQ got cut off).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mixer: Mixer!
    private let panel = PanelState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        mixer = Mixer()

        let host = NSHostingController(rootView: MixerView(mixer: mixer, panel: panel))
        host.sizingOptions = [.preferredContentSize] // the popover follows the content's size
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        updateIcon()

        #if BOOSTER_TEST_HOOKS
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.calmdoo.command"), object: nil, queue: .main
        ) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.run(command) }
        }
        #endif
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Louder icon while "Boost everything" is above 100%.
    private func updateIcon() {
        let boosted = withObservationTracking {
            mixer.master > 1
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateIcon() } }
        }
        let image = NSImage(systemSymbolName: boosted ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                            accessibilityDescription: "calmdoo")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - Test hook for the panel itself (tools/ctl.sh open | close | expand=<id> | expand= | snapshot)

    #if BOOSTER_TEST_HOOKS

    private func run(_ command: String) {
        switch command {
        case "open": showPanel()
        case "close": popover.performClose(nil)
        case "snapshot": snapshot()
        default:
            if command.hasPrefix("expand=") {
                let id = String(command.dropFirst(7))
                panel.expanded = id.isEmpty ? nil : id
            }
        }
    }

    /// Saves a picture of the open panel to ~/Library/Logs/calmdoo-panel.png and logs its size,
    /// so the layout can be checked without a screen recording permission.
    private func snapshot() {
        guard popover.isShown, let view = popover.contentViewController?.view else {
            Log.event("snapshot: panel is not open")
            return
        }
        view.layoutSubtreeIfNeeded()
        let fitting = (popover.contentViewController as? NSHostingController<MixerView>)?.sizeThatFits(in: CGSize(width: 330, height: 10_000))
        let window = view.window?.frame.size ?? .zero
        Log.event("snapshot: popover \(Int(popover.contentSize.width))x\(Int(popover.contentSize.height)), window \(Int(window.width))x\(Int(window.height)), content wants \(Int(fitting?.width ?? 0))x\(Int(fitting?.height ?? 0))")
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // The capture has no popover background, so white text would vanish: put the panel's own colour behind it.
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
        let url = Log.url.deletingLastPathComponent().appending(path: "calmdoo-panel.png")
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif
}
