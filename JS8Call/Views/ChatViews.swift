import SwiftUI
import JS8Core
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The RX/TX conversation pane, styled as a chat.
struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
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
                        MessageBubble(line: line, eot: model.settings.station.eot, mycall: model.settings.station.callsign,
                                      watch: model.settings.watch(matching: line.text))
                            .id(line.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onValueChange(of: model.conversation.last?.text) { _ in
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
    @EnvironmentObject private var model: AppModel
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
                                      showSignal: true, onMyOffset: onMyOffset,
                                      watch: model.settings.watch(matching: line.text))
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
            .scrollDismissesKeyboard(.interactively)
            .onValueChange(of: model.bandConversation.last?.text) { _ in
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

enum Keyboard {
    /// Ends editing in whichever text field has focus.
    static func dismiss() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

extension View {
    /// A tap anywhere in this view also puts the keyboard away, without
    /// taking the tap from buttons, bubbles or the waterfall underneath.
    func dismissesKeyboardOnTap() -> some View {
        #if os(iOS)
        simultaneousGesture(TapGesture().onEnded { Keyboard.dismiss() })
        #else
        self
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
    @EnvironmentObject private var model: AppModel
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
    var watch: WatchItem?

    var body: some View {
        let toMe = !line.isTx && !mycall.isEmpty && line.text.contains(" \(mycall)")
        let watch = line.isTx ? nil : watch
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
                    if let watch { WatchTag(item: watch) }
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
                    .watchGlow(watch, since: line.date, cornerRadius: 16, fill: !toMe)
                    .opacity(line.isComplete || line.isTx ? 1 : 0.9)
            }
            if !line.isTx { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 10)
    }
}

/// Directed command shortcuts, as in JS8Call's query menu.
///
/// Kept short enough to fit on an iPhone without scrolling: the menu is rebuilt
/// whenever a decode arrives, and a rebuild throws a scrolled menu back to its
/// start, so anything below the fold was effectively unreachable on a busy band.
struct QueryCommandMenu: View {
    @EnvironmentObject private var model: AppModel
    @Binding var text: String

    /// The commands used most in a QSO, shown directly. Bare commands, so each row
    /// stays on one line and the whole menu fits without scrolling.
    private let primary = ["SNR?", "GRID?", "HW CPY?", "AGN?", "QSL?", "73"]

    /// Everything else, one level down in two short submenus, each short enough
    /// to fit without scrolling.
    private let questions = ["INFO?", "STATUS?", "HEARING?", "QUERY MSGS"]
    private let replies = ["ACK", "NACK", "RR", "QSL", "FB", "YES", "NO", "SK"]

    var body: some View {
        let target = model.selectedCallsign
        let noTarget = target.isEmpty
        let report = model.calls.first { $0.call == target }.map { Varicode.formatSNR($0.snr) } ?? ""
        Menu {
            Section(noTarget ? "Pick a station first" : "Send to \(target)") {
                Button {
                    model.send("SNR \(report)")
                } label: {
                    Text(report.isEmpty ? "Send SNR (not heard)" : "Send SNR \(report)")
                }
                .disabled(noTarget || report.isEmpty)
                ForEach(primary, id: \.self) { c in
                    Button(c) { model.send(c) }
                        .disabled(noTarget)
                }
                Menu("More questions") {
                    ForEach(questions, id: \.self) { c in
                        Button(c) { model.send(c) }
                            .disabled(noTarget)
                    }
                }
                Menu("Replies") {
                    ForEach(replies, id: \.self) { c in
                        Button(c) { model.send(c) }
                            .disabled(noTarget)
                    }
                }
            }
            Section {
                Menu("Insert into message") {
                    Button("MSG (store in their inbox)") { text = "MSG " }
                    Button("MSG TO: (relay via station)") { text = "MSG TO:" }
                    Button("QUERY MSG <id>") { text = "QUERY MSG " }
                    Button("QUERY CALL <call>") { text = "QUERY CALL " }
                    Button("Relay  CALL>…") { text = ">" }
                    Button("GRID \(model.settings.station.grid.prefix(4))") { text = "GRID \(model.settings.station.grid)" }
                    Button("Reply: \(model.settings.station.replyMessage)") { text = model.settings.station.replyMessage }
                }
                Menu("Talk to a group") {
                    ForEach(["@ALLCALL", "@HB"] + model.settings.station.groups, id: \.self) { g in
                        Button(g) { model.selectedCallsign = g }
                    }
                }
            }
        } label: {
            Image(systemName: "command.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
        }
        .menuOrder(.fixed)
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

/// Message composer with selected-callsign pill, live frame preview and controls.
struct ComposeBar: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
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
                        .transmitEffect(isActive: model.isTransmitting)
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
                        .onValueChange(of: model.draft) { new in
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

                #if os(iOS)
                if focused {
                    Button("Done") { focused = false }
                        .font(Theme.rounded(14, .semibold))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                }
                #endif
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

            #if os(macOS)
            if model.isTuning { TuneLevelBar() }
            #endif
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
    @EnvironmentObject private var model: AppModel
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
    @EnvironmentObject private var model: AppModel
    @State private var storeFor: StoreTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Inbox", icon: "tray.full", trailing: AnyView(
                Button { let sel = model.selectedCallsign; storeFor = StoreTarget(call: model.storeRecipientProblem(sel) == nil ? sel : "") } label: {
                    Label("Store Message", systemImage: "square.and.pencil")
                        .font(Theme.rounded(13, .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
            ))
            if model.inbox.isEmpty {
                EmptyStateView(icon: "tray", title: "No messages",
                               subtitle: "Messages sent to you with MSG, and messages you hold for others, appear here. Tap Store Message to leave one at your station for someone to pick up.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.inbox) { m in
                            InboxRow(message: m)
                                .onTapGesture { model.markRead(m) }
                                .contextMenu {
                                    let other = counterpart(m)
                                    Button("Reply to \(other)") {
                                        model.selectedCallsign = other
                                        model.draft = "MSG "
                                    }
                                    if model.storeRecipientProblem(other) == nil {
                                        Button("Store Message for \(other)…") { storeFor = StoreTarget(call: other) }
                                    }
                                    Button("Delete", role: .destructive) { model.deleteMessage(m) }
                                }
                        }
                    }
                }
            }
        }
        .sheet(item: $storeFor) { t in StoreMessageSheet(to: t.call) }
    }

    /// The other station on a message: the sender, or the recipient when it's
    /// one we stored ourselves.
    private func counterpart(_ m: InboxMessage) -> String {
        let me = model.settings.station.callsign.uppercased()
        return Varicode.baseCallsign(m.from) == Varicode.baseCallsign(me) && !m.to.isEmpty ? m.to : m.from
    }
}

/// Identifiable wrapper so a sheet can open pre-filled for a callsign.
struct StoreTarget: Identifiable {
    let id = UUID()
    var call: String
}

/// JS8Call's "Store Message" dialog: write a message that waits at this
/// station, nothing is transmitted now. The recipient is told it's waiting when
/// they heartbeat or send QUERY MSGS, and fetches it with QUERY MSG <id>.
struct StoreMessageSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var to: String
    @State private var text = ""
    @FocusState private var focus: Field?
    private enum Field { case to, text }

    private var cleanTo: String { to.trimmingCharacters(in: .whitespaces).uppercased() }
    /// Shown once they leave the To field, not while they're mid-callsign.
    private var problem: String? { cleanTo.isEmpty || focus == .to ? nil : model.storeRecipientProblem(cleanTo) }
    private var canSave: Bool {
        model.storeRecipientProblem(cleanTo) == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Callsign or @GROUP", text: $to)
                        .font(Theme.mono(15, .bold))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .focused($focus, equals: .to)
                        .onSubmit { focus = .text }
                        .onValueChange(of: to) { new in
                            let up = new.uppercased()
                            if up != new { to = up }
                        }
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(Theme.tx)
                    }
                } header: {
                    Text("To")
                }
                Section {
                    TextField("Message", text: $text, axis: .vertical)
                        .font(Theme.mono(15))
                        .lineLimit(3...8)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .focused($focus, equals: .text)
                        .onValueChange(of: text) { new in
                            let up = new.uppercased()
                            if up != new { text = up }
                        }
                } header: {
                    Text("Message")
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Store Message")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Store") {
                        model.storeMessage(for: cleanTo, text: text)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear { focus = cleanTo.isEmpty ? .to : .text }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }

    private var footer: String {
        let who = model.storeRecipientProblem(cleanTo) == nil ? cleanTo : "that station"
        let me = model.settings.station.callsign.isEmpty ? "you" : model.settings.station.callsign
        return "Nothing is sent now. The message waits in your Inbox as HOLDING. When \(who) sends a heartbeat or QUERY MSGS to \(me), Firefly replies that a message is waiting, and they pick it up with QUERY MSG. Keep Firefly running with auto-reply on so your station can answer."
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
