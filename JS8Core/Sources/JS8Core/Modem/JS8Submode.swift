import Foundation

/// The JS8 speeds. Raw values match JS8Call's `Varicode::SubmodeType`.
public enum JS8Submode: Int, CaseIterable, Codable, Sendable, Identifiable {
    case normal = 0
    case fast = 1
    case turbo = 2
    case slow = 4
    case ultra = 8

    public static let numSymbols = 79
    public static let sampleRate = 12000

    public var id: Int { rawValue }

    /// Name as displayed by JS8Call.
    public var name: String {
        switch self {
        case .normal: return "Normal"
        case .fast: return "Fast"
        case .turbo: return "Turbo"
        case .slow: return "Slow"
        case .ultra: return "Ultra"
        }
    }

    /// Single-letter identifier used in JS8Call logs (A, B, C, E, I).
    public var letter: Character {
        switch self {
        case .normal: return "A"
        case .fast: return "B"
        case .turbo: return "C"
        case .slow: return "E"
        case .ultra: return "I"
        }
    }

    public var samplesPerSymbol: Int {
        switch self {
        case .normal: return 1920
        case .fast: return 1200
        case .turbo: return 600
        case .slow: return 3840
        case .ultra: return 384
        }
    }

    /// Transmission period, start to start, in seconds.
    public var period: Int {
        switch self {
        case .normal: return 15
        case .fast: return 10
        case .turbo: return 6
        case .slow: return 30
        case .ultra: return 4
        }
    }

    public var startDelayMS: Int {
        switch self {
        case .normal: return 500
        case .fast: return 200
        case .turbo: return 100
        case .slow: return 500
        case .ultra: return 100
        }
    }

    public var usesOriginalCostas: Bool { self == .normal }

    public var costas: [[Int]] { usesOriginalCostas ? Costas.original : Costas.modified }

    public var rxSNRThreshold: Int {
        switch self {
        case .normal: return -24
        case .fast: return -22
        case .turbo: return -20
        case .slow: return -28
        case .ultra: return -18
        }
    }

    /// Frequency window (Hz) used to associate decodes with an existing offset.
    public var rxThreshold: Int {
        switch self {
        case .normal: return 10
        case .fast: return 16
        case .turbo: return 32
        case .slow: return 10
        case .ultra: return 50
        }
    }

    public var samplesForSymbols: Int { Self.numSymbols * samplesPerSymbol }
    public var bandwidth: Int { 8 * Self.sampleRate / samplesPerSymbol }
    public var samplesPerPeriod: Int { Self.sampleRate * period }
    public var toneSpacing: Double { Double(Self.sampleRate) / Double(samplesPerSymbol) }
    public var samplesNeeded: Int {
        Int((Double(samplesForSymbols) + (0.5 + Double(startDelayMS) / 1000.0) * Double(Self.sampleRate)).rounded(.down))
    }
    public var dataDuration: Double { Double(samplesForSymbols) / Double(Self.sampleRate) }
    public var txDuration: Double { dataDuration + Double(startDelayMS) / 1000.0 }

    /// Heartbeats are only sent in Normal, Fast and Slow (as in JS8Call).
    public var canSendHeartbeat: Bool { self == .normal || self == .fast || self == .slow }

    /// JS8Call uses JS8CallData (the fast data frame) for every mode but Normal.
    public var usesFastDataFrames: Bool { self != .normal }
}

public enum Costas {
    public static let original: [[Int]] = [
        [4, 2, 5, 6, 1, 3, 0],
        [4, 2, 5, 6, 1, 3, 0],
        [4, 2, 5, 6, 1, 3, 0],
    ]
    public static let modified: [[Int]] = [
        [0, 6, 2, 3, 5, 4, 1],
        [1, 5, 0, 2, 3, 6, 4],
        [2, 5, 0, 6, 4, 1, 3],
    ]
}
