import Foundation

/// Complex sample, single precision.
public struct Complex: Equatable, Sendable {
    public var re: Float
    public var im: Float

    @inline(__always) public init(_ re: Float, _ im: Float) {
        self.re = re
        self.im = im
    }

    public static let zero = Complex(0, 0)

    @inline(__always) public static func polar(_ r: Float, _ theta: Float) -> Complex {
        Complex(r * cos(theta), r * sin(theta))
    }

    @inline(__always) public var conj: Complex { Complex(re, -im) }
    @inline(__always) public var norm: Float { re * re + im * im }
    @inline(__always) public var abs: Float { (re * re + im * im).squareRoot() }

    @inline(__always) public static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    @inline(__always) public static func - (a: Complex, b: Complex) -> Complex { Complex(a.re - b.re, a.im - b.im) }
    @inline(__always) public static func * (a: Complex, b: Complex) -> Complex {
        Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
    }
    @inline(__always) public static func * (a: Complex, s: Float) -> Complex { Complex(a.re * s, a.im * s) }
    @inline(__always) public static func += (a: inout Complex, b: Complex) { a.re += b.re; a.im += b.im }
    @inline(__always) public static func *= (a: inout Complex, b: Complex) { a = a * b }
}

/// Mixed-radix Stockham FFT for arbitrary lengths.
///
/// JS8 uses transform lengths such as 3008 (2^6 * 47) and 360960 that
/// Accelerate's vDSP DFT cannot handle, so this implementation supports any
/// factorisation: specialised butterflies for radix 2, 3, 4 and 5 and a
/// generic DFT for larger prime factors. Transforms are unnormalised, matching
/// FFTW's FFTW_FORWARD / FFTW_BACKWARD conventions.
public final class FFT: @unchecked Sendable {
    public let count: Int

    private struct Stage {
        let radix: Int
        let n: Int          // sub-sequence length at this stage
        let stride: Int     // s
        let twiddles: [Complex] // m * (radix - 1), index p*(radix-1) + (u-1)
        let roots: [Complex]    // radix-th roots of unity (generic radix only)
    }

    private let stages: [Stage]
    private var work: [Complex]

    public init(count: Int) {
        precondition(count > 0)
        self.count = count
        self.work = [Complex](repeating: .zero, count: count)

        var factors: [Int] = []
        var rem = count
        while rem % 4 == 0 { factors.append(4); rem /= 4 }
        while rem % 2 == 0 { factors.append(2); rem /= 2 }
        var f = 3
        while rem > 1 {
            while rem % f == 0 { factors.append(f); rem /= f }
            f += 2
            if f * f > rem && rem > 1 { factors.append(rem); rem = 1 }
        }

        var stages: [Stage] = []
        var n = count
        var s = 1
        for r in factors {
            let m = n / r
            var tw = [Complex](repeating: .zero, count: m * (r - 1))
            let theta0 = -2.0 * Double.pi / Double(n)
            for p in 0..<m {
                for u in 1..<r {
                    let a = theta0 * Double(p * u)
                    tw[p * (r - 1) + (u - 1)] = Complex(Float(cos(a)), Float(sin(a)))
                }
            }
            var roots: [Complex] = []
            if r > 5 {
                roots = (0..<r).map { k in
                    let a = -2.0 * Double.pi * Double(k) / Double(r)
                    return Complex(Float(cos(a)), Float(sin(a)))
                }
            }
            stages.append(Stage(radix: r, n: n, stride: s, twiddles: tw, roots: roots))
            n = m
            s *= r
        }
        self.stages = stages
    }

    /// In-place forward transform (e^{-i...}).
    public func forward(_ data: UnsafeMutablePointer<Complex>) {
        transform(data)
    }

    /// In-place backward transform (e^{+i...}), unnormalised.
    public func inverse(_ data: UnsafeMutablePointer<Complex>) {
        for i in 0..<count { data[i].im = -data[i].im }
        transform(data)
        for i in 0..<count { data[i].im = -data[i].im }
    }

    public func forward(_ data: inout [Complex]) {
        precondition(data.count >= count)
        data.withUnsafeMutableBufferPointer { forward($0.baseAddress!) }
    }

    public func inverse(_ data: inout [Complex]) {
        precondition(data.count >= count)
        data.withUnsafeMutableBufferPointer { inverse($0.baseAddress!) }
    }

    private func transform(_ data: UnsafeMutablePointer<Complex>) {
        if stages.isEmpty { return }
        work.withUnsafeMutableBufferPointer { wb in
            var x = data
            var y = wb.baseAddress!
            for stage in stages {
                Self.runStage(stage, x, y)
                swap(&x, &y)
            }
            if x != data {
                data.update(from: x, count: count)
            }
        }
    }

    @inline(__always)
    private static func runStage(_ st: Stage, _ x: UnsafeMutablePointer<Complex>, _ y: UnsafeMutablePointer<Complex>) {
        let r = st.radix
        let n = st.n
        let s = st.stride
        let m = n / r
        st.twiddles.withUnsafeBufferPointer { twb in
            let tw = twb.baseAddress!
            switch r {
            case 2:
                for p in 0..<m {
                    let w1 = tw[p]
                    let xa = x + s * p
                    let xb = x + s * (p + m)
                    let y0 = y + s * (2 * p)
                    let y1 = y + s * (2 * p + 1)
                    for q in 0..<s {
                        let a = xa[q], b = xb[q]
                        y0[q] = a + b
                        y1[q] = (a - b) * w1
                    }
                }
            case 3:
                let c1: Float = -0.5
                let c2: Float = -0.86602540378443864676 // -sin(2pi/3)
                for p in 0..<m {
                    let w1 = tw[p * 2], w2 = tw[p * 2 + 1]
                    let x0 = x + s * p, x1 = x + s * (p + m), x2 = x + s * (p + 2 * m)
                    let y0 = y + s * (3 * p), y1 = y + s * (3 * p + 1), y2 = y + s * (3 * p + 2)
                    for q in 0..<s {
                        let a = x0[q], b = x1[q], c = x2[q]
                        let t1 = b + c
                        let t2 = Complex(a.re + c1 * t1.re, a.im + c1 * t1.im)
                        let d = b - c
                        let t3 = Complex(-c2 * d.im, c2 * d.re) // c2 * i * d
                        y0[q] = a + t1
                        y1[q] = (t2 + t3) * w1
                        y2[q] = (t2 - t3) * w2
                    }
                }
            case 4:
                for p in 0..<m {
                    let w1 = tw[p * 3], w2 = tw[p * 3 + 1], w3 = tw[p * 3 + 2]
                    let x0 = x + s * p, x1 = x + s * (p + m), x2 = x + s * (p + 2 * m), x3 = x + s * (p + 3 * m)
                    let y0 = y + s * (4 * p), y1 = y + s * (4 * p + 1), y2 = y + s * (4 * p + 2), y3 = y + s * (4 * p + 3)
                    for q in 0..<s {
                        let a = x0[q], b = x1[q], c = x2[q], d = x3[q]
                        let apc = a + c, amc = a - c
                        let bpd = b + d, bmd = b - d
                        let jbmd = Complex(bmd.im, -bmd.re) // -i * (b - d)
                        y0[q] = apc + bpd
                        y1[q] = (amc + jbmd) * w1
                        y2[q] = (apc - bpd) * w2
                        y3[q] = (amc - jbmd) * w3
                    }
                }
            case 5:
                let c1 = Float(cos(2.0 * Double.pi / 5.0))
                let c2 = Float(cos(4.0 * Double.pi / 5.0))
                let s1 = Float(sin(2.0 * Double.pi / 5.0))
                let s2 = Float(sin(4.0 * Double.pi / 5.0))
                for p in 0..<m {
                    let w1 = tw[p * 4], w2 = tw[p * 4 + 1], w3 = tw[p * 4 + 2], w4 = tw[p * 4 + 3]
                    let x0 = x + s * p, x1 = x + s * (p + m), x2 = x + s * (p + 2 * m)
                    let x3 = x + s * (p + 3 * m), x4 = x + s * (p + 4 * m)
                    let y0 = y + s * (5 * p), y1 = y + s * (5 * p + 1), y2 = y + s * (5 * p + 2)
                    let y3 = y + s * (5 * p + 3), y4 = y + s * (5 * p + 4)
                    for q in 0..<s {
                        let a = x0[q], b = x1[q], c = x2[q], d = x3[q], e = x4[q]
                        let b_e = b + e, bme = b - e
                        let c_d = c + d, cmd = c - d
                        let t1 = Complex(a.re + c1 * b_e.re + c2 * c_d.re, a.im + c1 * b_e.im + c2 * c_d.im)
                        let t2 = Complex(a.re + c2 * b_e.re + c1 * c_d.re, a.im + c2 * b_e.im + c1 * c_d.im)
                        // -i * (s1*bme + s2*cmd), -i * (s2*bme - s1*cmd)
                        let u1 = Complex(s1 * bme.im + s2 * cmd.im, -(s1 * bme.re + s2 * cmd.re))
                        let u2 = Complex(s2 * bme.im - s1 * cmd.im, -(s2 * bme.re - s1 * cmd.re))
                        y0[q] = a + b_e + c_d
                        y1[q] = (t1 + u1) * w1
                        y2[q] = (t2 + u2) * w2
                        y3[q] = (t2 - u2) * w3
                        y4[q] = (t1 - u1) * w4
                    }
                }
            default:
                st.roots.withUnsafeBufferPointer { rb in
                    let roots = rb.baseAddress!
                    var tmp = [Complex](repeating: .zero, count: r)
                    for p in 0..<m {
                        for q in 0..<s {
                            for t in 0..<r { tmp[t] = x[q + s * (p + t * m)] }
                            for u in 0..<r {
                                var acc = Complex.zero
                                var idx = 0
                                for t in 0..<r {
                                    acc += tmp[t] * roots[idx]
                                    idx += u
                                    if idx >= r { idx -= r }
                                }
                                y[q + s * (r * p + u)] = u == 0 ? acc : acc * tw[p * (r - 1) + (u - 1)]
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Real-input forward FFT of even length `count`, producing `count/2 + 1`
/// complex bins (matching fftwf_plan_dft_r2c_1d).
public final class RealFFT: @unchecked Sendable {
    public let count: Int
    private let half: FFT
    private var buffer: [Complex]
    private let twiddles: [Complex]

    public init(count: Int) {
        precondition(count % 2 == 0)
        self.count = count
        self.half = FFT(count: count / 2)
        self.buffer = [Complex](repeating: .zero, count: count / 2)
        let h = count / 2
        self.twiddles = (0..<h).map { k in
            let a = -2.0 * Double.pi * Double(k) / Double(count)
            return Complex(Float(cos(a)), Float(sin(a)))
        }
    }

    /// `input` must hold `count` reals; `output` receives `count/2 + 1` bins.
    public func forward(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Complex>) {
        let h = count / 2
        buffer.withUnsafeMutableBufferPointer { bb in
            let z = bb.baseAddress!
            for i in 0..<h { z[i] = Complex(input[2 * i], input[2 * i + 1]) }
            half.forward(z)
            twiddles.withUnsafeBufferPointer { twb in
                let tw = twb.baseAddress!
                let z0 = z[0]
                output[0] = Complex(z0.re + z0.im, 0)
                output[h] = Complex(z0.re - z0.im, 0)
                if h > 1 {
                    for k in 1..<h {
                        let a = z[k]
                        let b = z[h - k].conj
                        let even = Complex((a.re + b.re) * 0.5, (a.im + b.im) * 0.5)
                        let d = a - b
                        let odd = Complex(d.im * 0.5, -d.re * 0.5) // -i/2 * (a - b)
                        output[k] = even + odd * tw[k]
                    }
                }
            }
        }
    }
}
