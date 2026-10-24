import SwiftUI
import JS8Core
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The RX/TX conversation pane, styled as a chat.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    var filterCallsign: String?

    var body: some View {
        let lines = model.conversation.filter { line in
            guard let c = filterCallsign, !c.isEmpty else { return true }
            return line.text.contains(c)
        }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if lines.isEmpty {
                        EmptyStateView(icon: "bubble.left.and.bubble.right", title: "No traffic yet",
                                       subtitle: "Messages on your offset and anything directed to you show up here.")
                    }
                    ForEach(lines) { line in
                        MessageBubble(line: line, eot: model.settings.station.eot, mycall: model.settings.station.callsign)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: model.conversation.last?.text) { _, _ in
                if let last = lines.last {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

/// Everything decoded across the passband, one bubble per transmission.
/// Tap a bubble to move there and select the sender.
struct BandConversationView: View {
    @Environment(AppModel.self) private var model
    var filterCallsign: String?
    var showHeartbeats = false

    var body: some View {
        let lines = model.bandConversation.filter { line in
            if !showHeartbeats && (line.text.contains("@HB") || line.text.contains(" HEARTBEAT")) { return false }
            guard let c = filterCallsign, !c.isEmpty else { return true }
            return line.text.contains(c)
        }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if lines.isEmpty {
                        EmptyStateView(icon: "dot.radiowaves.left.and.right", title: "Nothing heard yet",
                                       subtitle: "Every conversation decoded anywhere in the passband shows up here. Tap one to join it.")
                    }
                    ForEach(lines) { line in
                        let onMyOffset = abs(line.offset - model.settings.offset) <= (line.submode ?? model.settings.submode).rxThreshold
                        MessageBubble(line: line, eot: model.settings.station.eot, mycall: model.settings.station.callsign,
                                      showSignal: true, onMyOffset: onMyOffset)
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture { if !line.isTx { join(line) } }
                            .contextMenu {
                                if !line.isTx {
                                    Button("Listen on \(line.offset) Hz") { model.setOffset(line.offset) }
                                    if let call = AppModel.sender(of: line) {
                                        Button("Join \(call) on \(line.offset) Hz") { join(line) }
                                    }
                                }
                                Button("Copy text") { Pasteboard.copy(line.text) }
                            }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: model.bandConversation.last?.text) { _, _ in
                if let last = lines.last {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func join(_ line: ConversationLine) {
        model.join(line)
        let who = AppModel.sender(of: line).map { " with \($0) selected" } ?? ""
        model.banner = "Listening on \(line.offset) Hz\(who)"
    }
}

enum Pasteboard {
    static func copy(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}

/// Which traffic the chat pane shows.
enum ChatScope: String, CaseIterable, Identifiable {
    case band = "All band"
    case mine = "My offset"
    var id: String { rawValue }
}

/// Conversation header with the All band / My offset switch, used on every layout.
struct ChatPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("chatScope") private var scope = ChatScope.band
    @AppStorage("chatShowHeartbeats") private var showHeartbeats = false
    @State private var onlySelected = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("Show", selection: $scope) {
                    ForEach(ChatScope.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                Spacer()
                if scope == .band {
                    Toggle(isOn: $showHeartbeats) { Image(systemName: showHeartbeats ? "heart.fill" : "heart.slash") }
                        .toggleStyle(.button)
                        .font(.caption)
                        .accessibilityLabel("Show heartbeats")
                }
                if !model.selectedCallsign.isEmpty {
                    Toggle("Only \(model.selectedCallsign)", isOn: $onlySelected)
                        .toggleStyle(.button)
                        .font(.caption)
                }
                Button {
                    scope == .band ? model.clearBandConversation() : model.clearConversation()
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 10)
            let filter = onlySelected ? model.selectedCallsign : nil
            switch scope {
            case .band: BandConversationView(filterCallsign: filter, showHeartbeats: showHeartbeats)
            case .mine: ConversationView(filterCallsign: filter)
            }
        }
    }
}

struct MessageBubble: View {
    let line: ConversationLine
    let eot: String
    let mycall: String
    var showSignal = false
    var onMyOffset = false

    var body: some View {
        let toMe = !line.isTx && !mycall.isEmpty && line.text.contains(" \(mycall)")
        HStack {
            if line.isTx { Spacer(minLength: 40) }
            VStack(alignment: line.isTx ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Format.utcTime.string(from: line.date))
                    Text("\(line.offset) Hz")
                        .foregroundStyle(onMyOffset ? Theme.warn : Theme.faint)
                    if showSignal, !line.isTx, let snr = line.snr {
                        Text(Format.snr(snr) + " dB").foregroundStyle(Theme.snrColor(snr))
                    }
                    if showSignal, let m = line.submode {
                        Text(m.name).foregroundStyle(Theme.modeColor(m))
                    }
                    if line.isTx { Image(systemName: "antenna.radiowaves.left.and.right") }
                    if showSignal && onMyOffset && !line.isTx { Image(systemName: "ear").foregroundStyle(Theme.warn) }
                }
                .font(Theme.mono(9))
                .foregroundStyle(Theme.faint)
                Text(line.text.replacingOccurrences(of: " \(eot) ", with: " \(eot)").trimmingCharacters(in: .whitespaces))
                    .font(Theme.mono(14))
                    .foregroundStyle(line.isTx ? Theme.bg : Theme.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(line.isTx
                                  ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                                  : AnyShapeStyle(toMe ? Theme.tx.opacity(0.22) : Theme.cardHi))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(toMe ? Theme.tx.opacity(0.7) : .clear, lineWidth: 1)
                    )
                    .opacity(line.isComplete || line.isTx ? 1 : 0.9)
            }
            if !line.isTx { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 10)
    }
}

/// Directed command shortcuts, as in JS8Call's query menu.
struct QueryCommandMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String

    private let commands: [(String, String, Bool)] = [
        ("SNR?", "What is my signal report?", true),
        ("GRID?", "What is your grid?", true),
        ("INFO?", "What is your station info?", true),
        ("STATUS?", "What is your status?", true),
        ("HEARING?", "Who are you hearing?", true),
        ("QUERY MSGS", "Do you have messages for me?", true),
        ("AGN?", "Please repeat", true),
        ("HW CPY?", "How do you copy?", true),
        ("QSL?", "Did you copy?", true),
        ("ACK", "Acknowledge", true),
        ("NACK", "Negative acknowledge", true),
        ("RR", "Roger roger", true),
        ("QSL", "I copy", true),
        ("FB", "Fine business", true),
        ("YES", "Yes", true),
        ("NO", "No", true),
        ("73", "Best regards", true),
        ("SK", "End of contact", true),
    ]

    var body: some View {
        Menu {
            Section("Send now to \(model.selectedCallsign.isEmpty ? "selected station" : model.selectedCallsign)") {
                ForEach(commands, id: \.0) { c in
                    Button {
                        model.send(c.0)
                    } label: {
                        Text("\(c.0)  —  \(c.1)")
                    }
                    .disabled(model.selectedCallsign.isEmpty)
                }
            }
            Section("Insert") {
                Button("MSG (store in their inbox)") { text = "MSG " }
                Button("MSG TO: (relay via station)") { text = "MSG TO:" }
                Button("QUERY MSG <id>") { text = "QUERY MSG " }
                Button("QUERY CALL <call>") { text = "QUERY CALL " }
                Button("Relay  CALL>…") { text = ">" }
                Button("SNR report") {
                    if let cd = model.calls.first(where: { $0.call == model.selectedCallsign }) {
                        text = "SNR \(Varicode.formatSNR(cd.snr))"
                    }
                }
                Button("GRID \(model.settings.station.grid.prefix(4))") { text = "GRID \(model.settings.station.grid)" }
                Button("Reply: \(model.settings.station.replyMessage)") { text = model.settings.station.replyMessage }
            }
            Section("To group") {
                ForEach(["@ALLCALL", "@HB"] + model.settings.station.groups, id: \.self) { g in
                    Button(g) { model.selectedCallsign = g }
                }
            }
        } label: {
            Image(systemName: "command.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

/// Message composer with selected-callsign pill, live frame preview and controls.
struct ComposeBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let text = model.draft
        VStack(spacing: 8) {
            if !model.pendingReplies.isEmpty {
                ForEach(model.pendingReplies) { r in
                    HStack {
                        Image(systemName: "questionmark.bubble.fill").foregroundStyle(Theme.warn)
                        Text("Auto-reply: \(r.message.message)").font(Theme.mono(12)).lineLimit(2)
                        Spacer()
                        Button("Send") { model.approve(r) }.buttonStyle(.borderedProminent).tint(Theme.rx)
                        Button { model.reject(r) } label: { Image(systemName: "xmark") }.buttonStyle(.bordered)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warn.opacity(0.12)))
                }
            }
            if model.isTransmitting || model.queuedFrames > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.right")
                        .foregroundStyle(Theme.tx)
                        .symbolEffect(.variableColor.iterative, isActive: model.isTransmitting)
                    Text(model.isTuning ? "TUNING" : (model.txText.isEmpty ? "Waiting for next period…" : model.txText))
                        .font(Theme.mono(12, .semibold))
                        .foregroundStyle(Theme.tx)
                        .lineLimit(1)
                    if model.queuedFrames > 0 {
                        Chip(text: "+\(model.queuedFrames) frames", color: Theme.tx)
                    }
                    Spacer()
                    Button {
                        model.halt()
                    } label: {
                        Label("Halt", systemImage: "stop.fill").font(Theme.rounded(12, .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.tx)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.tx.opacity(0.12)))
            }

            HStack(spacing: 8) {
                QueryCommandMenu(text: $model.draft)

                HStack(spacing: 6) {
                    if !model.selectedCallsign.isEmpty {
                        Button {
                            model.selectedCallsign = ""
                        } label: {
                            HStack(spacing: 3) {
                                Text(model.selectedCallsign).font(Theme.mono(12, .bold))
                                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.accent))
                            .foregroundStyle(Theme.bg)
                        }
                        .buttonStyle(.plain)
                    }
                    TextField(model.selectedCallsign.isEmpty ? "Message (CQ, free text…)" : "Message to \(model.selectedCallsign)",
                              text: $model.draft, axis: .vertical)
                        .font(Theme.mono(15))
                        .lineLimit(1...4)
                        .focused($focused)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        #endif
                        .onSubmit(send)
                        .onChange(of: model.draft) { _, new in
                            let up = new.uppercased()
                            if up != new { model.draft = up }
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.cardHi))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(focused ? Theme.accent.opacity(0.6) : Theme.stroke))

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(text.isEmpty || !model.settings.txEnabled ? Theme.faint : Theme.accent)
                        .glow(text.isEmpty ? .clear : Theme.accent, radius: 6)
                }
                .buttonStyle(.plain)
                .disabled(text.isEmpty || !model.settings.txEnabled)
            }

            if !text.isEmpty {
                let frames = model.preview(text)
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up").font(.caption2)
                    Text("\(frames.count) frame\(frames.count == 1 ? "" : "s") • \(String(format: "%.0f", Double(frames.count * model.settings.submode.period))) s on air")
                    Text("→ " + frames.map(\.message).joined())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(Theme.mono(10))
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ControlStrip()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func send() {
        let t = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        model.draft = ""
        if !model.send(t) { model.draft = t }
    }
}

/// CQ / Heartbeat / Tune / TX-enable buttons.
struct ControlStrip: View {
    @Environment(AppModel.self) private var model
    @State private var showLevels = false

    var body: some View {
        HStack(spacing: 8) {
            ControlButton(title: "CQ", icon: "megaphone.fill", active: model.cqLoop, color: Theme.rx) {
                if model.settings.station.cqIntervalMinutes > 0 { model.toggleCQLoop() } else { model.sendCQ() }
            }
            ControlButton(title: "HB", icon: "heart.fill", active: model.heartbeatLoop, color: Theme.tx,
                          disabled: !model.settings.submode.canSendHeartbeat) {
                model.toggleHeartbeat()
            }
            ControlButton(title: model.isTuning ? "Stop" : "Tune", icon: "tuningfork", active: model.isTuning, color: Theme.warn) {
                model.isTuning ? model.stopTune() : model.startTune()
            }
            ControlButton(title: "Levels", icon: "slider.vertical.3", active: false, color: Theme.accent) {
                showLevels = true
            }
            ControlButton(title: "Auto", icon: "arrowshape.turn.up.left.2.fill", active: model.settings.station.autoReply, color: Theme.accent2) {
                model.settings.station.autoReply.toggle()
            }
            ControlButton(title: model.settings.txEnabled ? "TX On" : "TX Off", icon: "power", active: model.settings.txEnabled,
                          color: model.settings.txEnabled ? Theme.rx : Theme.tx) {
                model.settings.txEnabled.toggle()
                if !model.settings.txEnabled { model.halt() }
            }
        }
        .sheet(isPresented: $showLevels) {
            LevelsSheet().presentationDetents([.fraction(0.85), .large])
        }
    }
}

struct ControlButton: View {
    let title: String
    let icon: String
    let active: Bool
    let color: Color
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(Theme.rounded(10, .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(active ? Theme.bg : color)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(active ? color : color.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}

/// Store-and-forward inbox.
struct InboxView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Inbox", icon: "tray.full")
            if model.inbox.isEmpty {
                EmptyStateView(icon: "tray", title: "No messages",
                               subtitle: "Messages sent to you with MSG, and messages you hold for others (MSG TO:), appear here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.inbox) { m in
                            InboxRow(message: m)
                                .onTapGesture { model.markRead(m) }
                                .contextMenu {
                                    Button("Reply to \(m.from)") {
                                        model.selectedCallsign = m.from
                                        model.draft = "MSG "
                                    }
                                    Button("Delete", role: .destructive) { model.deleteMessage(m) }
                                }
                        }
                    }
                }
            }
        }
    }
}

struct InboxRow: View {
    let message: InboxMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Chip(text: label, color: color, filled: message.type == "UNREAD")
                Text(message.type == "STORE" ? "\(message.from) → \(message.to)" : message.from)
                    .font(Theme.mono(13, .bold)).foregroundStyle(Theme.text)
                Spacer()
                Text("#\(message.id)  " + Format.utcShort.string(from: message.utc) + "Z")
                    .font(Theme.mono(10)).foregroundStyle(Theme.faint)
            }
            Text(message.text).font(Theme.mono(14)).foregroundStyle(Theme.text).textSelection(.enabled)
            if !message.path.isEmpty && message.path.contains(">") {
                Text("via \(message.path)").font(Theme.mono(10)).foregroundStyle(Theme.dim)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardHi.opacity(0.7)))
    }

    private var label: String {
        switch message.type {
        case "UNREAD": return "NEW"
        case "STORE": return "HOLDING"
        case "DELIVERED": return "DELIVERED"
        default: return "READ"
        }
    }

    private var color: Color {
        switch message.type {
        case "UNREAD": return Theme.accent
        case "STORE": return Theme.warn
        case "DELIVERED": return Theme.rx
        default: return Theme.dim
        }
    }
}
