import Foundation

/// UTC wall clock with a user-adjustable offset (JS8 needs ±1 s timing).
enum AppClock {
    nonisolated(unsafe) static var offset: TimeInterval = 0
    static func now() -> Date { Date().addingTimeInterval(offset) }
    static func nowSeconds() -> Double { Date().timeIntervalSince1970 + offset }
}

/// Sixty seconds of 12 kHz receive audio, indexed by absolute sample time
/// (seconds since the epoch × 12000) so that decode windows line up with the
/// UTC transmit periods, exactly like JS8Call's dec_data ring buffer.
final class RxRingBuffer: @unchecked Sendable {
    static let rate = 12000
    static let capacity = 60 * rate
    private static let blockSize = 1200

    private var samples = [Float](repeating: 0, count: capacity)
    private var blockStamp = [Int64](repeating: -1, count: capacity / blockSize)
    private var nextIndex: Int64 = -1
    private let lock = NSLock()

    /// Write samples whose first sample was captured at `time` (UTC seconds).
    func write(_ data: UnsafeBufferPointer<Float>, time: Double) {
        lock.lock()
        defer { lock.unlock() }
        let expected = Int64((time * Double(Self.rate)).rounded())
        if nextIndex < 0 || abs(expected - nextIndex) > 600 {
            nextIndex = expected
        }
        var idx = nextIndex
        for v in data {
            let pos = Int(idx % Int64(Self.capacity))
            samples[pos] = v
            blockStamp[pos / Self.blockSize] = idx / Int64(Self.blockSize)
            idx += 1
        }
        nextIndex = idx
    }

    var latestIndex: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }

    /// Copy `count` samples starting at absolute index `start`; missing audio is zero.
    func read(start: Int64, count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let idx = start + Int64(i)
            if idx < 0 || idx >= nextIndex { continue }
            let pos = Int(idx % Int64(Self.capacity))
            if blockStamp[pos / Self.blockSize] == idx / Int64(Self.blockSize) {
                out[i] = samples[pos]
            }
        }
        return out
    }

    func reset() {
        lock.lock()
        nextIndex = -1
        for i in blockStamp.indices { blockStamp[i] = -1 }
        lock.unlock()
    }
}
