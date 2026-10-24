import Foundation

/// The JS8Call station state machine: band and call activity, message
/// buffering, directed command handling, auto-replies, heartbeats and the
/// transmit queue. Ported from JS8Call's mainwindow processing functions
/// (processDecodeEvent, processRxActivity, processCompoundActivity,
/// processBufferedActivity, processCommandActivity, processTxQueue,
/// prepareNextMessageFrame) so that the station behaves the same on air.
///
/// All methods must be called from one thread (the app uses the main actor).
public final class JS8Station {
    // MARK: Configuration and operator state

    public var config: StationConfig
    public var submode: JS8Submode = .normal
    public var dialFrequency: UInt64 = 14_078_000
    /// The selected audio offset (JS8Call's freq()).
    public var offset: Int = 1500
    public var selectedCallsign: String = ""
    /// Master transmit enable (JS8Call's "Enable TX" button).
    public var txEnabled = true
    /// Heartbeat networking mode (Mode > Enable Heartbeat Networking).
    public var heartbeatNetworking = true
    /// Seconds of transmit delay before the period boundary (PTT lead).
    public var txDelay: Double = 0.2

    public let inbox: Inbox
    public let clock: () -> Date

    // MARK: Observable state

    public private(set) var bandActivity: [Int: [ActivityDetail]] = [:]
    public private(set) var callActivity: [String: CallDetail] = [:]
    public private(set) var conversation: [ConversationLine] = []
    /// Every transmission heard anywhere in the passband, assembled per offset.
    /// The conversation pane only shows our offset and traffic directed to us.
    public private(set) var bandConversation: [ConversationLine] = []
    public private(set) var heardGraphOutgoing: [String: Set<String>] = [:]
    public private(set) var heardGraphIncoming: [String: Set<String>] = [:]
    public private(set) var pendingReplies: [PendingReply] = []
    public private(set) var txMessageQueue: [QueuedMessage] = []
    /// Text in the outgoing message box that has not been sent.
    public var draftText = ""

    public private(set) var isTransmitting = false
    public private(set) var currentTx: TxRequest?
    public private(set) var lastTxStart: Date?
    public private(set) var lastTxStop: Date?
    public private(set) var txFramesRemaining = 0
    public private(set) var txFramesSent = 0
    public private(set) var lastTxMessage = ""

    // Loops
    public private(set) var heartbeatLoopActive = false
    public private(set) var cqLoopActive = false
    private var nextHeartbeat: Date?
    private var nextCQ: Date?

    // MARK: Callbacks

    public var onNotify: ((StationNotification, String) -> Void)?
    public var onChange: (() -> Void)?

    // MARK: Private state

    private var messageBuffer: [Int: MessageBuffer] = [:]
    private var rxActivityQueue: [ActivityDetail] = []
    private var rxCommandQueue: [CommandDetail] = []
    private struct FrameKey: Hashable { let submode: JS8Submode; let frame: String }
    private var dupeCache: [FrameKey: Date] = [:]
    private var rxDirectedCache: [Int: (isAllcall: Bool, date: Date)] = [:]
    private var rxFrameBlockNumbers: [Int: Int] = [:]
    /// Open (unfinished) lines in bandConversation by offset; -1 keys our TX.
    private var bandOpenLines: [Int: Int] = [:]
    private var allcallReplies: [String: Date] = [:]
    private var txFrameQueue: [Varicode.Frame] = []
    private var totalTxMessage = ""
    private var nextFrame: Varicode.Frame?
    private var offsetBeforeAuto = 0
    private var rxDirty = false
    private var lastClosedMessageBufferOffset = 0

    public init(config: StationConfig, inbox: Inbox, clock: @escaping () -> Date = { Date() }) {
        self.config = config
        self.inbox = inbox
        self.clock = clock
    }

    // MARK: - Helpers

    var mycall: String { config.callsign.uppercased().qTrimmed() }
    var mygrid4: String { config.grid.qLeft(4) }

    func isAllCallIncluded(_ text: String) -> Bool { text.contains("@ALLCALL") || text.contains("@HB") }
    func isGroupCallIncluded(_ text: String) -> Bool { config.groups.contains(text) }

    public func isMyCallIncluded(_ text: String) -> Bool {
        let base = Varicode.baseCallsign(mycall)
        if base.isEmpty || !text.contains(base) { return false }
        let calls = Varicode.parseCallsigns(text)
        return calls.contains(base) || calls.contains(mycall)
    }

    public func isDirectedOffset(_ offset: Int) -> (Bool, Bool) {
        guard let e = rxDirectedCache[offset / 10 * 10], clock().timeIntervalSince(e.date) < 120 else { return (false, false) }
        return (true, e.isAllcall)
    }

    func markOffsetDirected(_ offset: Int, isAllcall: Bool) {
        let now = clock()
        rxDirectedCache[offset / 10 * 10] = (isAllcall, now)
        rxDirectedCache[offset / 10 * 10 + 10] = (isAllcall, now)
    }

    func clearOffsetDirected(_ offset: Int) {
        rxDirectedCache[offset / 10 * 10] = nil
        rxDirectedCache[offset / 10 * 10 + 10] = nil
    }

    public static func since(_ date: Date, now: Date) -> String {
        let delta = Int(now.timeIntervalSince(date))
        if delta >= 86400 { return "\(delta / 86400)d" }
        if delta >= 3600 { return "\(delta / 3600)h" }
        if delta >= 60 { return "\(delta / 60)m" }
        if delta >= 15 { return "\(delta - delta % 15)s" }
        return "now"
    }

    public func macroValues() -> [String: String] {
        var values: [String: String] = [
            "<MYCALL>": mycall,
            "<MYGRID4>": mygrid4,
            "<MYGRID12>": config.grid.qLeft(12),
            "<MYINFO>": config.info,
            "<MYCQ>": config.cqMessage,
            "<MYREPLY>": config.replyMessage,
            "<MYSTATUS>": config.status,
            "<MYVERSION>": "JS8 FIREFLY 1.0",
            "<MYIDLE>": "0M",
        ]
        if let cd = callActivity[selectedCallsign] {
            values["<CALL>"] = selectedCallsign
            values["<TDELTA>"] = "\(Int(1000 * cd.tdrift)) ms"
            if cd.snr > -31 { values["<SNR>"] = Varicode.formatSNR(cd.snr) }
        }
        for k in ["<MYINFO>", "<MYSTATUS>", "<MYCQ>", "<MYREPLY>"] {
            values[k] = replaceMacros(values[k] ?? "", values, prune: false)
        }
        return values
    }

    public func replaceMacros(_ text: String, _ values: [String: String]? = nil, prune: Bool) -> String {
        var out = text
        for (k, v) in (values ?? macroValues()).sorted(by: { $0.key < $1.key }) {
            out = out.replacingOccurrences(of: k, with: v.uppercased())
        }
        if prune {
            out = out.replacingOccurrences(of: "[<](?:[^>]+)[>]", with: "", options: .regularExpression)
        }
        return out
    }

    // MARK: - Receive

    /// Feed one decoded frame (JS8Call's processDecodeEvent).
    public func handleDecode(_ raw: JS8RawDecode, dial: UInt64? = nil) {
        let now = clock()
        let decoded = DecodedText(raw)
        let key = FrameKey(submode: decoded.submode, frame: decoded.frame)
        if let seen = dupeCache[key], now.timeIntervalSince(seen) < 0.5 * Double(decoded.submode.period) {
            return
        }
        dupeCache[key] = now
        rxDirty = true

        let freq = dial ?? dialFrequency
        var d = ActivityDetail()
        var cmd = CommandDetail()

        if !decoded.messageWords.isEmpty {
            let off = decoded.frequencyOffset
            if bandActivity[off] == nil {
                let range = decoded.submode.rxThreshold
                for prev in (off - range)...(off + range) where bandActivity[prev] != nil {
                    bandActivity[off] = bandActivity[prev]
                    bandActivity[prev] = nil
                    break
                }
            }

            d.isLowConfidence = decoded.isLowConfidence
            d.isCompound = decoded.isCompound
            d.isDirected = decoded.isDirectedMessage
            d.bits = decoded.bits
            d.dial = freq
            d.offset = off
            d.text = decoded.message
            d.utc = now
            d.snr = decoded.snr
            d.isBuffered = false
            d.submode = decoded.submode
            d.tdrift = decoded.dt

            if d.bits & Varicode.TransmissionType.first.rawValue != 0,
               hasExistingMessageBuffer(decoded.submode, d.offset, drift: true) != nil {
                messageBuffer[d.offset] = nil
            }

            if hasExistingMessageBuffer(decoded.submode, d.offset, drift: true) != nil,
               !decoded.isCompound, !decoded.isDirectedMessage {
                d.isBuffered = true
                messageBuffer[d.offset]?.msgs.append(d)
            }

            rxActivityQueue.append(d)
            bandActivity[off, default: []].append(d)
            while bandActivity[off]!.count > 10 { bandActivity[off]!.removeFirst() }
        }

        if decoded.isCompound && !decoded.isDirectedMessage {
            var cd = CallDetail()
            cd.call = decoded.compoundCall
            cd.grid = decoded.extra
            cd.snr = decoded.snr
            cd.dial = freq
            cd.offset = decoded.frequencyOffset
            cd.utc = now
            cd.bits = decoded.bits
            cd.submode = decoded.submode
            cd.tdrift = decoded.dt

            if decoded.isHeartbeat {
                cmd.from = cd.call
                cmd.snr = cd.snr
                cmd.bits = cd.bits
                cmd.grid = cd.grid
                cmd.dial = cd.dial
                cmd.offset = cd.offset
                cmd.utc = cd.utc
                cmd.tdrift = cd.tdrift
                cmd.submode = cd.submode
                if decoded.isAlt {
                    cmd.to = "@ALLCALL"
                    cmd.cmd = " CQ"
                    cmd.text = decoded.message
                    rxCommandQueue.append(cmd)
                    onNotify?(.cq, cd.call)
                } else {
                    cmd.to = "@HB"
                    cmd.cmd = " HEARTBEAT"
                    rxCommandQueue.append(cmd)
                    onNotify?(.hb, cd.call)
                }
            } else {
                _ = hasExistingMessageBuffer(cd.submode, cd.offset, drift: true)
                messageBuffer[cd.offset, default: MessageBuffer()].compound.append(cd)
            }
        }

        if decoded.isDirectedMessage {
            let parts = decoded.directed
            cmd = CommandDetail()
            cmd.from = parts[0]
            cmd.to = parts[1]
            cmd.cmd = parts[2]
            cmd.dial = freq
            cmd.offset = decoded.frequencyOffset
            cmd.snr = decoded.snr
            cmd.utc = now
            cmd.bits = decoded.bits
            cmd.extra = parts.count > 2 ? Array(parts.dropFirst(3)).joined(separator: " ") : ""
            cmd.submode = decoded.submode
            cmd.tdrift = decoded.dt

            if (Varicode.isCommandBuffered(cmd.cmd) && cmd.bits & Varicode.TransmissionType.last.rawValue == 0) ||
                cmd.from == "<....>" || cmd.to == "<....>" {
                if cmd.from != "<....>" && cmd.to != "<....>" {
                    var cd = CallDetail()
                    cd.call = cmd.from
                    cd.bits = cmd.bits
                    cd.snr = cmd.snr
                    cd.dial = cmd.dial
                    cd.offset = cmd.offset
                    cd.utc = now
                    cd.ackTimestamp = cmd.to == mycall ? now : nil
                    cd.tdrift = cmd.tdrift
                    cd.submode = cmd.submode
                    logCallActivity(cd)
                    logHeardGraph(cmd.from, cmd.to)
                }
                _ = hasExistingMessageBuffer(cmd.submode, cmd.offset, drift: true)
                var buffer = messageBuffer[cmd.offset] ?? MessageBuffer()
                buffer.cmd = cmd
                buffer.msgs.removeAll()
                messageBuffer[cmd.offset] = buffer
            } else {
                rxCommandQueue.append(cmd)
            }
        }
        onChange?()
    }

    @discardableResult
    private func hasExistingMessageBuffer(_ submode: JS8Submode, _ offset: Int, drift: Bool) -> Int? {
        if messageBuffer[offset] != nil { return offset }
        let range = submode.rxThreshold
        for prev in (offset - range)...(offset + range) where messageBuffer[prev] != nil {
            if drift {
                messageBuffer[offset] = messageBuffer[prev]
                messageBuffer[prev] = nil
            }
            return prev
        }
        return nil
    }

    private func hasExistingMessageBufferToMe() -> Bool {
        messageBuffer.values.contains { b in
            b.cmd.utc != nil && (b.cmd.to == mycall || b.cmd.to == Varicode.baseCallsign(mycall))
        }
    }

    func logCallActivity(_ dIn: CallDetail) {
        var d = dIn
        if d.call.qTrimmed().isEmpty || d.call.contains(">") { return }
        if let old = callActivity[d.call] {
            if d.grid.isEmpty && !old.grid.isEmpty { d.grid = old.grid }
            if d.ackTimestamp == nil { d.ackTimestamp = old.ackTimestamp }
            if d.cqTimestamp == nil { d.cqTimestamp = old.cqTimestamp }
            callActivity[d.call] = d
        } else {
            callActivity[d.call] = d
            onNotify?(.newCall, d.call)
        }
    }

    func logHeardGraph(_ from: String, _ to: String) {
        heardGraphOutgoing[mycall, default: []].insert(from)
        heardGraphIncoming[from, default: []].insert(mycall)
        if to == "@ALLCALL" { return }
        heardGraphOutgoing[from, default: []].insert(to)
        heardGraphIncoming[to, default: []].insert(from)
    }

    // MARK: - Periodic processing

    /// Call about once per second.
    public func tick() {
        let now = clock()
        processActivity()
        processLoops(now: now)
        processTxQueue()
        pendingReplies.removeAll { $0.expires < now }
        dupeCache = dupeCache.filter { now.timeIntervalSince($0.value) <= Double($0.key.submode.period) }
        onChange?()
    }

    public func processActivity() {
        processRxActivity()
        processIdleActivity()
        processCompoundActivity()
        processBufferedActivity()
        processCommandActivity()
        rxDirty = false
    }

    func processRxActivity() {
        while !rxActivityQueue.isEmpty {
            var d = rxActivityQueue.removeFirst()
            var shouldDisplay = abs(d.offset - offset) <= d.submode.rxThreshold

            if let prev = hasExistingMessageBuffer(d.submode, d.offset, drift: false),
               let buffer = messageBuffer[prev],
               buffer.cmd.to == mycall || isGroupCallIncluded(buffer.cmd.to) {
                d.isBuffered = true
                shouldDisplay = true
                if let last = buffer.compound.last {
                    d.text = "\(last.call): \(d.text)"
                    d.utc = min(d.utc, last.utc)
                }
            } else if d.isDirected && d.text.contains("<....>") {
                continue
            } else if d.isDirected && (d.text.contains(": HB ") || d.text.contains(": @ALLCALL HB")) {
                continue
            }

            logBandText(d.text, offset: d.offset, date: d.utc, snr: d.snr, submode: d.submode, bits: d.bits, isTx: false)

            if d.bits & Varicode.TransmissionType.first.rawValue != 0 && !d.isDirected && !d.isCompound {
                let calls = Varicode.parseCallsigns(d.text)
                if let theirCall = calls.first, d.text.hasPrefix(theirCall), d.text.qMid(theirCall.u16Count, 1) == ":" {
                    var cd = CallDetail()
                    cd.call = theirCall
                    cd.dial = d.dial
                    cd.offset = d.offset
                    cd.snr = d.snr
                    cd.bits = d.bits
                    cd.tdrift = d.tdrift
                    cd.utc = d.utc
                    cd.submode = d.submode
                    logCallActivity(cd)
                }
            }

            if !shouldDisplay { continue }

            let isFirst = d.bits & Varicode.TransmissionType.first.rawValue != 0
            let isLast = d.bits & Varicode.TransmissionType.last.rawValue != 0
            if isLast { d.text = "\(Varicode.rstrip(d.text)) \(config.eot) " }

            displayText(d.text, offset: d.offset, date: d.utc, isTx: false, isNewLine: isFirst, isLast: isLast)

            if !isAllCallIncluded(d.text) { cancelCQLoop() }
            if isLast { clearOffsetDirected(d.offset) }
            if isLast && !d.isBuffered { rxFrameBlockNumbers[d.offset] = nil }
        }
    }

    func processIdleActivity() {
        let now = clock()
        for (off, activity) in bandActivity {
            guard let last = activity.last else { continue }
            if last.bits & Varicode.TransmissionType.last.rawValue != 0 { continue }
            if last.text == config.mfi { continue }
            if now.timeIntervalSince(last.utc) < Double(last.submode.period) * 1.5 { continue }

            var d = ActivityDetail()
            d.text = config.mfi
            d.utc = last.utc
            d.snr = last.snr
            d.tdrift = last.tdrift
            d.dial = last.dial
            d.offset = last.offset
            d.submode = last.submode
            if hasExistingMessageBuffer(d.submode, off, drift: false) != nil {
                messageBuffer[off]?.msgs.append(d)
            }
            rxActivityQueue.append(d)
            bandActivity[off]?.append(d)
        }
    }

    func processCompoundActivity() {
        for freq in Array(messageBuffer.keys) {
            guard var buffer = messageBuffer[freq], !buffer.compound.isEmpty else { continue }
            let bits = buffer.cmd.bits
            let validBits = bits == 0 || bits & 1 != 0 || bits & 2 != 0 || bits & 4 != 0
            if !validBits { continue }
            if buffer.cmd.from == "<....>" && buffer.cmd.to == "<....>" && buffer.compound.count < 2 { continue }
            if (buffer.cmd.from == "<....>" || buffer.cmd.to == "<....>") && buffer.compound.isEmpty { continue }

            if buffer.cmd.from == "<....>" {
                let d = buffer.compound.removeFirst()
                buffer.cmd.from = d.call
                buffer.cmd.grid = d.grid
                buffer.cmd.isCompound = true
                buffer.cmd.utc = minDate(buffer.cmd.utc, d.utc)
                if d.bits & Varicode.TransmissionType.last.rawValue != 0 { buffer.cmd.bits = d.bits }
            }
            if buffer.cmd.to == "<....>" {
                let d = buffer.compound.removeFirst()
                buffer.cmd.to = d.call
                buffer.cmd.isCompound = true
                buffer.cmd.utc = minDate(buffer.cmd.utc, d.utc)
                if d.bits & Varicode.TransmissionType.last.rawValue != 0 { buffer.cmd.bits = d.bits }
            }
            messageBuffer[freq] = buffer

            if buffer.cmd.bits & Varicode.TransmissionType.last.rawValue == 0 { continue }

            var dt = buffer.cmd.utc
            for c in buffer.compound { dt = minDate(dt, c.utc) }
            for m in buffer.msgs { dt = minDate(dt, m.utc) }
            buffer.cmd.utc = dt

            rxCommandQueue.append(buffer.cmd)
            messageBuffer[freq] = nil
            lastClosedMessageBufferOffset = freq
        }
    }

    private func minDate(_ a: Date?, _ b: Date) -> Date { a.map { min($0, b) } ?? b }

    func processBufferedActivity() {
        let now = clock()
        for freq in Array(messageBuffer.keys) {
            guard var buffer = messageBuffer[freq] else { continue }
            var dt = now.addingTimeInterval(-86400)
            if let u = buffer.cmd.utc { dt = max(dt, u) }
            if let c = buffer.compound.last { dt = max(dt, c.utc) }
            if let m = buffer.msgs.last { dt = max(dt, m.utc) }
            let age = now.timeIntervalSince(dt)

            if age > 60 && !buffer.msgs.isEmpty {
                buffer.msgs[buffer.msgs.count - 1].bits |= Varicode.TransmissionType.last.rawValue
                messageBuffer[freq] = buffer
            }
            if age > 90 {
                messageBuffer[freq] = nil
                continue
            }
            if buffer.msgs.isEmpty { continue }
            if buffer.msgs.last!.bits & Varicode.TransmissionType.last.rawValue == 0 { continue }

            var message = Varicode.rstrip(buffer.msgs.map(\.text).joined())
            var valid = false
            if Varicode.isCommandBuffered(buffer.cmd.cmd) {
                let size = Varicode.isCommandChecksumed(buffer.cmd.cmd)
                if size == 32 {
                    message = Varicode.lstrip(message)
                    let checksum = message.qRight(6)
                    message = message.qLeft(message.u16Count - 7)
                    valid = Varicode.checksum32Valid(checksum, message)
                } else if size == 16 {
                    message = Varicode.lstrip(message)
                    let checksum = message.qRight(3)
                    message = message.qLeft(message.u16Count - 4)
                    valid = Varicode.checksum16Valid(checksum, message)
                } else {
                    valid = true
                }
            } else {
                valid = true
            }

            if valid {
                buffer.cmd.bits |= Varicode.TransmissionType.last.rawValue
                buffer.cmd.text = message
                buffer.cmd.isBuffered = true
                rxCommandQueue.append(buffer.cmd)
            }
            messageBuffer[freq] = nil
            lastClosedMessageBufferOffset = freq
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func processCommandActivity() {
        let now = clock()
        while !rxCommandQueue.isEmpty {
            var d = rxCommandQueue.removeFirst()
            let isAllCall = isAllCallIncluded(d.to)
            let isGroupCall = isGroupCallIncluded(d.to) || d.to == "@APRSIS"

            if d.from == "<....>" || d.to == "<....>" { continue }
            if !Varicode.isCommandAllowed(d.cmd) { continue }

            let toMe = d.to == mycall || d.to == Varicode.baseCallsign(mycall)

            var cd = CallDetail()
            cd.call = d.from
            cd.grid = d.grid
            cd.snr = d.snr
            cd.dial = d.dial
            cd.offset = d.offset
            cd.bits = d.bits
            cd.ackTimestamp = d.text.contains(": ACK") || toMe ? d.utc : nil
            cd.utc = d.utc ?? now
            cd.tdrift = d.tdrift
            cd.submode = d.submode
            logCallActivity(cd)
            logHeardGraph(d.from, d.to)

            var onSent: (@Sendable () -> Void)?

            if d.cmd == " HEARING" {
                for call in Varicode.parseCallsigns(d.text) { logHeardGraph(d.from, call) }
            }
            if d.cmd == " GRID" {
                for grid in Varicode.parseGrids(d.text) {
                    var g = CallDetail()
                    g.bits = d.bits
                    g.call = d.from
                    g.dial = d.dial
                    g.offset = d.offset
                    g.grid = grid
                    g.snr = d.snr
                    g.utc = d.utc ?? now
                    g.tdrift = d.tdrift
                    g.submode = d.submode
                    logCallActivity(g)
                }
            }

            var baseList = ["\(d.to)\(d.cmd)"]
            if !d.extra.isEmpty { baseList.append(d.extra) }
            if !d.text.isEmpty { baseList.append(d.text) }
            var baseText = baseList.joined(separator: " ")
            if d.bits & Varicode.TransmissionType.last.rawValue != 0 {
                baseText = "\(Varicode.rstrip(baseText)) \(config.eot) "
            }
            let text = "\(d.from): \(baseText)"

            if isAllCall && config.avoidAllcall && d.cmd != " CQ" && d.cmd != " HB" && d.cmd != " HEARTBEAT" { continue }
            if !isAllCall && !toMe && !isGroupCall { continue }

            var shouldDisplay = true
            if isAllCall && (d.cmd != " " || text.contains("@HB HEARTBEAT")) { shouldDisplay = false }
            if shouldDisplay {
                displayText(text, offset: d.offset, date: d.utc ?? now, isTx: false, isNewLine: true, isLast: false,
                            replaceSameSender: !d.cmd.contains(" ACK") && !d.cmd.contains(" SNR") ? d.from : nil)
                if !isAllCall {
                    cancelCQLoop()
                    onNotify?(.directed, text)
                }
            }

            if !config.autoWhitelist.isEmpty &&
                !(config.autoWhitelist.contains(d.from) || config.autoWhitelist.contains(Varicode.baseCallsign(d.from))) {
                continue
            }
            if config.autoBlacklist.contains(d.from) || config.autoBlacklist.contains(Varicode.baseCallsign(d.from)) {
                continue
            }
            if isAllCall, let last = allcallReplies[d.from], now.timeIntervalSince(last) / 60 < 55 { continue }

            if Varicode.isCommandAutoreply(d.cmd) && !d.relayPath.isEmpty && !d.cmd.hasPrefix(" MSG") && !d.cmd.hasPrefix(" QUERY") {
                d.from = d.relayPath
            }

            var reply = ""
            let priority = Priority.normal
            let freq = -1

            if d.cmd == " SNR?" && !isAllCall {
                reply = "\(d.from) SNR \(Varicode.formatSNR(d.snr))"
            } else if d.cmd == " INFO?" && !isAllCall {
                if config.info.isEmpty { continue }
                reply = "\(d.from) INFO \(replaceMacros(config.info, prune: true))"
            } else if d.cmd == " STATUS?" && !isAllCall {
                if config.status.isEmpty { continue }
                reply = "\(d.from) STATUS \(replaceMacros(config.status, prune: true))"
            } else if d.cmd == " GRID?" && !isAllCall {
                if config.grid.isEmpty { continue }
                reply = "\(d.from) GRID \(config.grid)"
            } else if d.cmd == " HEARING?" && !isAllCall {
                let calls = callActivity.keys.sorted { (callActivity[$0]!.utc) > (callActivity[$1]!.utc) }
                var lines: [String] = []
                for call in calls where lines.count < 4 && call != d.from {
                    let c = callActivity[call]!
                    if config.callsignAgingMinutes > 0 && now.timeIntervalSince(c.utc) / 60 >= Double(config.callsignAgingMinutes) { continue }
                    lines.append(c.call)
                }
                reply = (["\(d.from) HEARING"] + lines).joined(separator: " ")
            } else if d.cmd == ">" && !isAllCall && !config.relayOff {
                let pattern = #"^(?<callsign>\b(?<prefix>[A-Z0-9]{1,4}\/)?(?<base>([0-9A-Z])?([0-9A-Z])([0-9])([A-Z])?([A-Z])?([A-Z])?)(?<suffix>\/[A-Z0-9]{1,4})?(?<type>[> ]))\b"#
                var relayText = d.text
                if let m = QRegex(pattern).match(relayText), !isGroupCall {
                    if m.captured("type") != ">" {
                        let ns = relayText as NSString
                        relayText = ns.replacingCharacters(in: NSRange(location: m.capturedStart("type"), length: m.capturedLength("type")), with: ">")
                    }
                    reply = "\(relayText) *DE* \(d.from)"
                } else if !d.text.hasPrefix("ACK") {
                    let calls = Self.parseRelayPathCallsigns(d.from, d.text)
                    for call in calls {
                        var r = CallDetail()
                        r.call = call
                        r.snr = -64
                        r.dial = d.dial
                        r.offset = d.offset
                        r.through = d.from
                        r.utc = now
                        r.tdrift = d.tdrift
                        r.submode = d.submode
                        logCallActivity(r)
                    }
                    d.relayPath = calls.joined(separator: ">")
                    reply = "\(d.relayPath) ACK"

                    var relayed = d.text.components(separatedBy: " ")
                    if var first = relayed.first {
                        var valid = Varicode.isCommandAllowed(first)
                        if !valid {
                            first = " " + first
                            valid = Varicode.isCommandAllowed(first)
                            if valid { relayed.removeFirst() }
                        }
                        if !relayed.isEmpty {
                            if first == " MSG" {
                                let second = relayed[0]
                                if second == "TO:" {
                                    first = " MSG TO:"
                                    relayed.removeFirst()
                                } else if second.hasPrefix("TO:") {
                                    first = " MSG TO:"
                                    relayed[0] = String(second.dropFirst(3))
                                }
                            } else if first == " QUERY" {
                                let second = relayed[0]
                                if second == "MSGS" || second == "MSGS?" {
                                    first = " QUERY MSGS"
                                    relayed.removeFirst()
                                } else if second == "CALL" {
                                    first = " QUERY CALL"
                                    relayed.removeFirst()
                                }
                            }
                        }
                        if Varicode.isCommandAllowed(first) && Varicode.isCommandAutoreply(first) {
                            var rd = CommandDetail()
                            rd.bits = d.bits
                            rd.cmd = first
                            rd.dial = d.dial
                            rd.offset = d.offset
                            rd.from = d.from
                            rd.relayPath = d.relayPath
                            rd.text = relayed.joined(separator: " ")
                            rd.to = d.to
                            rd.utc = d.utc
                            rxCommandQueue.insert(rd, at: 0)
                            continue
                        }
                    }
                }
            } else if d.cmd == " MSG TO:" && !isAllCall {
                var segs = d.text.components(separatedBy: " ")
                if segs.isEmpty { continue }
                let to = segs.removeFirst()
                let msgText = segs.joined(separator: " ").qTrimmed()
                if d.to == "@APRSIS" || config.relayOff { continue }
                let calls = Self.parseRelayPathCallsigns(d.from, msgText)
                d.relayPath = calls.joined(separator: ">")
                var store = d
                store.text = msgText
                store.to = Varicode.baseCallsign(to)
                inbox.append(type: "STORE", store)
                reply = "\(calls.count > 1 ? d.relayPath : d.from) ACK"
            } else if d.cmd == " AGN?" && !isAllCall && !isGroupCall && !lastTxMessage.isEmpty {
                reply = Varicode.rstrip(lastTxMessage)
            } else if (d.cmd == " HB" || d.cmd == " HEARTBEAT") && submode.canSendHeartbeat && heartbeatNetworking &&
                        config.autoReply && config.heartbeatAcknowledgements {
                if !messageBuffer.isEmpty { continue }
                if config.heartbeatQSOPause && !selectedCallsign.isEmpty { continue }
                if config.hbBlacklist.contains(d.from) || config.hbBlacklist.contains(Varicode.baseCallsign(d.from)) { continue }

                var extra = ""
                var mid = inbox.nextMessageId(for: d.from)
                var pending = inbox.countUnread(for: d.from)
                if isGroupCall { pending += inbox.countGroupUnread(d.to, for: d.from, now: now) }
                pending -= 1
                if mid != -1 {
                    extra = pending > 0 ? "MSG ID \(mid) +\(pending))" : "MSG ID \(mid)"
                } else if isGroupCall {
                    mid = inbox.nextGroupMessageId(d.to, for: d.from, now: now)
                    if mid != -1 { extra = pending > 0 ? "MSG ID \(mid) +\(pending))" : "MSG ID \(mid)" }
                }
                sendHeartbeatAck(to: d.from, snr: d.snr, extra: extra)
                if isAllCall { allcallReplies[d.from] = now }
                continue
            } else if d.cmd == " HEARTBEAT SNR" {
                continue
            } else if d.cmd == " CQ" {
                var c = CallDetail()
                c.bits = d.bits
                c.call = d.from
                c.dial = d.dial
                c.offset = d.offset
                c.grid = d.grid
                c.snr = d.snr
                c.tdrift = d.tdrift
                c.submode = d.submode
                c.utc = d.utc ?? now
                c.cqTimestamp = d.utc ?? now
                logCallActivity(c)
                logHeardGraph(d.from, d.to)
                continue
            } else if d.cmd == " MSG" && !isAllCall {
                if d.to == "@APRSIS" { continue }
                let calls = Self.parseRelayPathCallsigns(d.from, d.text)
                d.cmd = " MSG "
                d.relayPath = calls.joined(separator: ">")
                inbox.append(type: "UNREAD", d)
                onNotify?(.inbox, "\(d.from): \(d.text)")
                reply = "\(calls.count > 1 ? d.relayPath : d.from) ACK"
            } else if d.cmd == " ACK" && !isAllCall {
                onNotify?(.ack, d.from)
                continue
            } else if d.cmd == " CMD" && !isAllCall {
                continue
            } else if d.cmd == " QUERY" && !isAllCall {
                var who = d.from
                var replyPath = d.from
                if d.relayPath.contains(">") {
                    who = d.relayPath.components(separatedBy: ">").last ?? d.from
                    replyPath = d.relayPath
                }
                var segs = d.text.components(separatedBy: " ")
                if segs.isEmpty { continue }
                let qcmd = segs.removeFirst()
                if qcmd == "MSG" && !segs.isEmpty {
                    guard let mid = Int(segs[0]), let msg = inbox.message(mid) else { continue }
                    let from = msg.from.qTrimmed()
                    let to = msg.to.qTrimmed()
                    let isGroupMsg = to.hasPrefix("@")
                    if !isGroupMsg && to != who && to != Varicode.baseCallsign(who) { continue }
                    let msgText = msg.text.qTrimmed()
                    if msgText.isEmpty { continue }
                    let inboxRef = inbox
                    if !isGroupMsg {
                        onSent = { inboxRef.setType(mid, "DELIVERED") }
                    } else {
                        let whoCopy = who
                        onSent = { inboxRef.markGroupDelivered(mid, to: whoCopy) }
                    }
                    var pending = inbox.countUnread(for: who)
                    if isGroupCall { pending += inbox.countGroupUnread(d.to, for: who, now: now) }
                    pending -= 2
                    var look = inbox.lookaheadMessageId(for: who, after: mid)
                    if look == -1 && isGroupMsg { look = inbox.lookaheadGroupMessageId(d.to, for: who, after: mid, now: now) }
                    if look != -1 {
                        reply = pending > 0
                            ? "\(replyPath) MSG \(msgText) FROM \(from) NEXT MSG ID \(look) +\(pending)"
                            : "\(replyPath) MSG \(msgText) FROM \(from) NEXT MSG ID \(look)"
                    } else {
                        reply = "\(replyPath) MSG \(msgText) FROM \(from)"
                    }
                }
            } else if d.cmd == " QUERY MSGS" && config.autoReply {
                var who = d.from
                var replyPath = d.from
                if d.relayPath.contains(">") {
                    who = d.relayPath.components(separatedBy: ">").last ?? d.from
                    replyPath = d.relayPath
                }
                var mid = inbox.nextMessageId(for: who)
                var pending = inbox.countUnread(for: who)
                if isGroupCall { pending += inbox.countGroupUnread(d.to, for: d.from, now: now) }
                pending -= 1
                if mid != -1 {
                    reply = pending > 0 ? "\(replyPath) YES MSG ID \(mid) +\(pending)" : "\(replyPath) YES MSG ID \(mid)"
                } else if isGroupCall {
                    mid = inbox.nextGroupMessageId(d.to, for: d.from, now: now)
                    if mid != -1 {
                        reply = pending > 0 ? "\(replyPath) YES MSG ID \(mid) +\(pending)" : "\(replyPath) YES MSG ID \(mid)"
                    }
                }
                if !isAllCall && reply.isEmpty { reply = "\(replyPath) NO" }
            } else if d.cmd == " QUERY CALL" && config.autoReply {
                var replyPath = d.from
                if d.relayPath.contains(">") { replyPath = d.relayPath }
                if d.text.isEmpty { continue }
                let calls = Varicode.parseCallsigns(d.text)
                guard let baseCall = calls.first else { continue }
                var replies: [String] = []
                for c in callActivity.values {
                    if config.callsignAgingMinutes > 0 && now.timeIntervalSince(c.utc) / 60 >= Double(config.callsignAgingMinutes) { continue }
                    if baseCall == c.call || baseCall == Varicode.baseCallsign(c.call) {
                        replies.append("\(Varicode.formatSNR(c.snr)) (\(Self.since(c.utc, now: now)))".qTrimmed())
                        break
                    }
                }
                if !replies.isEmpty { replies.insert("\(replyPath) YES", at: 0) }
                reply = replies.joined(separator: " ")
            }

            if reply.isEmpty { continue }
            if !config.autoReply && isAllCall { continue }
            if !draftText.isEmpty { continue }
            if hasExistingMessageBufferToMe() { continue }
            if isAllCall { allcallReplies[d.from] = now }

            let message = QueuedMessage(date: now, priority: priority, message: reply, offset: freq, onSent: onSent)
            if config.autoReplyConfirmation {
                pendingReplies.append(PendingReply(created: now, expires: now.addingTimeInterval(90), message: message))
            } else {
                enqueue(message)
            }
        }
    }

    static func parseRelayPathCallsigns(_ from: String, _ text: String) -> [String] {
        let pattern = #"\s([*]DE[*]|VIA)\s(?<callsign>\b(?<prefix>[A-Z0-9]{1,4}\/)?(?<base>([0-9A-Z])?([0-9A-Z])([0-9])([A-Z])?([A-Z])?([A-Z])?)(?<suffix>\/[A-Z0-9]{1,4})?)\b"#
        var calls: [String] = []
        for m in QRegex(pattern).globalMatch(text) { calls.insert(m.captured("callsign"), at: 0) }
        calls.insert(from, at: 0)
        return calls
    }

    // MARK: - Conversation display (displayTextForFreq)

    func displayText(_ text: String, offset freqIn: Int, date: Date, isTx: Bool, isNewLine: Bool, isLast: Bool,
                     replaceSameSender: String? = nil) {
        var freq = freqIn
        let low = freq / 10 * 10
        let high = low + 10
        var block: Int?
        if let b = rxFrameBlockNumbers[freq] {
            block = b
        } else if let b = rxFrameBlockNumbers[low] {
            block = b
            freq = low
        } else if let b = rxFrameBlockNumbers[high] {
            block = b
            freq = high
        }
        if isNewLine {
            rxFrameBlockNumbers[freq] = nil
            rxFrameBlockNumbers[low] = nil
            rxFrameBlockNumbers[high] = nil
            block = nil
        }

        // Duplicate ACK/HB SNR suppression.
        if (text.contains(" ACK ") || text.contains(" HEARTBEAT SNR ")),
           conversation.suffix(20).contains(where: { $0.text == text && abs($0.date.timeIntervalSince(date)) < 1 }) {
            return
        }
        // The same frame can reach the display both from the offset feed and as
        // a directed command; show it once.
        let trimmed = text.qTrimmed()
        if isNewLine, conversation.suffix(10).contains(where: { !$0.isTx && $0.date == date && $0.text.qTrimmed() == trimmed }) {
            return
        }
        if let sender = replaceSameSender,
           let idx = conversation.lastIndex(where: { !$0.isTx && $0.date == date && $0.text.hasPrefix("\(sender):") }) {
            conversation.remove(at: idx)
        }

        var index: Int
        if let b = block, b < conversation.count, !conversation[b].text.contains(config.eot) {
            conversation[b].text += text
            conversation[b].isComplete = isLast
            index = b
        } else {
            conversation.append(ConversationLine(date: date, offset: freq, text: text, isTx: isTx, isComplete: isLast))
            index = conversation.count - 1
        }
        if conversation.count > 2000 {
            let drop = conversation.count - 2000
            conversation.removeFirst(drop)
            index -= drop
            rxFrameBlockNumbers = rxFrameBlockNumbers.compactMapValues { $0 - drop >= 0 ? $0 - drop : nil }
        }

        if isLast {
            rxFrameBlockNumbers.removeAll()
        } else {
            rxFrameBlockNumbers[freq] = index
            rxFrameBlockNumbers[low] = index
            rxFrameBlockNumbers[high] = index
        }
    }

    public func clearConversation() {
        conversation.removeAll()
        rxFrameBlockNumbers.removeAll()
        onChange?()
    }

    /// Assemble frames into one line per transmission, for every offset.
    func logBandText(_ textIn: String, offset: Int, date: Date, snr: Int?, submode: JS8Submode, bits: Int, isTx: Bool) {
        let isFirst = bits & Varicode.TransmissionType.first.rawValue != 0
        let isLast = bits & Varicode.TransmissionType.last.rawValue != 0
        let isIdle = !isTx && textIn == config.mfi
        var text = textIn
        if isLast { text = "\(Varicode.rstrip(text)) \(config.eot) " }

        // Follow a stream that drifts a few Hz between frames.
        let key: Int? = isTx ? (bandOpenLines[-1] != nil ? -1 : nil) : bandOpenLines.keys
            .filter { $0 >= 0 && abs($0 - offset) <= submode.rxThreshold }
            .min { abs($0 - offset) < abs($1 - offset) }

        var index: Int
        if !isFirst, let k = key, let i = bandOpenLines[k], i < bandConversation.count, !bandConversation[i].isComplete {
            bandOpenLines[k] = nil
            bandConversation[i].text += text
            bandConversation[i].isComplete = isLast || isIdle
            if let snr { bandConversation[i].snr = snr }
            index = i
        } else {
            if let k = key { bandOpenLines[k] = nil }
            if isIdle { return }
            bandConversation.append(ConversationLine(date: date, offset: offset, text: text, isTx: isTx, isComplete: isLast,
                                                     snr: snr, submode: submode))
            index = bandConversation.count - 1
        }
        if bandConversation.count > 1000 {
            let drop = bandConversation.count - 1000
            bandConversation.removeFirst(drop)
            index -= drop
            bandOpenLines = bandOpenLines.compactMapValues { $0 - drop >= 0 ? $0 - drop : nil }
        }
        if !isLast && !isIdle { bandOpenLines[isTx ? -1 : offset] = index }
    }

    public func clearBandConversation() {
        bandConversation.removeAll()
        bandOpenLines.removeAll()
        onChange?()
    }

    public func clearBandActivity() {
        bandActivity.removeAll()
        onChange?()
    }

    public func clearCallActivity() {
        callActivity.removeAll()
        onChange?()
    }

    // MARK: - Transmit queue

    public func enqueue(_ m: QueuedMessage) {
        txMessageQueue.append(m)
        txMessageQueue.sort { a, b in a.priority != b.priority ? a.priority > b.priority : a.date < b.date }
    }

    public func enqueue(priority: Int, message: String, offset: Int, onSent: (@Sendable () -> Void)? = nil) {
        enqueue(QueuedMessage(date: clock(), priority: priority, message: message, offset: offset, onSent: onSent))
    }

    public func approvePendingReply(_ id: UUID) {
        guard let i = pendingReplies.firstIndex(where: { $0.id == id }) else { return }
        enqueue(pendingReplies.remove(at: i).message)
        processTxQueue()
    }

    public func rejectPendingReply(_ id: UUID) {
        pendingReplies.removeAll { $0.id == id }
    }

    public var isMessageQueuedForTransmit: Bool { isTransmitting || txFramesRemaining > 0 || nextFrame != nil }

    func processTxQueue() {
        guard let head = txMessageQueue.first else { return }
        let f = head.offset == -1 ? offset : head.offset
        if f <= 0 { return }
        if !txFrameQueue.isEmpty { return }
        if !draftText.isEmpty { return }
        if isMessageQueuedForTransmit { return }

        let isAuto = head.priority >= Priority.high || head.message.contains(" HEARTBEAT ") ||
            head.message.contains(" HB ") || head.message.contains(" ACK ") || config.autoReply
        if isAuto && !txEnabled {
            txMessageQueue.removeFirst()
            return
        }
        if head.priority <= Priority.low, let last = lastTxStart, clock().timeIntervalSince(last) <= 30 {
            return
        }
        let message = txMessageQueue.removeFirst()

        if isAuto {
            if offsetBeforeAuto == 0 { offsetBeforeAuto = offset }
            offset = f
            send(message.message)
        } else {
            draftText = message.message
        }
        message.onSent?()
    }

    /// Compose and start sending a message (JS8Call's Send button).
    @discardableResult
    public func send(_ text: String) -> Bool {
        let t = text.qTrimmed()
        if t.isEmpty || mycall.isEmpty { return false }
        if !txEnabled { return false }
        if t.u16Count > 5 && t.replacingOccurrences(of: String(t.first!), with: "").qTrimmed().isEmpty { return false }

        resetMessageTransmitQueue()
        var info = Varicode.MessageInfo()
        let frames = Varicode.buildMessageFrames(mycall: mycall, mygrid: mygrid4, selectedCall: selectedCallsign,
                                                 text: replaceMacros(text, prune: false),
                                                 forceIdentify: !config.avoidForcedIdentify, forceData: false,
                                                 submode: submode, info: &info)
        if frames.isEmpty { return false }
        txFrameQueue = frames
        txFramesRemaining = frames.count
        draftText = ""
        _ = prepareNextMessageFrame()
        onChange?()
        return true
    }

    /// Preview of how `text` will be framed and what the other side will see.
    public func preview(_ text: String) -> [DecodedText] {
        var info = Varicode.MessageInfo()
        let frames = Varicode.buildMessageFrames(mycall: mycall, mygrid: mygrid4, selectedCall: selectedCallsign,
                                                 text: replaceMacros(text, prune: false),
                                                 forceIdentify: !config.avoidForcedIdentify, forceData: false,
                                                 submode: submode, info: &info)
        return frames.map { DecodedText(frame: $0.frame, bits: $0.type, submode: submode) }
    }

    func resetMessageTransmitQueue() {
        txFrameQueue.removeAll()
        txFramesRemaining = 0
        txFramesSent = 0
        totalTxMessage = ""
        nextFrame = nil
    }

    /// Halt everything queued (JS8Call's Halt TX).
    public func haltTransmit() {
        resetMessageTransmitQueue()
        txMessageQueue.removeAll()
        heartbeatLoopActive = false
        cqLoopActive = false
        restoreOffset()
        onChange?()
    }

    private func prepareNextMessageFrame() -> Bool {
        guard !txFrameQueue.isEmpty else {
            nextFrame = nil
            return false
        }
        var f = txFrameQueue.removeFirst()
        if txFramesSent > 0 { f.type &= ~Varicode.TransmissionType.first.rawValue }
        if txFrameQueue.isEmpty { f.type |= Varicode.TransmissionType.last.rawValue }
        if f.frame.isEmpty {
            nextFrame = nil
            return false
        }
        let dt = DecodedText(frame: f.frame, bits: f.type, submode: submode)
        totalTxMessage += dt.message
        txFramesSent += 1
        lastTxMessage = totalTxMessage
        nextFrame = f
        return true
    }

    /// Decide whether to key up now. Returns a request when a frame should
    /// start in the current (or imminent) period.
    public func pollTransmit(now: Date) -> TxRequest? {
        guard !isTransmitting, let frame = nextFrame, txEnabled else { return nil }
        let period = Double(submode.period)
        let ms = now.timeIntervalSince1970
        let into = ms.truncatingRemainder(dividingBy: period)
        let inTxDelay = period - txDelay <= into
        let timeToSend = (0 <= into && into < submode.txDuration) || inTxDelay
        var lateThreshold = (period - submode.dataDuration) / period - txDelay / period
        if submode == .fast { lateThreshold *= 0.75 }
        if submode == .turbo || submode == .ultra { lateThreshold *= 0.5 }
        guard timeToSend && (into / period < lateThreshold || inTxDelay) else { return nil }

        let periodStart = Date(timeIntervalSince1970: inTxDelay ? ms - into + period : ms - into)
        guard let tones = JS8Codec.encode(type: frame.type, frame: frame.frame, costas: submode.costas) else {
            nextFrame = nil
            return nil
        }
        let dt = DecodedText(frame: frame.frame, bits: frame.type, submode: submode)
        let isLast = frame.type & Varicode.TransmissionType.last.rawValue != 0
        let isFirst = txFramesSent == 1
        let display = isLast ? "\(dt.message) \(config.eot) " : dt.message
        displayText(display, offset: offset, date: now, isTx: true, isNewLine: isLast ? false : isFirst, isLast: isLast)
        logBandText(dt.message, offset: offset, date: now, snr: nil, submode: submode,
                    bits: frame.type | (isFirst ? Varicode.TransmissionType.first.rawValue : 0), isTx: true)

        let req = TxRequest(frame: frame.frame, type: frame.type, tones: tones, offset: offset, submode: submode,
                            periodStart: periodStart, displayText: dt.message)
        nextFrame = nil
        txFramesRemaining = txFrameQueue.count
        isTransmitting = true
        currentTx = req
        lastTxStart = now
        onNotify?(.txStarted, dt.message)
        onChange?()
        return req
    }

    /// Call when the audio for `currentTx` has finished.
    public func transmissionFinished() {
        guard isTransmitting else { return }
        isTransmitting = false
        currentTx = nil
        lastTxStop = clock()
        if !prepareNextMessageFrame() {
            resetMessageTransmitQueue()
            restoreOffset()
        }
        txFramesRemaining = txFrameQueue.count + (nextFrame == nil ? 0 : 1)
        onNotify?(.txFinished, "")
        onChange?()
    }

    private func restoreOffset() {
        if offsetBeforeAuto != 0 {
            offset = offsetBeforeAuto
            offsetBeforeAuto = 0
        }
    }

    // MARK: - Heartbeat / CQ

    func isFreqOffsetFree(_ f: Int, _ bw: Int) -> Bool {
        if offset == f || isDirectedOffset(f).0 { return true }
        let now = clock()
        for (off, activity) in bandActivity {
            guard let last = activity.last, now.timeIntervalSince(last.utc) < 30 else { continue }
            if abs(off - f) < bw { return false }
        }
        return true
    }

    func findFreeFreqOffset(_ fmin: Int, _ fmax: Int, _ bw: Int) -> Int {
        let nslots = (fmax - fmin) / bw
        for _ in 0..<nslots {
            let f = fmin + bw * Int.random(in: 0..<nslots)
            if isFreqOffsetFree(f, bw) { return f }
        }
        for _ in 0..<nslots {
            let f = fmin + Int.random(in: 0..<(fmax - fmin))
            if isFreqOffsetFree(f, bw) { return f }
        }
        return fmin
    }

    public func sendHeartbeat() {
        guard submode.canSendHeartbeat else { return }
        let message = "\(mycall): HEARTBEAT \(mygrid4)".qTrimmed()
        var f = findFreeFreqOffset(500, 1000, 50)
        if offset <= 1000 {
            f = offset
        } else if config.heartbeatAnywhere {
            f = -1
        }
        enqueue(priority: Priority.low + 1, message: message, offset: f)
        processTxQueue()
    }

    func sendHeartbeatAck(to: String, snr: Int, extra: String) {
        let message = "\(to) HEARTBEAT SNR \(Varicode.formatSNR(snr)) \(extra)".qTrimmed()
        let f = config.heartbeatAnywhere ? -1 : findFreeFreqOffset(500, 1000, 50)
        let m = QueuedMessage(date: clock(), priority: Priority.low + 1, message: message, offset: f, onSent: nil)
        if config.autoReplyConfirmation {
            pendingReplies.append(PendingReply(created: clock(), expires: clock().addingTimeInterval(90), message: m))
        } else {
            enqueue(m)
            processTxQueue()
        }
    }

    public func sendCQ() {
        selectedCallsign = ""
        send(replaceMacros(config.cqMessage, prune: true))
    }

    public func setHeartbeatLoop(_ on: Bool) {
        heartbeatLoopActive = on
        if on {
            if config.heartbeatQSOPause { selectedCallsign = "" }
            sendHeartbeat()
            nextHeartbeat = config.heartbeatIntervalMinutes > 0 ? clock().addingTimeInterval(Double(config.heartbeatIntervalMinutes) * 60) : nil
            if nextHeartbeat == nil { heartbeatLoopActive = false }
        } else {
            nextHeartbeat = nil
        }
        onChange?()
    }

    public func setCQLoop(_ on: Bool) {
        cqLoopActive = on
        if on {
            sendCQ()
            nextCQ = config.cqIntervalMinutes > 0 ? clock().addingTimeInterval(Double(config.cqIntervalMinutes) * 60) : nil
            if nextCQ == nil { cqLoopActive = false }
        } else {
            nextCQ = nil
        }
        onChange?()
    }

    func cancelCQLoop() {
        if cqLoopActive {
            cqLoopActive = false
            nextCQ = nil
        }
    }

    func processLoops(now: Date) {
        if heartbeatLoopActive, let next = nextHeartbeat, now >= next {
            if !isMessageQueuedForTransmit && !(config.heartbeatQSOPause && !selectedCallsign.isEmpty) {
                sendHeartbeat()
            }
            nextHeartbeat = now.addingTimeInterval(Double(max(1, config.heartbeatIntervalMinutes)) * 60)
        }
        if cqLoopActive, let next = nextCQ, now >= next {
            if !isMessageQueuedForTransmit { sendCQ() }
            nextCQ = now.addingTimeInterval(Double(max(1, config.cqIntervalMinutes)) * 60)
        }
    }

    // MARK: - Decoder gating

    /// JS8Call pauses decoding while transmitting and shortly afterwards.
    public func shouldDecode(now: Date) -> Bool {
        if isTransmitting { return false }
        if let stop = lastTxStop {
            let threshold = submode == .slow ? 4.0 : 2.0
            if now.timeIntervalSince(stop) < threshold { return false }
        }
        return true
    }

    /// Text aggregated per offset for the band activity table.
    public func bandActivityRows(now: Date) -> [BandActivityRow] {
        var rows: [BandActivityRow] = []
        let (directedOffsets) = Set(rxDirectedCache.filter { now.timeIntervalSince($0.value.date) < 120 && !$0.value.isAllcall }.keys)
        for (off, itemsIn) in bandActivity {
            var items = itemsIn
            for i in items.indices {
                var show = true
                if config.activityAgingMinutes > 0 && now.timeIntervalSince(items[i].utc) / 60 >= Double(config.activityAgingMinutes) {
                    show = false
                }
                if !config.showHeartbeatsInBand {
                    if items[i].text.contains(" @HB ") || items[i].text.contains(" HEARTBEAT ") {
                        show = false
                        if i > 0 && items[i - 1].shouldDisplay && items[i - 1].text.hasSuffix(": ") { items[i - 1].shouldDisplay = false }
                    }
                    if (i == 0 || !items[i - 1].shouldDisplay) && items[i].text.contains(" MSG ID ") { show = false }
                }
                if items[i].text.isEmpty { show = false }
                items[i].shouldDisplay = show
            }
            var texts: [String] = []
            var last: ActivityDetail?
            for item in items where item.shouldDisplay {
                var t = item.text
                if item.isLowConfidence { t = "[\(t)]" }
                if item.bits & Varicode.TransmissionType.last.rawValue != 0 { t = "\(Varicode.rstrip(t)) \(config.eot) " }
                texts.append(t)
                last = item
            }
            let joined = Varicode.rstrip(texts.joined())
            guard let l = last, !joined.isEmpty else { continue }
            let highlight = directedOffsets.contains(off / 10 * 10) || isMyCallIncluded(texts.last ?? "")
            rows.append(BandActivityRow(offset: off, text: joined, snr: l.snr, utc: l.utc, submode: l.submode,
                                        tdrift: l.tdrift, isDirectedToMe: highlight))
        }
        return rows.sorted { $0.offset < $1.offset }
    }
}

public struct BandActivityRow: Identifiable, Hashable, Sendable {
    public var id: Int { offset }
    public var offset: Int
    public var text: String
    public var snr: Int
    public var utc: Date
    public var submode: JS8Submode
    public var tdrift: Float
    public var isDirectedToMe: Bool
}
