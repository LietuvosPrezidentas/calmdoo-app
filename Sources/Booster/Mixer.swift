import AppKit
import BoosterCore
import CoreAudio
import Observation

/// Knows which apps are making sound, holds each app's volume, and keeps
/// exactly the taps that are needed: an app at 100% with the master at 100% is left alone.
@MainActor
@Observable
final class Mixer {
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: NSImage?
        let isPlaying: Bool

        static func == (a: Row, b: Row) -> Bool { a.id == b.id && a.name == b.name && a.isPlaying == b.isPlaying }
    }

    private(set) var rows: [Row] = []
    private(set) var permission: AudioPermission.Status = .unknown
    private(set) var outputName = ""
    private(set) var problem: String?
    /// A one-off note for the panel, like "boosts were reset".
    private(set) var notice: String?
    private(set) var volumes: [String: Double] = [:]
    private(set) var muted: Set<String> = []
    private(set) var effects: [String: EffectSettings] = [:]
    /// 1...4: boosts every app on top of its own slider.
    private(set) var master: Double = 1

    private struct Identity { let key: String; let name: String; let icon: NSImage? }
    private struct Group { let identity: Identity; var objects: Set<AudioObjectID>; var playing: Bool }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let myPID = getpid()
    @ObservationIgnored private var groups: [String: Group] = [:]
    @ObservationIgnored private var taps: [String: AppTap] = [:]
    @ObservationIgnored private var identities: [pid_t: Identity] = [:]
    @ObservationIgnored private var lastPlaying: [String: Date] = [:]
    @ObservationIgnored private var lastNeeded: [String: Date] = [:]
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private var watched: Set<AudioObjectID> = []
    @ObservationIgnored private var outputUID: String?
    @ObservationIgnored private var lastKnownOutput: String?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var timer: Timer?
    #if BOOSTER_TEST_HOOKS
    @ObservationIgnored private var debugLog = false
    #endif

    /// How long a paused app keeps its tap, so pressing play again does not blast at full volume.
    private let pauseGrace: TimeInterval = 30

    init() {
        master = Self.clampMaster(defaults.object(forKey: "master") as? Double ?? 1)
        for (key, value) in defaults.dictionaryRepresentation() {
            if key.hasPrefix("volume."), let v = value as? Double, v.isFinite { volumes[String(key.dropFirst(7))] = GainCurve.snap(v) }
            if key.hasPrefix("muted."), (value as? Bool) == true { muted.insert(String(key.dropFirst(6))) }
            if key.hasPrefix("eq."), let bands = value as? [Double] {
                effects[String(key.dropFirst(3)), default: .neutral].eq = EffectSettings(eq: bands).eq
            }
            if key.hasPrefix("comp."), let raw = value as? Int, let mode = Compression(rawValue: UInt8(clamping: raw)) {
                effects[String(key.dropFirst(5)), default: .neutral].compression = mode
            }
        }
        permission = AudioPermission.status()
        Log.event("start: permission \(permission), master \(master), \(volumes.count) saved volumes")
        if permission != .granted {
            AudioPermission.request { [weak self] granted in
                MainActor.assumeIsolated {
                    Log.event("permission answer: \(granted)")
                    if !granted { Log.error("audio permission refused") }
                    self?.permission = granted ? .granted : AudioPermission.status()
                    self?.refresh()
                }
            }
        }
        listen()
        refresh()
    }

    // MARK: - What the panel calls

    func volume(_ id: String) -> Double { volumes[id] ?? 1 }

    func setMaster(_ value: Double) {
        notice = nil
        master = Self.clampMaster(value)
        defaults.set(master, forKey: "master")
        reconcile()
    }

    private static func clampMaster(_ value: Double) -> Double { min(max(GainCurve.snap(value), 1), GainCurve.maxVolume) }

    /// Settings are only kept for apps that have actually played, so nothing can fill the
    /// settings file with made-up names.
    private func isKnown(_ id: String) -> Bool { lastPlaying[id] != nil }

    func setVolume(_ value: Double, for id: String) {
        guard isKnown(id) else { return }
        notice = nil
        let v = GainCurve.snap(value)
        volumes[id] = v
        defaults.set(v, forKey: "volume." + id)
        reconcile()
    }

    func isMuted(_ id: String) -> Bool { muted.contains(id) }

    func toggleMute(_ id: String) {
        guard isKnown(id) else { return }
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        defaults.set(muted.contains(id), forKey: "muted." + id)
        reconcile()
    }

    func effects(_ id: String) -> EffectSettings { effects[id] ?? .neutral }

    func setEffects(_ settings: EffectSettings, for id: String) {
        guard isKnown(id) else { return }
        let s = EffectSettings(eq: settings.eq, compression: settings.compression) // clamps and rounds
        effects[id] = s
        if s.eq.allSatisfy({ $0 == 0 }) { defaults.removeObject(forKey: "eq." + id) } else { defaults.set(s.eq, forKey: "eq." + id) }
        if s.compression == .off { defaults.removeObject(forKey: "comp." + id) } else { defaults.set(Int(s.compression.rawValue), forKey: "comp." + id) }
        reconcile()
    }

    func askForPermission() {
        AudioPermission.request { [weak self] granted in
            MainActor.assumeIsolated {
                if !granted { AudioPermission.openSettings() }
                self?.permission = AudioPermission.status()
                self?.refresh()
            }
        }
    }

    func stopAll() {
        for key in Array(taps.keys) { drop(key, reason: "quit") }
    }

    private func gain(_ key: String) -> Float {
        if muted.contains(key) { return 0 }
        return GainCurve.combined(app: volume(key), master: master)
    }

    // MARK: - Watching Core Audio

    private func listen() {
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.queueRefresh() }
            }
        }
        // Safety net: catches anything a listener missed, and expires paused apps' taps.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        #if BOOSTER_TEST_HOOKS
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.booster.command"), object: nil, queue: .main
        ) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.run(command) }
        }
        #endif
    }

    /// One listener per process, so pressing play is noticed within milliseconds, not at the next tick.
    private func watch(_ objects: Set<AudioObjectID>) {
        for object in objects.subtracting(watched) {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(object, &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.queueRefresh() }
            }
        }
        watched = objects
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.refresh()
            }
        }
    }

    private func tick() {
        if permission != .granted {
            let now = AudioPermission.status()
            if now != permission { permission = now; Log.event("permission now \(now)") }
        }
        refresh()
        #if BOOSTER_TEST_HOOKS
        if debugLog {
            for (key, tap) in taps.sorted(by: { $0.key < $1.key }) {
                let peaks = tap.processor.takePeaks()
                Log.event(String(format: "level %@ gain %.3f in %.3f out %.3f", key, tap.processor.gain, peaks.input, peaks.output))
            }
        }
        #endif
    }

    // MARK: - Scan and reconcile

    func refresh() {
        scan()
        reconcile()
    }

    private func scan() {
        let processes = AudioProcesses.all().filter { $0.pid != myPID && $0.ownerPID != myPID }
        let livePIDs = Set(processes.map(\.ownerPID))
        identities = identities.filter { livePIDs.contains($0.key) }

        var found: [String: Group] = [:]
        for p in processes {
            let id = identity(p)
            found[id.key, default: Group(identity: id, objects: [], playing: false)].objects.insert(p.objectID)
            if p.isPlaying { found[id.key]?.playing = true }
        }
        groups = found
        watch(Set(processes.map(\.objectID)))

        let now = Date()
        for (key, group) in found where group.playing { lastPlaying[key] = now }

        // An app gets a row once it has played sound, and keeps it until it quits.
        let newRows = found.values
            .filter { lastPlaying[$0.identity.key] != nil }
            .map { Row(id: $0.identity.key, name: $0.identity.name, icon: $0.identity.icon, isPlaying: $0.playing) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if newRows != rows { rows = newRows }

        let device = OutputDevice.defaultID()
        let uid = device.flatMap(OutputDevice.uid)
        if uid != outputUID { Log.event("output device: \(uid ?? "none")") }
        outputUID = uid
        if let uid {
            if let previous = lastKnownOutput, previous != uid { outputChanged() }
            lastKnownOutput = uid
        }
        let name = device.flatMap(OutputDevice.name) ?? "No output"
        if name != outputName { outputName = name }
    }

    /// A boost set for quiet laptop speakers must not land in a pair of AirPods. When the output
    /// switches, anything above 100% goes back to 100%. Turned-down apps stay turned down.
    private func outputChanged() {
        var reset = false
        for (id, v) in volumes where v > 1 {
            volumes[id] = 1
            defaults.set(1.0, forKey: "volume." + id)
            reset = true
        }
        if master > 1 {
            master = 1
            defaults.set(1.0, forKey: "master")
            reset = true
        }
        if reset { notice = "Output changed, so boosts went back to 100%." }
    }

    private func reconcile() {
        guard permission == .granted, let output = outputUID else {
            for key in Array(taps.keys) { drop(key, reason: "no permission or output") }
            return
        }
        let now = Date()
        for (key, group) in groups {
            let g = gain(key)
            let recent = group.playing || now.timeIntervalSince(lastPlaying[key] ?? .distantPast) < pauseGrace
            let fx = effects(key)
            let needed = recent && (g != 1 || !fx.isNeutral)
            if needed { lastNeeded[key] = now }

            if let tap = taps[key] {
                let sameSetup = tap.processObjects == group.objects && tap.outputUID == output
                // Short grace so dragging a slider across 100% does not start and stop the tap.
                let stillWanted = now.timeIntervalSince(lastNeeded[key] ?? .distantPast) < 5
                if sameSetup && stillWanted {
                    tap.processor.gain = g
                    if tap.processor.settings != fx { tap.processor.settings = fx }
                    continue
                }
                drop(key, reason: sameSetup ? "not needed" : "processes or output changed")
            }
            if needed && now.timeIntervalSince(failedAt[key] ?? .distantPast) > 10 {
                do {
                    taps[key] = try AppTap.make(processObjects: group.objects, outputUID: output, gain: g, settings: fx)
                    Log.event("tap \(key) on \(output), \(group.objects.count) processes, gain \(g), eq \(fx.eq), comp \(fx.compression); inputs: \(taps[key]?.diagnostics ?? "")")
                    failedAt[key] = nil
                    if problem != nil { problem = nil }
                } catch {
                    failedAt[key] = now
                    problem = "Couldn't change \(group.identity.name): \(error)"
                    Log.error("could not change \(group.identity.name): \(error)")
                }
            }
        }
        for key in taps.keys where groups[key] == nil { drop(key, reason: "app gone") }
    }

    private func drop(_ key: String, reason: String) {
        taps[key]?.invalidate()
        taps[key] = nil
        Log.event("untap \(key): \(reason)")
    }

    // MARK: - Naming apps

    private static let friendlyNames = [
        "systemsoundserverd": "System sounds",
        "com.apple.PowerChime": "Charging sound",
    ]

    private func identity(_ p: AudioProcess) -> Identity {
        if let cached = identities[p.ownerPID] { return cached }
        let id: Identity
        if let app = NSRunningApplication(processIdentifier: p.ownerPID), let bundle = app.bundleIdentifier {
            id = Identity(key: bundle, name: Self.clean(Self.friendlyNames[bundle] ?? app.localizedName ?? bundle), icon: app.icon)
        } else {
            let bundle = p.bundleID ?? AudioProcesses.processName(p.pid) ?? "pid.\(p.pid)"
            let fallback = bundle.split(separator: ".").last.map(String.init) ?? bundle
            id = Identity(key: bundle, name: Self.friendlyNames[bundle] ?? fallback, icon: nil)
        }
        identities[p.ownerPID] = id
        return id
    }

    /// Drops invisible direction marks some apps put in their names (WhatsApp does).
    private static func clean(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}\u{200F}")))
    }

    // MARK: - Test hook (test builds only: ./build.sh --test-hooks)

    #if BOOSTER_TEST_HOOKS
    /// Commands from tools/ctl.sh, for testing without clicking:
    /// "dump", "debug=on", "debug=off", "master=2", "<bundle id>=0.5", "mute=<bundle id>",
    /// "comp=<bundle id>:strong", "eq=<bundle id>:6,0,0,0,-3", "output-changed".
    /// Anything on the Mac can send these, which is why release builds do not listen.
    private func run(_ command: String) {
        Log.event("command: \(command)")
        if command == "output-changed" { outputChanged(); reconcile(); return }
        if command == "dump" {
            for (key, group) in groups.sorted(by: { $0.key < $1.key }) where lastPlaying[key] != nil {
                Log.event("app \(key) \"\(group.identity.name)\" playing=\(group.playing) processes=\(group.objects.sorted()) volume=\(volume(key)) muted=\(isMuted(key)) eq=\(effects(key).eq) comp=\(effects(key).compression) tapped=\(taps[key] != nil)")
            }
            Log.event("permission=\(permission) output=\(outputUID ?? "none") master=\(master) taps=\(taps.keys.sorted()) notice=\(notice ?? "none")")
            return
        }
        let parts = command.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "debug": debugLog = parts[1] == "on"
        case "master": if let v = Double(parts[1]) { setMaster(v) }
        case "mute": toggleMute(parts[1])
        case "comp", "eq":
            let arg = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
            guard arg.count == 2 else { return }
            var s = effects(arg[0])
            if parts[0] == "comp" {
                s.compression = ["off": .off, "light": .light, "strong": .strong][arg[1]] ?? .off
            } else {
                s.eq = arg[1].split(separator: ",").compactMap { Double($0) }
            }
            setEffects(s, for: arg[0])
        default: if let v = Double(parts[1]) { setVolume(v, for: parts[0]) }
        }
    }
    #endif
}
