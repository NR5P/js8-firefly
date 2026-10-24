import Foundation

/// Interpretation of a decoded 12-character frame. Port of JS8Call's
/// DecodedText: tries fast data, data, heartbeat, compound and directed
/// unpacking in that order.
public struct DecodedText: Sendable, Hashable {
    public static let qualityThreshold: Float = 0.17

    public private(set) var frameType: Varicode.FrameType = .unknown
    public let frame: String
    public private(set) var isAlt = false
    public private(set) var isHeartbeat = false
    public let isLowConfidence: Bool
    public private(set) var compoundCall = ""
    public private(set) var directed: [String] = []
    public private(set) var extra = ""
    public private(set) var message: String
    public let bits: Int
    public let submode: JS8Submode
    public let frequencyOffset: Int
    public let snr: Int
    public let dt: Float

    public var isCompound: Bool { !compoundCall.isEmpty }
    public var isDirectedMessage: Bool { directed.count > 2 }
    public var isFirst: Bool { bits & Varicode.TransmissionType.first.rawValue != 0 }
    public var isLast: Bool { bits & Varicode.TransmissionType.last.rawValue != 0 }

    public init(frame: String, bits: Int, submode: JS8Submode, isLowConfidence: Bool = false,
                frequencyOffset: Int = 0, snr: Int = 0, dt: Float = 0) {
        self.frame = frame
        self.bits = bits
        self.submode = submode
        self.isLowConfidence = isLowConfidence
        self.frequencyOffset = frequencyOffset
        self.snr = snr
        self.dt = dt
        self.message = frame

        let m = frame.qTrimmed()
        if m.u16Count < 12 || m.contains(" ") { return }

        if tryUnpackFastData(m) { return }
        if tryUnpackData(m) { return }
        if tryUnpackHeartbeat(m) { return }
        if tryUnpackCompound(m) { return }
        _ = tryUnpackDirected(m)
    }

    public init(_ raw: JS8RawDecode) {
        self.init(frame: raw.frame, bits: raw.type, submode: raw.submode,
                  isLowConfidence: raw.quality < Self.qualityThreshold,
                  frequencyOffset: Int(raw.frequency), snr: raw.snr, dt: raw.dt)
    }

    private var isDataBits: Bool { bits & Varicode.TransmissionType.data.rawValue == Varicode.TransmissionType.data.rawValue }

    private static func buildCompound(_ parts: [String]) -> String {
        Array(parts.prefix(2)).filter { !$0.isEmpty }.joined(separator: "/")
    }

    private mutating func tryUnpackFastData(_ m: String) -> Bool {
        if !isDataBits { return false }
        let data = Varicode.unpackFastDataMessage(m)
        if data.isEmpty { return false }
        message = data
        frameType = .data
        return true
    }

    private mutating func tryUnpackData(_ m: String) -> Bool {
        if isDataBits { return false }
        let data = Varicode.unpackDataMessage(m)
        if data.isEmpty { return false }
        message = data
        frameType = .data
        return true
    }

    private mutating func tryUnpackHeartbeat(_ m: String) -> Bool {
        if isDataBits { return false }
        guard let hb = Varicode.unpackHeartbeatMessage(m), hb.parts.count >= 2 else { return false }
        frameType = Varicode.FrameType(rawValue: hb.type) ?? .unknown
        isHeartbeat = true
        isAlt = hb.isAlt
        extra = hb.parts.count > 2 ? hb.parts[2] : ""
        compoundCall = Self.buildCompound(hb.parts)
        message = compoundCall + ": "
        if hb.isAlt {
            message += "@ALLCALL " + Varicode.cqString(hb.bits3)
        } else {
            let s = Varicode.hbString(hb.bits3)
            message += "@HB " + (s == "HB" ? "HEARTBEAT" : s)
        }
        message += " " + extra + " "
        return true
    }

    private mutating func tryUnpackCompound(_ m: String) -> Bool {
        guard let c = Varicode.unpackCompoundMessage(m), c.parts.count >= 2, !isDataBits else { return false }
        frameType = Varicode.FrameType(rawValue: c.type) ?? .unknown
        extra = Array(c.parts.dropFirst(2)).joined(separator: " ")
        compoundCall = Self.buildCompound(c.parts)
        if c.type == Varicode.FrameType.compound.rawValue {
            message = compoundCall + ": "
        } else if c.type == Varicode.FrameType.compoundDirected.rawValue {
            message = compoundCall + extra + " "
            directed = ["<....>", compoundCall] + Array(c.parts.dropFirst(2))
        }
        return true
    }

    private mutating func tryUnpackDirected(_ m: String) -> Bool {
        if isDataBits { return false }
        guard let d = Varicode.unpackDirectedMessage(m), !d.parts.isEmpty else { return false }
        let parts = d.parts
        switch parts.count {
        case 3, 4:
            message = parts[0] + ": " + parts[1] + Array(parts.dropFirst(2)).joined(separator: " ") + " "
        default:
            message = parts.joined()
        }
        directed = parts
        frameType = Varicode.FrameType(rawValue: d.type) ?? .unknown
        return true
    }

    /// Whole message followed by its words (mimics a regex capture list).
    public var messageWords: [String] {
        [message] + message.split(separator: " ").map(String.init)
    }
}
