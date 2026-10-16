import BoosterCore
import ServiceManagement
import SwiftUI

/// The panel that drops down from the menu bar icon.
struct MixerView: View {
    let mixer: Mixer
    let panel: PanelState
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if mixer.permission != .granted { permissionBanner }
            masterRow
            Divider().padding(.vertical, 10)
            apps
            if let problem = mixer.problem {
                Text(problem).font(.caption).foregroundStyle(.red).padding(.top, 8)
            }
            Divider().padding(.vertical, 10)
            footer
        }
        .padding(14)
        .frame(width: 330)
    }

    private var header: some View {
        HStack {
            Text("Booster").font(.system(size: 15, weight: .bold))
            Spacer()
            Label(mixer.outputName, systemImage: "hifispeaker.fill")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.bottom, 12)
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Booster needs one permission to change app volumes.")
                .font(.callout.weight(.medium))
            Text("System Settings → Privacy & Security → Screen & System Audio Recording → turn on Booster under “System Audio Recording Only”.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { mixer.askForPermission() }.controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 12)
    }

    private var masterRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Boost everything", systemImage: "bolt.fill").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(percent(mixer.master)) { mixer.setMaster(1) }
                    .buttonStyle(.plain).monospacedDigit()
                    .foregroundStyle(mixer.master > 1 ? Color.orange : Color.secondary)
                    .help("Click to reset to 100%")
            }
            Slider(value: Binding(get: { mixer.master }, set: { mixer.setMaster($0) }), in: 1...GainCurve.maxVolume)
                .controlSize(.small)
                .tint(.orange)
        }
    }

    @ViewBuilder private var apps: some View {
        if mixer.rows.isEmpty {
            Text("Nothing has played yet. Start a song or a video and the app shows up here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if mixer.rows.count > 6 {
            ScrollView { appList }.frame(height: 360)
        } else {
            appList
        }
    }

    private var appList: some View {
        VStack(spacing: 12) {
            ForEach(mixer.rows) { row in
                AppRowView(row: row, mixer: mixer, isExpanded: panel.expanded == row.id) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        panel.expanded = panel.expanded == row.id ? nil : row.id
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Open at login", isOn: $opensAtLogin)
                .toggleStyle(.checkbox).font(.caption)
                .onChange(of: opensAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        Log.write("open at login: \(error)")
                    }
                    let actual = SMAppService.mainApp.status == .enabled
                    if actual != on { opensAtLogin = actual }
                }
            Spacer()
            Button("Quit") {
                mixer.stopAll()
                NSApp.terminate(nil)
            }
            .controlSize(.small)
            .keyboardShortcut("q")
        }
    }
}

private struct AppRowView: View {
    let row: Mixer.Row
    let mixer: Mixer
    let isExpanded: Bool
    let toggleEffects: () -> Void

    var body: some View {
        let volume = mixer.volume(row.id)
        let muted = mixer.isMuted(row.id)
        let effectsOn = !mixer.effects(row.id).isNeutral
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    if let icon = row.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if row.isPlaying {
                            Circle().fill(Color.green).frame(width: 6, height: 6).help("Playing now")
                        }
                        Spacer()
                        Button(action: toggleEffects) {
                            Image(systemName: "slider.vertical.3")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(effectsOn ? Color.orange : isExpanded ? Color.primary : Color.secondary)
                        .help("EQ and compressor")
                        Button(muted ? "Muted" : percent(volume)) { mixer.setVolume(1, for: row.id) }
                            .buttonStyle(.plain).monospacedDigit().font(.callout)
                            .foregroundStyle(muted ? Color.red : volume > 1 ? Color.orange : Color.secondary)
                            .help("Click to reset to 100%")
                    }
                    HStack(spacing: 6) {
                        Button { mixer.toggleMute(row.id) } label: {
                            Image(systemName: muted ? "speaker.slash.fill" : speakerSymbol(volume)).frame(width: 18)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(muted ? Color.red : Color.secondary)
                        .help(muted ? "Unmute" : "Mute")

                        // 100% sits in the middle: left half is quieter, right half is boost.
                        Slider(value: Binding(get: { SliderScale.position(volume: volume) },
                                              set: { mixer.setVolume(SliderScale.volume(position: $0), for: row.id) }),
                               in: 0...1)
                            .controlSize(.small)
                            .tint(volume > 1 ? .orange : .accentColor)
                            .disabled(muted)
                    }
                }
            }
            if isExpanded {
                EffectsView(id: row.id, mixer: mixer)
                    .transition(.opacity)
            }
        }
    }

    private func speakerSymbol(_ v: Double) -> String {
        v == 0 ? "speaker.fill" : v < 0.5 ? "speaker.wave.1.fill" : v <= 1 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// Compressor and 5-band EQ for one app.
private struct EffectsView: View {
    let id: String
    let mixer: Mixer

    var body: some View {
        let fx = mixer.effects(id)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Compressor").font(.caption.weight(.semibold))
                    Spacer()
                    Picker("Compressor", selection: Binding(get: { fx.compression }, set: { update { $0.compression = $1 }($0) })) {
                        Text("Off").tag(Compression.off)
                        Text("Light").tag(Compression.light)
                        Text("Strong").tag(Compression.strong)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 160)
                }
                Text("Quiet parts up, loud parts down.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("EQ").font(.caption.weight(.semibold))
                    Spacer()
                    Menu("Presets") {
                        ForEach(EffectSettings.presets, id: \.name) { preset in
                            Button(preset.name) { update { $0.eq = $1 }(preset.eq) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                }
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<EffectSettings.bandCount, id: \.self) { band in
                        VStack(spacing: 2) {
                            Text(dbLabel(fx.eq[band]))
                                .font(.system(size: 9)).monospacedDigit()
                                .foregroundStyle(fx.eq[band] == 0 ? Color.secondary : Color.primary)
                            VerticalSlider(value: Binding(get: { fx.eq[band] },
                                                          set: { value in update { $0.eq[band] = $1 }(value) }),
                                           range: -EffectSettings.maxDB...EffectSettings.maxDB)
                            Text(EffectSettings.bandNames[band]).font(.system(size: 9, weight: .medium))
                                .lineLimit(1).fixedSize()
                            Text(EffectSettings.bandLabels[band]).font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Reads the current settings fresh, applies one change, saves.
    private func update<T>(_ change: @escaping (inout EffectSettings, T) -> Void) -> (T) -> Void {
        { value in
            var s = mixer.effects(id)
            change(&s, value)
            mixer.setEffects(s, for: id)
        }
    }

    private func dbLabel(_ db: Double) -> String {
        db == 0 ? "0" : String(format: db.rounded() == db ? "%+.0f" : "%+.1f", db)
    }
}

/// A slim vertical slider for EQ bands. Snaps to half-dB steps and sticks at 0.
private struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    private let knob: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let x = geo.size.width / 2
            let travel = geo.size.height - knob
            let span = range.upperBound - range.lowerBound
            let y = { (v: Double) in knob / 2 + (1 - CGFloat((v - range.lowerBound) / span)) * travel }
            let knobY = y(value), zeroY = y(0)
            ZStack {
                Capsule().fill(Color.secondary.opacity(0.25))
                    .frame(width: 4, height: geo.size.height).position(x: x, y: geo.size.height / 2)
                Rectangle().fill(value >= 0 ? Color.orange : Color.accentColor)
                    .frame(width: 4, height: abs(knobY - zeroY)).position(x: x, y: (knobY + zeroY) / 2)
                Rectangle().fill(Color.secondary.opacity(0.6))
                    .frame(width: 12, height: 1).position(x: x, y: zeroY)
                Circle().fill(Color.white).shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: knob, height: knob).position(x: x, y: knobY)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = 1 - min(max((drag.location.y - knob / 2) / travel, 0), 1)
                var v = ((range.lowerBound + Double(f) * span) * 2).rounded() / 2
                if abs(v) < 0.75 { v = 0 }
                if v != value { value = v }
            })
        }
        .frame(width: 26, height: 60)
    }
}

private func percent(_ volume: Double) -> String { "\(Int((volume * 100).rounded()))%" }
