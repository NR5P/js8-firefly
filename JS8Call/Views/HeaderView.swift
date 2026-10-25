import SwiftUI
import JS8Core

/// Top status console: clock, period ring, band/dial, speed and TX state.
struct HeaderView: View {
    @Environment(AppModel.self) private var model
    @State private var showBands = false
    @State private var showLevels = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let now = AppClock.now()
            HStack(spacing: 12) {
                PeriodRing(submode: model.settings.submode, now: now, transmitting: model.isTransmitting)
                    .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.settings.station.callsign.isEmpty ? "NOCALL" : model.settings.station.callsign)
                            .font(Theme.mono(15, .bold))
                            .foregroundStyle(Theme.text)
                        if !model.settings.station.grid.isEmpty {
                            Text(model.settings.station.grid.prefix(6))
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    Text(Format.utcTime.string(from: now) + " UTC")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.dim)
                }

                Spacer(minLength: 4)

                Button {
                    showBands = true
                } label: {
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 4) {
                            Circle().fill(rigColor).frame(width: 6, height: 6)
                            Text([Band.name(for: model.settings.dialFrequency), model.settings.dialLabel]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.rounded(11, .bold))
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                        }
                        Text(Format.mhzLong(model.settings.dialFrequency))
                            .font(Theme.mono(15, .semibold))
                            .foregroundStyle(Theme.text)
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.plain)

                SpeedMenu()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    Theme.bg2.opacity(0.92)
                    if model.isTransmitting {
                        LinearGradient(colors: [Theme.tx.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    }
                }
            )
            .overlay(alignment: .bottom) {
                LevelBar(level: model.inputLevel, transmitting: model.isTransmitting)
                    .frame(height: 3)
                    .frame(height: 10, alignment: .bottom)
                    .contentShape(Rectangle())
                    .onTapGesture { showLevels = true }
            }
            .id(ctx.date.timeIntervalSince1970 > 0)
        }
        .sheet(isPresented: $showBands) {
            BandPickerSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showLevels) {
            LevelsSheet()
                .presentationDetents([.fraction(0.85), .large])
        }
    }

    private var rigColor: Color {
        switch model.rig.status {
        case .connected: return Theme.rx
        case .connecting: return Theme.warn
        case .error: return Theme.tx
        case .disconnected: return Theme.faint
        }
    }
}

struct SpeedMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(JS8Submode.allCases.sorted { $0.period > $1.period }) { m in
                Button {
                    model.settings.submode = m
                } label: {
                    Label("\(m.name) — \(m.period)s, \(m.bandwidth) Hz", systemImage: model.settings.submode == m ? "checkmark" : "")
                }
            }
        } label: {
            Text(model.settings.submode.name.uppercased())
                .font(Theme.mono(11, .bold))
                .foregroundStyle(Theme.modeColor(model.settings.submode))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.modeColor(model.settings.submode).opacity(0.14)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Ring showing progress through the current transmit period.
struct PeriodRing: View {
    let submode: JS8Submode
    let now: Date
    let transmitting: Bool

    var body: some View {
        let p = Double(submode.period)
        let t = now.timeIntervalSince1970.truncatingRemainder(dividingBy: p)
        let frac = t / p
        let txFrac = submode.txDuration / p
        ZStack {
            Circle().stroke(Theme.stroke, lineWidth: 5)
            Circle()
                .trim(from: Double(submode.startDelayMS) / 1000 / p, to: txFrac)
                .stroke(Theme.faint.opacity(0.6), style: StrokeStyle(lineWidth: 5))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: frac)
                .stroke(transmitting ? Theme.tx : Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .glow(transmitting ? Theme.tx : Theme.accent, radius: 4)
            VStack(spacing: -2) {
                Text("\(Int(p - t))")
                    .font(Theme.mono(14, .bold))
                    .foregroundStyle(transmitting ? Theme.tx : Theme.text)
                Text(transmitting ? "TX" : "RX")
                    .font(Theme.rounded(8, .heavy))
                    .foregroundStyle(transmitting ? Theme.tx : Theme.rx)
            }
        }
    }
}

struct LevelBar: View {
    let level: Float
    let transmitting: Bool

    var body: some View {
        GeometryReader { geo in
            let norm = CGFloat(max(0, min(1, (level + 80) / 70)))
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.stroke)
                Rectangle()
                    .fill(LinearGradient(colors: [Theme.rx, Theme.warn, Theme.tx], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * (transmitting ? 1 : norm))
                    .opacity(transmitting ? 0.6 : 1)
            }
        }
    }
}

struct BandPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""
    @State private var customLabel = ""
    @State private var editing: SavedFrequency?
    @State private var editKHz = ""
    @State private var editLabel = ""

    var body: some View {
        NavigationStack {
            List {
                if !model.settings.customFrequencies.isEmpty {
                    Section {
                        ForEach(model.settings.customFrequencies) { saved in
                            Button {
                                model.setDial(saved.frequency)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(saved.label.isEmpty ? Band.name(for: saved.frequency) : saved.label)
                                            .font(Theme.rounded(16, .semibold))
                                            .lineLimit(1)
                                        Text(Format.mhzLong(saved.frequency) + " MHz · " + Band.name(for: saved.frequency))
                                            .font(Theme.mono(13))
                                            .foregroundStyle(Theme.dim)
                                    }
                                    Spacer()
                                    if model.settings.dialFrequency == saved.frequency {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { model.deleteFrequency(saved.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { beginEdit(saved) } label: { Label("Edit", systemImage: "pencil") }
                            }
                            .contextMenu {
                                Button { beginEdit(saved) } label: { Label("Edit", systemImage: "pencil") }
                                Button(role: .destructive) { model.deleteFrequency(saved.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("My frequencies")
                    } footer: {
                        Text("Swipe or long-press to edit or delete.")
                    }
                }
                Section {
                    ForEach(Band.js8) { band in
                        Button {
                            model.setDial(band.frequency)
                            dismiss()
                        } label: {
                            HStack {
                                Text(band.name).font(Theme.rounded(16, .semibold)).frame(width: 60, alignment: .leading)
                                Text(Format.mhzLong(band.frequency) + " MHz").font(Theme.mono(15))
                                Spacer()
                                if model.settings.dialFrequency == band.frequency {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("JS8 calling frequencies (USB dial)")
                } footer: {
                    Text(model.rig.isConnected ? "The radio will be tuned automatically." :
                        "No rig control connected — set the radio to this dial frequency in USB / DATA-U.")
                }
                Section {
                    TextField("kHz, e.g. " + String(format: "%.3f", Double(model.settings.dialFrequency) / 1000), text: $custom)
                        .font(Theme.mono(15))
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    TextField("Label (optional), e.g. Local Net", text: $customLabel)
                    HStack {
                        Button("Tune") {
                            if let hz = Self.parseKHz(custom) {
                                model.setDial(hz)
                                dismiss()
                            }
                        }
                        .disabled(Self.parseKHz(custom) == nil)
                        Spacer()
                        Button("Save") {
                            let hz = custom.isEmpty ? model.settings.dialFrequency : Self.parseKHz(custom)
                            guard let hz else { return }
                            model.saveFrequency(hz, label: customLabel)
                            model.setDial(hz)
                            custom = ""
                            customLabel = ""
                        }
                        .disabled(!custom.isEmpty && Self.parseKHz(custom) == nil)
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Custom dial")
                } footer: {
                    Text("Save adds it to My frequencies. Leave the frequency empty to save the current dial.")
                }
            }
            .navigationTitle("Band")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Edit frequency", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("kHz", text: $editKHz)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                TextField("Label", text: $editLabel)
                Button("Save") {
                    if let saved = editing, let hz = Self.parseKHz(editKHz) {
                        model.saveFrequency(hz, label: editLabel, replacing: saved.id)
                    }
                    editing = nil
                }
                Button("Cancel", role: .cancel) { editing = nil }
            }
        }
    }

    private func beginEdit(_ saved: SavedFrequency) {
        editKHz = String(format: "%.3f", Double(saved.frequency) / 1000)
        editLabel = saved.label
        editing = saved
    }

    static func parseKHz(_ text: String) -> UInt64? {
        guard let khz = Double(text.replacingOccurrences(of: ",", with: ".")), khz > 100 else { return nil }
        return UInt64((khz * 1000).rounded())
    }
}
