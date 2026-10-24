import Foundation

/// One decoded frame as shown in band activity (JS8Call's ActivityDetail).
public struct ActivityDetail: Identifiable, Hashable, Sendable, Codable {
    public var id = UUID()
    public var isLowConfidence = false
    public var isCompound = false
    public var isDirected = false
    public var isBuffered = false
    public var shouldDisplay = true
    public var bits = 0
    public var dial: UInt64 = 0
    public var offset = 0
    public var snr = 0
    public var text = ""
    public var utc = Date()
    public var submode: JS8Submode = .normal
    public var tdrift: Float = 0

    public init() {}
}

/// A station heard on the air (JS8Call's CallDetail).
public struct CallDetail: Identifiable, Hashable, Sendable, Codable {
    public var id: String { call }
    public var call = ""
    public var grid = ""
    public var through = ""
    public var snr = 0
    public var dial: UInt64 = 0
    public var offset = 0
    public var utc = Date()
    public var ackTimestamp: Date?
    public var cqTimestamp: Date?
    public var bits = 0
    public var submode: JS8Submode = .normal
    public var tdrift: Float = 0

    public init() {}
}

/// A directed command addressed to someone (JS8Call's CommandDetail).
public struct CommandDetail: Hashable, Sendable, Codable {
    public var isCompound = false
    public var isBuffered = false
    public var from = ""
    public var to = ""
    public var cmd = ""
    public var grid = ""
    public var extra = ""
    public var text = ""
    public var relayPath = ""
    public var snr = 0
    public var dial: UInt64 = 0
    public var offset = 0
    public var utc: Date?
    public var bits = 0
    public var submode: JS8Submode = .normal
    public var tdrift: Float = 0

    public init() {}
}

struct MessageBuffer {
    var cmd = CommandDetail()
    var compound: [CallDetail] = []
    var msgs: [ActivityDetail] = []
}

/// A line in the conversation window (JS8Call's RX/TX text pane).
public struct ConversationLine: Identifiable, Hashable, Sendable, Codable {
    public var id = UUID()
    public var date: Date
    public var offset: Int
    public var text: String
    public var isTx: Bool
    public var isComplete: Bool
    public var snr: Int?
    public var submode: JS8Submode?
}

public enum Priority {
    public static let low = 10
    public static let normal = 100
    public static let high = 1000
}

/// A message waiting to be transmitted.
public struct QueuedMessage: Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var priority: Int
    public var message: String
    public var offset: Int          // -1 = current offset
    public var onSent: (@Sendable () -> Void)?
}

/// An auto-reply awaiting operator confirmation.
public struct PendingReply: Identifiable, Sendable {
    public var id = UUID()
    public var created: Date
    public var expires: Date
    public var message: QueuedMessage
}

public enum StationNotification: String, Sendable {
    case directed, inbox, cq, hb, ack, newCall, txStarted, txFinished
}

/// Everything the station needs to know about the operator.
public struct StationConfig: Codable, Equatable, Sendable {
    public var callsign = ""
    public var grid = ""
    public var info = ""
    public var status = ""
    public var groups: [String] = []
    public var cqMessage = "CQ CQ CQ <MYGRID4>"
    public var replyMessage = "HW CPY?"
    public var eot = "\u{2662}"
    public var mfi = "\u{2026}\u{2026}"
    public var autoReply = true
    public var autoReplyConfirmation = false
    public var avoidAllcall = false
    public var avoidForcedIdentify = false
    public var relayOff = false
    public var heartbeatAcknowledgements = true
    public var heartbeatQSOPause = true
    public var heartbeatAnywhere = false
    public var heartbeatIntervalMinutes = 10
    public var cqIntervalMinutes = 0
    public var callsignAgingMinutes = 0
    public var activityAgingMinutes = 2
    public var autoWhitelist: [String] = []
    public var autoBlacklist: [String] = []
    public var hbBlacklist: [String] = []
    public var idleWatchdogMinutes = 0
    public var showHeartbeatsInBand = true

    public init() {}
}

/// A frame the station wants put on the air.
public struct TxRequest: Sendable, Equatable {
    public var frame: String
    public var type: Int
    public var tones: [Int]
    public var offset: Int
    public var submode: JS8Submode
    public var periodStart: Date
    public var displayText: String
}
