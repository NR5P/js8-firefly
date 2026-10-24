import CoreGraphics
import Foundation

/// Scrolling waterfall image built from spectrum rows.
final class WaterfallRenderer: @unchecked Sendable {
    static let minHz = 100.0
    static let maxHz = 3100.0
    static let height = 220
    let width: Int
    let height = WaterfallRenderer.height
    private let startBin: Int
    private var pixels: [UInt32]
    private var row = 0
    private var floorDB: Float = -90
    private var binFloor: [Float] = []
    private let lock = NSLock()
    private let palette: [UInt32]
    /// dB from the noise floor to full white.
    var rangeDB = AppSettings.defaultWaterfallRange
    var brightness: Float = 0
    /// T/R period length; the first row of each period is drawn as a line.
    var periodSeconds: Double = 15
    private var latest: [Float] = []
    private var rowCount = 0
    private var lastPeriod: Int64 = -1
    /// Period boundaries still on screen: the row they were drawn on and the period start time.
    private var boundaries: [(row: Int, start: Double)] = []
    private var snapshotMarks: [PeriodMark] = []

    /// A period boundary in the latest image, `rowsFromTop` rows below the newest row.
    struct PeriodMark: Hashable {
        let rowsFromTop: Int
        let start: Date
    }

    /// Period boundaries matching the most recent `makeImage()`.
    var periodMarks: [PeriodMark] {
        lock.lock()
        defer { lock.unlock() }
        return snapshotMarks
    }

    /// Most recent normalised spectrum row (0…1), safe to call from any thread.
    var latestSpectrum: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    init() {
        startBin = Int(Self.minHz / SpectrumAnalyzer.binHz)
        width = Int((Self.maxHz - Self.minHz) / SpectrumAnalyzer.binHz)
        pixels = [UInt32](repeating: 0xFF10_0806, count: width * height)
        palette = Self.makePalette()
    }

    /// Classic JS8/WSJT style: deep navy → blue → cyan → yellow → red → white.
    static func makePalette() -> [UInt32] {
        let stops: [(Float, (Float, Float, Float))] = [
            (0.00, (0.02, 0.03, 0.08)),
            (0.18, (0.04, 0.10, 0.35)),
            (0.38, (0.05, 0.45, 0.85)),
            (0.55, (0.15, 0.85, 0.95)),
            (0.70, (0.95, 0.95, 0.30)),
            (0.85, (1.00, 0.45, 0.10)),
            (1.00, (1.00, 0.95, 0.95)),
        ]
        var out = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            let x = Float(i) / 255
            var k = 0
            while k < stops.count - 2 && x > stops[k + 1].0 { k += 1 }
            let (x0, c0) = stops[k], (x1, c1) = stops[k + 1]
            let t = max(0, min(1, (x - x0) / (x1 - x0)))
            let r = UInt32((c0.0 + (c1.0 - c0.0) * t) * 255)
            let g = UInt32((c0.1 + (c1.1 - c0.1) * t) * 255)
            let b = UInt32((c0.2 + (c1.2 - c0.2) * t) * 255)
            out[i] = 0xFF00_0000 | (b << 16) | (g << 8) | r
        }
        return out
    }

    func add(row db: [Float]) {
        guard db.count >= startBin + width else { return }
        var slice = Array(db[startBin..<(startBin + width)])
        // Flatten the receiver passband: track a per-bin noise floor that
        // falls quickly and rises slowly (signals don't lift it), like
        // JS8Call's flattened waterfall.
        if binFloor.count != width { binFloor = slice }
        for i in 0..<width {
            let v = slice[i]
            binFloor[i] = v < binFloor[i] ? binFloor[i] * 0.7 + v * 0.3 : binFloor[i] + min(0.08, v - binFloor[i])
        }
        // Smooth the floor across neighbouring bins.
        var smooth = binFloor
        let k = 12
        for i in 0..<width {
            var acc: Float = 0
            var n: Float = 0
            for j in max(0, i - k)...min(width - 1, i + k) { acc += binFloor[j]; n += 1 }
            smooth[i] = acc / n
        }
        let globalFloor = smooth.sorted()[width / 2]
        for i in 0..<width { slice[i] = slice[i] - smooth[i] + globalFloor }
        let sorted = slice.sorted()
        let p25 = sorted[sorted.count / 4]
        floorDB = floorDB * 0.9 + p25 * 0.1
        let p = max(1, periodSeconds)
        let period = Int64((AppClock.nowSeconds() / p).rounded(.down))
        let isBoundary = lastPeriod >= 0 && period != lastPeriod
        lastPeriod = period
        lock.lock()
        row = (row + height - 1) % height
        rowCount += 1
        let base = row * width
        let lo = floorDB - 4 + brightness
        let span = max(8, rangeDB)
        for i in 0..<width {
            let v = (slice[i] - lo) / span
            let idx = Int(max(0, min(1, v)) * 255)
            pixels[base + i] = isBoundary ? Self.boundaryTint(palette[idx]) : palette[idx]
        }
        if isBoundary { boundaries.append((rowCount, Double(period) * p)) }
        boundaries.removeAll { rowCount - $0.row >= height }
        latest = slice.map { ($0 - lo) / span }
        lock.unlock()
    }

    /// Blend a pixel halfway toward light grey so the boundary shows without hiding signals.
    private static func boundaryTint(_ px: UInt32) -> UInt32 {
        let r = ((px & 0xFF) + 0xD0) / 2
        let g = (((px >> 8) & 0xFF) + 0xD0) / 2
        let b = (((px >> 16) & 0xFF) + 0xD0) / 2
        return 0xFF00_0000 | (b << 16) | (g << 8) | r
    }

    /// Newest row first.
    func makeImage() -> CGImage? {
        lock.lock()
        snapshotMarks = boundaries.map {
            PeriodMark(rowsFromTop: rowCount - $0.row, start: Date(timeIntervalSince1970: $0.start))
        }
        var ordered = [UInt32](repeating: 0, count: width * height)
        let first = row * width
        let tail = pixels.count - first
        ordered.withUnsafeMutableBufferPointer { dst in
            pixels.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress! + first, count: tail)
                (dst.baseAddress! + tail).update(from: src.baseAddress!, count: first)
            }
        }
        lock.unlock()
        let data = ordered.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
