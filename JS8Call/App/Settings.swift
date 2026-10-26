import Foundation
import JS8Core

/// All persisted app settings.
struct AppSettings: Codable, Equatable {
    var station = StationConfig()
    var submode: JS8Submode = .normal
    var offset = 1500
    var dialFrequency: UInt64 = 14_078_000
    var txEnabled = true
    var heartbeatNetworking = true
    var decodeAllSpeeds = true
    var tx = TxAudioSettings()
    var txDelay: Double = 0.2
    var rig = RigSettings()
    var inputChannel = 0
    /// Hardware RX gain (0...1); nil until the user sets it. Optional so older saved settings still decode.
    var inputGain: Float?
    var clockOffset: Double = 0
    var macInputDevice: String = ""
    var macOutputDevice: String = ""
    /// dB from the waterfall's noise floor to full white; nil until the user sets it.
    /// Optional so older saved settings still decode.
    var waterfallRange: Float?
    var waterfallBrightness: Float = 0
    var notificationsEnabled = true
    var hasOnboarded = false
    /// User-saved dial frequencies with optional labels; nil until the first is saved.
    /// Optional so older saved settings still decode.
    var savedFrequencies: [SavedFrequency]?
    /// Keep the grid updated from the device location; nil (off) until the user turns it on.
    /// Optional so older saved settings still decode.
    var gridFromLocation: Bool?

    static let storageKey = "JS8CallSettings.v1"

    /// Wide enough that a signal 40 dB over the noise doesn't saturate to white.
    static let defaultWaterfallRange: Float = 48
    var waterfallRangeDB: Float { waterfallRange ?? Self.defaultWaterfallRange }

    var autoGrid: Bool {
        get { gridFromLocation ?? false }
        set { gridFromLocation = newValue ? true : nil }
    }

    var customFrequencies: [SavedFrequency] {
        get { savedFrequencies ?? [] }
        set { savedFrequencies = newValue.isEmpty ? nil : newValue.sorted { $0.frequency < $1.frequency } }
    }

    /// The label of the saved frequency matching the dial, if any.
    var dialLabel: String? {
        customFrequencies.first { $0.frequency == dialFrequency && !$0.label.isEmpty }?.label
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// A user-saved dial frequency, e.g. a local net or event frequency.
struct SavedFrequency: Codable, Identifiable, Hashable {
    var id = UUID()
    var frequency: UInt64
    var label: String
}

/// Standard JS8 calling frequencies (dial, USB).
struct Band: Identifiable, Hashable {
    let name: String
    let frequency: UInt64
    var id: String { name }

    static let js8: [Band] = [
        Band(name: "160m", frequency: 1_842_000),
        Band(name: "80m", frequency: 3_578_000),
        Band(name: "60m", frequency: 5_357_000),
        Band(name: "40m", frequency: 7_078_000),
        Band(name: "30m", frequency: 10_130_000),
        Band(name: "20m", frequency: 14_078_000),
        Band(name: "17m", frequency: 18_104_000),
        Band(name: "15m", frequency: 21_078_000),
        Band(name: "12m", frequency: 24_922_000),
        Band(name: "10m", frequency: 28_078_000),
        Band(name: "6m", frequency: 50_318_000),
        Band(name: "2m", frequency: 144_178_000),
    ]

    static func name(for hz: UInt64) -> String {
        let ranges: [(String, ClosedRange<UInt64>)] = [
            ("160m", 1_800_000...2_000_000), ("80m", 3_500_000...4_000_000), ("60m", 5_250_000...5_450_000),
            ("40m", 7_000_000...7_300_000), ("30m", 10_100_000...10_150_000), ("20m", 14_000_000...14_350_000),
            ("17m", 18_068_000...18_168_000), ("15m", 21_000_000...21_450_000), ("12m", 24_890_000...24_990_000),
            ("10m", 28_000_000...29_700_000), ("6m", 50_000_000...54_000_000), ("2m", 144_000_000...148_000_000),
        ]
        return ranges.first { $0.1.contains(hz) }?.0 ?? "OOB"
    }
}

enum Format {
    static func mhz(_ hz: UInt64) -> String {
        String(format: "%.3f", Double(hz) / 1_000_000)
    }

    static func mhzLong(_ hz: UInt64) -> String {
        let mhz = hz / 1_000_000
        let khz = (hz / 1000) % 1000
        let rem = hz % 1000
        return String(format: "%llu.%03llu.%03llu", mhz, khz, rem)
    }

    static let utcTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static let utcShort: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func snr(_ v: Int) -> String { Varicode.formatSNR(v).isEmpty ? "–" : Varicode.formatSNR(v) }
}

/// Great-circle distance and bearing between Maidenhead grids.
enum GridMath {
    static func isValid(_ g: String) -> Bool {
        let u = Array(g.uppercased().utf8)
        guard u.count >= 4 else { return false }
        return (65...82).contains(u[0]) && (65...82).contains(u[1]) && (48...57).contains(u[2]) && (48...57).contains(u[3])
    }

    /// The 6-character locator (e.g. "EM73tu") for a position in degrees, east and north positive.
    static func grid(latitude: Double, longitude: Double) -> String {
        let lon = min(max(longitude + 180, 0), 359.9999)
        let lat = min(max(latitude + 90, 0), 179.9999)
        let field = { (v: Double) in UInt8(65 + Int(v)) }
        let sub = { (v: Double) in UInt8(97 + Int(v)) }
        let bytes: [UInt8] = [
            field(lon / 20), field(lat / 10),
            UInt8(48 + Int(lon.truncatingRemainder(dividingBy: 20) / 2)),
            UInt8(48 + Int(lat.truncatingRemainder(dividingBy: 10))),
            sub(lon.truncatingRemainder(dividingBy: 2) * 12),
            sub(lat.truncatingRemainder(dividingBy: 1) * 24),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    static func distanceBearing(from a: String, to b: String) -> (km: Double, bearing: Double)? {
        guard isValid(a), isValid(b) else { return nil }
        let (lon1, lat1) = Varicode.grid2deg(a)
        let (lon2, lat2) = Varicode.grid2deg(b)
        let r = 6371.0
        let p1 = Double(lat1) * .pi / 180, p2 = Double(lat2) * .pi / 180
        let dl = Double(lon2 - lon1) * .pi / 180
        let h = sin((p2 - p1) / 2) * sin((p2 - p1) / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        let km = 2 * r * asin(min(1, sqrt(h)))
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        var brg = atan2(y, x) * 180 / .pi
        if brg < 0 { brg += 360 }
        return (km, brg)
    }
}
