import Accelerate
import Foundation

/// Rolling spectrum for the waterfall: 4096-point Hann-windowed FFT of the
/// 12 kHz receive stream (2.93 Hz bins), hop of 1024 samples (~11.7 rows/s).
final class SpectrumAnalyzer: @unchecked Sendable {
    static let fftSize = 4096
    static let hop = 1024
    static let binHz = Double(RxRingBuffer.rate) / Double(fftSize)

    private let setup: vDSP.FFT<DSPSplitComplex>
    private var window: [Float]
    private var history = [Float](repeating: 0, count: fftSize)
    private var pending = 0
    private var real = [Float](repeating: 0, count: fftSize / 2)
    private var imag = [Float](repeating: 0, count: fftSize / 2)

    /// Called with one row of power in dB for bins 0..<fftSize/2.
    var onRow: (([Float]) -> Void)?

    init() {
        setup = vDSP.FFT(log2n: vDSP_Length(log2(Double(Self.fftSize))), radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.fftSize, isHalfWindow: false)
    }

    private var writePos = 0

    func process(_ data: UnsafeBufferPointer<Float>) {
        for v in data {
            history[writePos] = v
            writePos = (writePos + 1) % Self.fftSize
            pending += 1
            if pending >= Self.hop {
                pending = 0
                computeRow()
            }
        }
    }

    private func computeRow() {
        let n = Self.fftSize
        var windowed = [Float](repeating: 0, count: n)
        for i in 0..<n { windowed[i] = history[(writePos + i) % n] * window[i] }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                setup.forward(input: split, output: &split)
                var mags = [Float](repeating: 0, count: n / 2)
                vDSP.squareMagnitudes(split, result: &mags)
                // Normalise for 16-bit scaled input and convert to dB.
                let scale = 1.0 / Float(n * n) * 4
                vDSP.multiply(scale, mags, result: &mags)
                vDSP.add(1e-12, mags, result: &mags)
                let db = vDSP.powerToDecibels(mags, zeroReference: 1)
                onRow?(db)
            }
        }
    }
}
