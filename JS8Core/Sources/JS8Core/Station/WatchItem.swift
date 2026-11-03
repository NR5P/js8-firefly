import Foundation

/// A callsign, @GROUP or word to make stand out when it is heard (JS8Call's highlight words).
public struct WatchItem: Codable, Identifiable, Hashable {
    public var id = UUID()
    /// Normalized with `WatchMatcher.normalize`.
    public var term: String
    public var color: WatchColor = .gold

    public init(id: UUID = UUID(), term: String, color: WatchColor = .gold) {
        self.id = id
        self.term = term
        self.color = color
    }

    public var kind: String {
        if term.hasPrefix("@") { return "Group" }
        return Varicode.isValidCallsign(term).valid ? "Station" : "Word or group"
    }
}

public enum WatchColor: String, Codable, CaseIterable, Identifiable {
    case gold, magenta, violet, lime, orange, crimson, pearl
    public var id: String { rawValue }

    public var name: String { rawValue.capitalized }

    /// sRGB components, 0...1.
    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .gold: return (1.0, 0.82, 0.22)
        case .magenta: return (1.0, 0.36, 0.84)
        case .violet: return (0.68, 0.52, 1.0)
        case .lime: return (0.72, 1.0, 0.32)
        case .orange: return (1.0, 0.56, 0.18)
        case .crimson: return (0.82, 0.04, 0.20)
        case .pearl: return (0.94, 0.95, 1.0)
        }
    }

    /// A color this version doesn't know (saved by a newer one) falls back to gold,
    /// so it can't make the whole settings file fail to load.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WatchColor(rawValue: raw) ?? .gold
    }
}
