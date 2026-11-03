import Foundation

/// Repeatable noise for tests that build audio.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func gaussian(_ g: inout SeededGenerator) -> Float {
    let u1 = max(Double(g.next() >> 11) / Double(1 << 53), 1e-12)
    let u2 = Double(g.next() >> 11) / Double(1 << 53)
    return Float((-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2))
}
