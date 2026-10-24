import SwiftUI
#if os(iOS)
import AVFoundation
#endif

/// Quick RX / TX level adjustment, opened from the Levels button or the header meter.
struct LevelsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                        RxMeter(level: model.inputLevel,
                                clipping: ctx.date.timeIntervalSince(model.lastClip) < 2,
                                transmitting: model.isTransmitting)
                    }
                    Picker("Input channel", selection: $model.settings.inputChannel) {
                        Text("Left").tag(0)
                        Text("Right").tag(1)
                        Text("Mix").tag(-1)
                    }
                    if let gain = model.inputGain {
                        LevelSlider(title: "RX gain",
                                    value: Binding(get: { gain }, set: { model.settings.inputGain = $0 }))
                    }
                } header: {
                    Label("Receive", systemImage: "arrow.down.circle")
                } footer: {
                    Text(model.inputGain == nil
                         ? "On a quiet part of the band, aim for about 30 dB. This interface has no adjustable input gain, so set it with the radio's audio-out level (often a USB / DATA audio menu item)."
                         : "On a quiet part of the band, aim for about 30 dB. If RX gain runs out, adjust the radio's audio-out level too.")
                }

                Section {
                    LevelSlider(title: "TX level", value: $model.settings.tx.outputLevel, range: 0.01...1)
                    Button {
                        model.isTuning ? model.stopTune() : model.startTune()
                    } label: {
                        Label(model.isTuning ? "Stop tune" : "Tune (key a steady carrier)",
                              systemImage: model.isTuning ? "stop.fill" : "tuningfork")
                            .font(Theme.rounded(15, .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(model.isTuning ? Theme.bg : Theme.warn)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(model.isTuning ? Theme.tx : Theme.warn.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.settings.txEnabled)
                    if !model.settings.txEnabled {
                        Text("TX is off — turn it on to tune.").font(.caption).foregroundStyle(Theme.warn)
                    }
                    #if os(iOS)
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        LabeledContent("iPhone volume",
                                       value: "\(Int((AVAudioSession.sharedInstance().outputVolume * 100).rounded()))%")
                    }
                    #endif
                } header: {
                    Label("Transmit", systemImage: "arrow.up.circle")
                } footer: {
                    Text(tuneHint)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.backgroundGradient)
            .navigationTitle("Levels")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onDisappear { model.stopTune() }
    }

    private var tuneHint: String {
        #if os(iOS)
        "Press Tune, then raise TX level until the radio's ALC just starts to move, and back off a little. Leave the iPhone volume at a fixed setting (it multiplies TX level). Tune stops when you close this panel."
        #else
        "Press Tune, then raise TX level until the radio's ALC just starts to move, and back off a little. Tune stops when you close this panel."
        #endif
    }
}

/// Slider with fine −/+ steps and a percentage readout.
private struct LevelSlider: View {
    let title: String
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .font(Theme.mono(14, .semibold))
                    .monospacedDigit()
            }
            HStack(spacing: 10) {
                step(-0.01, icon: "minus")
                Slider(value: $value, in: range)
                step(0.01, icon: "plus")
            }
        }
    }

    private func step(_ delta: Float, icon: String) -> some View {
        Button {
            value = min(range.upperBound, max(range.lowerBound, ((value + delta) * 100).rounded() / 100))
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.accent.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
    }
}

/// Receive level on JS8Call's scale (dB above one 16-bit step), with the target zone shaded.
struct RxMeter: View {
    let level: Float          // dBFS
    let clipping: Bool
    let transmitting: Bool

    static let scale: ClosedRange<Float> = 0...90
    static let target: ClosedRange<Float> = 25...45

    /// JS8Call / WSJT-X meter units: full scale is about 90 dB.
    private var db: Float { level + 90.3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(db > 0 ? "\(Int(db.rounded())) dB" : "– dB")
                    .font(Theme.mono(28, .bold))
                    .monospacedDigit()
                    .foregroundStyle(status.color)
                Text(String(format: "%.0f dBFS", level))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(status.text)
                    .font(Theme.rounded(13, .bold))
                    .foregroundStyle(status.color)
                    .multilineTextAlignment(.trailing)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Theme.stroke)
                    Rectangle().fill(Theme.rx.opacity(0.22))
                        .frame(width: x(Self.target.upperBound, w) - x(Self.target.lowerBound, w))
                        .offset(x: x(Self.target.lowerBound, w))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(status.color)
                        .frame(width: max(4, x(db, w)))
                        .animation(.easeOut(duration: 0.15), value: db)
                    Rectangle().fill(Theme.text).frame(width: 2)
                        .offset(x: x(30, w) - 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 16)
            HStack {
                ForEach([0, 30, 60, 90], id: \.self) { v in
                    Text("\(v)")
                    if v != 90 { Spacer() }
                }
            }
            .font(Theme.mono(10))
            .foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 4)
    }

    private func x(_ v: Float, _ width: CGFloat) -> CGFloat {
        let s = Self.scale
        return width * CGFloat((min(s.upperBound, max(s.lowerBound, v)) - s.lowerBound) / (s.upperBound - s.lowerBound))
    }

    private var status: (text: String, color: Color) {
        if transmitting { return ("Transmitting", Theme.dim) }
        if clipping { return ("Clipping — turn down", Theme.tx) }
        switch db {
        case ..<5: return ("No audio — check cable / channel", Theme.tx)
        case ..<15: return ("Too low", Theme.tx)
        case ..<Self.target.lowerBound: return ("A little low", Theme.warn)
        case ...Self.target.upperBound: return ("Good", Theme.rx)
        case ..<60: return ("A little hot", Theme.warn)
        default: return ("Too hot — turn down", Theme.tx)
        }
    }
}
