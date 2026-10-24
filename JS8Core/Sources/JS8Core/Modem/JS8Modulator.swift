import Foundation

/// Continuous-phase 8-FSK waveform generator, equivalent to JS8Call's
/// Modulator (no pulse shaping, with the same short fade at the end).
public enum JS8Modulator {
    /// Generate the audio for one frame (symbols only, no start delay).
    /// - Parameters:
    ///   - tones: 79 tone indices from `JS8Codec.encode`.
    ///   - frequency: audio frequency of tone 0, in Hz.
    ///   - sampleRate: output sample rate; must be a multiple of 12000 or 12000.
    ///   - amplitude: peak amplitude (0...1).
    public static func synthesize(tones: [Int], frequency: Double, submode: JS8Submode,
                                  sampleRate: Double = 48000, amplitude: Float = 1) -> [Float] {
        let ratio = sampleRate / Double(JS8Submode.sampleRate)
        let nsps = Double(submode.samplesPerSymbol) * ratio
        let total = Int((Double(tones.count) * nsps).rounded())
        let spacing = submode.toneSpacing
        let tau = 2.0 * Double.pi
        let i0 = Int((Double(JS8Submode.numSymbols) - 0.017) * nsps)

        var out = [Float](repeating: 0, count: total)
        var phi = 0.0
        var amp = Double(amplitude)
        var lastSym = -1
        var dphi = 0.0
        for i in 0..<total {
            let sym = min(Int(Double(i) / nsps), tones.count - 1)
            if sym != lastSym {
                dphi = tau * (frequency + Double(tones[sym]) * spacing) / sampleRate
                lastSym = sym
            }
            phi += dphi
            if phi > tau { phi -= tau }
            if i > i0 { amp *= 0.98 }
            out[i] = Float(amp * sin(phi))
        }
        return out
    }
}
