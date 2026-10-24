import Foundation

/// A frame recovered from the air.
public struct JS8RawDecode: Sendable, Hashable {
    public var frame: String     // 12 characters
    public var type: Int         // 3-bit transmission type (first/last/data flags)
    public var snr: Int
    public var dt: Float         // time offset in seconds
    public var frequency: Float  // audio offset in Hz
    public var quality: Float
    public var submode: JS8Submode
}

/// Candidate sync information, useful for drawing decode attempts.
public struct JS8SyncCandidate: Sendable {
    public var frequency: Float
    public var dt: Float
    public var sync: Float
}

/// Per-submode JS8 decoder. Port of JS8Call's `DecodeMode<Mode>` (JS8.cpp),
/// which is itself a conversion of the original Fortran decoder. Constants,
/// array sizes, index arithmetic and pass structure follow the reference so
/// that this decoder recovers the same frames from the same audio.
public final class JS8ModeDecoder: @unchecked Sendable {
    // Common parameters
    static let NN = 79
    static let ND = 58
    static let ASYNCMIN: Float = 1.5
    static let NFSRCH = 5
    static let NMAXCAND = 300
    static let NFILT = 1400
    static let NROWS = 8
    static let NFOS = 2
    static let NSSY = 4
    static let NP = 3200
    static let NP2 = 2812 // note: the reference uses this shared constant in js8dec
    static let TAU: Float = 2 * Float.pi

    static let BASELINE_DEGREE = 5
    static let BASELINE_SAMPLE = 10
    static let BASELINE_MIN = 500
    static let BASELINE_MAX = 2500

    public let submode: JS8Submode

    // Mode parameters
    let NSPS: Int
    let NTXDUR: Int
    let NDOWNSPS: Int
    let NDD: Int
    let JZ: Int
    let ASTART: Float
    let BASESUB: Float
    let AZ: Float
    let NMAX: Int
    let NFFT1: Int
    let NSTEP: Int
    let NHSYM: Int
    let NDOWN: Int
    let NQSYMBOL: Int
    let NDFFT1: Int
    let NDFFT2: Int
    let MODE_NP2: Int
    let TSTEP: Float
    let JSTRT: Int
    let DF: Float

    let costas: [[Int]]

    // Buffers
    var nuttal: [Float]
    var csyncs: [Complex]          // [3][7][NDOWNSPS]
    var csymb: [Complex]
    var filter: [Complex]
    var cfilt: [Complex]
    var dsCx: [Complex]            // NDFFT1/2 + 1
    var sd: [Complex]              // NFFT1/2 + 1
    var cd0: [Complex]             // NP
    var dd: [Float]                // NMAX
    var s: [Float]                 // [NSPS][NHSYM] row-major by frequency
    var savg: [Float]              // NSPS
    var sdIn: [Float]              // NFFT1 windowed input
    var bbIn: [Float]              // NDFFT1 input

    // FFTs
    let fftSD: RealFFT
    let fftBB: RealFFT
    let fftDS: FFT
    let fftCS: FFT
    let fftCF: FFT

    let taperHead: [Float]
    let taperTail: [Float]
    let baselineNodes: [Double]

    struct Sync {
        var freq: Float
        var step: Float
        var sync: Float
    }

    public init(submode: JS8Submode) {
        self.submode = submode
        switch submode {
        case .normal:
            NDOWNSPS = 32; NDD = 100; JZ = 62; ASTART = 0.5; BASESUB = 40
            AZ = (12000.0 / Float(1920)) * Float(0.64)
        case .fast:
            NDOWNSPS = 20; NDD = 100; JZ = 144; ASTART = 0.2; BASESUB = 39
            AZ = (12000.0 / Float(1200)) * Float(0.8)
        case .turbo:
            NDOWNSPS = 12; NDD = 120; JZ = 172; ASTART = 0.1; BASESUB = 38
            AZ = (12000.0 / Float(600)) * Float(0.6)
        case .slow:
            NDOWNSPS = 32; NDD = 94; JZ = 32; ASTART = 0.5; BASESUB = 42
            AZ = (12000.0 / Float(3840)) * Float(0.64)
        case .ultra:
            NDOWNSPS = 12; NDD = 125; JZ = 250; ASTART = 0.1; BASESUB = 36
            AZ = (12000.0 / Float(384)) * Float(0.64)
        }
        NSPS = submode.samplesPerSymbol
        NTXDUR = submode.period
        NMAX = NTXDUR * 12000
        NFFT1 = NSPS * Self.NFOS
        NSTEP = NSPS / Self.NSSY
        NHSYM = NMAX / NSTEP - 3
        NDOWN = NSPS / NDOWNSPS
        NQSYMBOL = NDOWNSPS / 4
        NDFFT1 = NSPS * NDD
        NDFFT2 = NDFFT1 / NDOWN
        MODE_NP2 = Self.NN * NDOWNSPS
        TSTEP = Float(NSTEP) / 12000.0
        JSTRT = Int(ASTART / TSTEP)
        DF = 12000.0 / Float(NFFT1)
        costas = submode.costas

        nuttal = [Float](repeating: 0, count: NFFT1)
        csyncs = [Complex](repeating: .zero, count: 3 * 7 * NDOWNSPS)
        csymb = [Complex](repeating: .zero, count: NDOWNSPS)
        filter = [Complex](repeating: .zero, count: NMAX)
        cfilt = [Complex](repeating: .zero, count: NMAX)
        dsCx = [Complex](repeating: .zero, count: NDFFT1 / 2 + 1)
        sd = [Complex](repeating: .zero, count: NFFT1 / 2 + 1)
        cd0 = [Complex](repeating: .zero, count: Self.NP)
        dd = [Float](repeating: 0, count: NMAX)
        s = [Float](repeating: 0, count: NSPS * NHSYM)
        savg = [Float](repeating: 0, count: NSPS)
        sdIn = [Float](repeating: 0, count: NFFT1)
        bbIn = [Float](repeating: 0, count: NDFFT1)

        fftSD = RealFFT(count: NFFT1)
        fftBB = RealFFT(count: NDFFT1)
        fftDS = FFT(count: NDFFT2)
        fftCS = FFT(count: NDOWNSPS)
        fftCF = FFT(count: NMAX)

        var head = [Float](repeating: 0, count: NDD + 1)
        var tail = [Float](repeating: 0, count: NDD + 1)
        for i in 0...NDD {
            let v = Float(0.5 * (1.0 + cos(Double(i) * Double.pi / Double(NDD))))
            tail[i] = v
            head[NDD - i] = v
        }
        taperHead = head
        taperTail = tail

        let nodeCount = Self.BASELINE_DEGREE + 1
        let slice = Double.pi / (2.0 * Double(nodeCount))
        baselineNodes = (0..<nodeCount).map { i in 0.5 * (1.0 - cos(slice * (2.0 * Double(i) + 1))) }

        // Nuttall window, normalised as in the reference.
        let a0 = 0.3635819, a1 = -0.4891775, a2 = 0.1365995, a3 = -0.0106411
        var sum: Double = 0
        var win = [Double](repeating: 0, count: NFFT1)
        let pi = 4.0 * atan(1.0)
        for i in 0..<NFFT1 {
            let x = Double(i) / Double(NFFT1)
            let v = Float(a0 + a1 * cos(2 * pi * x) + a2 * cos(4 * pi * x) + a3 * cos(6 * pi * x))
            win[i] = Double(v)
            sum += Double(v)
        }
        for i in 0..<NFFT1 {
            nuttal[i] = Float(win[i] / sum * Double(NFFT1) / 300.0)
        }

        // Costas reference waveforms.
        for i in 0..<7 {
            for k in 0..<3 {
                let dphi = Self.TAU * Float(costas[k][i]) / Float(NDOWNSPS)
                var phi: Float = 0
                for j in 0..<NDOWNSPS {
                    csyncs[(k * 7 + i) * NDOWNSPS + j] = .polar(1, phi)
                    phi = fmodf(phi + dphi, Self.TAU)
                }
            }
        }

        // Hann-like low-pass filter for signal subtraction, in the frequency domain.
        let fpi = Float(pi)
        var fsum: Float = 0
        var tmp = [Float](repeating: 0, count: Self.NFILT + 1)
        for j in (-Self.NFILT / 2)...(Self.NFILT / 2) {
            let v = powf(cosf(fpi * Float(j) / Float(Self.NFILT)), 2)
            tmp[j + Self.NFILT / 2] = v
            fsum += v
        }
        for i in 0...Self.NFILT { filter[i] = Complex(tmp[i] / fsum, 0) }
        // rotate first NFILT+1 elements left by NFILT/2
        let head0 = Array(filter[0..<(Self.NFILT / 2)])
        let rest = Array(filter[(Self.NFILT / 2)...Self.NFILT])
        for (i, v) in rest.enumerated() { filter[i] = v }
        for (i, v) in head0.enumerated() { filter[rest.count + i] = v }
        fftCF.forward(&filter)
        let factor = 1.0 / Float(NMAX)
        for i in 0..<NMAX { filter[i] = filter[i] * factor }
    }

    // MARK: - Entry point

    /// Decode one period of 12 kHz audio. `samples` should start at the
    /// beginning of the transmit period; at most NMAX samples are used.
    /// `nfqso` is the operator's selected offset; decodes near it are tried first.
    public func decode(samples: UnsafeBufferPointer<Float>, nfqso: Int, nfa: Int = 0, nfb: Int = 5000,
                       onDecode: (JS8RawDecode) -> Void) -> Int {
        let sz = min(samples.count, NMAX)
        for i in 0..<NMAX { dd[i] = i < sz ? samples[i] : 0 }

        struct Key: Hashable { let type: Int; let data: String }
        var decodes: [Key: Int] = [:]

        for ipass in 1...3 {
            var candidates = syncjs8(nfa: nfa, nfb: nfb)
            if candidates.isEmpty { break }

            let q = Float(nfqso)
            candidates.sort { a, b in
                let ad = abs(a.freq - q), bd = abs(b.freq - q)
                if ad < 10 && bd >= 10 { return true }
                if bd < 10 && ad >= 10 { return false }
                if ad != bd { return ad < bd }
                return a.freq < b.freq
            }

            computeBasebandFFT()

            let subtract = ipass < 3
            var improved = false

            for cand in candidates {
                var f1 = cand.freq
                var xdt = cand.step
                var nharderrors = -1
                var xsnr: Float = 0
                if let (type, data) = js8dec(lsubtract: subtract, f1: &f1, xdt: &xdt, nharderrors: &nharderrors, xsnr: &xsnr) {
                    let snr = Int(xsnr.rounded())
                    let key = Key(type: type, data: data)
                    if let prev = decodes[key] {
                        if prev < snr {
                            decodes[key] = snr
                            improved = true
                        } else {
                            continue
                        }
                    } else {
                        decodes[key] = snr
                        improved = true
                    }
                    onDecode(JS8RawDecode(frame: data, type: type, snr: snr, dt: xdt - ASTART, frequency: f1,
                                          quality: 1 - Float(nharderrors) / 60, submode: submode))
                }
            }
            if !improved { break }
        }
        return decodes.count
    }

    // MARK: - Spectra and sync search

    func syncjs8(nfa nfaIn: Int, nfb nfbIn: Int) -> [Sync] {
        for i in 0..<NSPS { savg[i] = 0 }

        dd.withUnsafeBufferPointer { ddb in
            sdIn.withUnsafeMutableBufferPointer { inb in
                sd.withUnsafeMutableBufferPointer { sdb in
                    s.withUnsafeMutableBufferPointer { sb in
                        savg.withUnsafeMutableBufferPointer { avg in
                            nuttal.withUnsafeBufferPointer { nut in
                                for j in 0..<NHSYM {
                                    let ia = j * NSTEP
                                    let ib = ia + NFFT1
                                    if ib > NMAX { break }
                                    for i in 0..<NFFT1 { inb[i] = ddb[ia + i] * nut[i] }
                                    fftSD.forward(inb.baseAddress!, sdb.baseAddress!)
                                    for i in 0..<NSPS {
                                        let p = sdb[i].norm
                                        sb[i * NHSYM + j] = p
                                        avg[i] += p
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        var nfa = nfaIn, nfb = nfbIn
        let nwin = nfb - nfa
        if nfa < 100 {
            nfa = 100
            if nwin < 100 { nfb = nfa + nwin }
        }
        if nfb > 4910 {
            nfb = 4910
            if nwin < 100 { nfa = nfb - nwin }
        }
        let ia = max(0, Int((Float(nfa) / DF).rounded()))
        let ib = Int((Float(nfb) / DF).rounded())

        baselinejs8(ia: ia, ib: ib)

        var entries: [Sync] = []
        entries.reserveCapacity(ib - ia + 1)
        let costas = self.costas
        s.withUnsafeBufferPointer { sb in
            for i in ia...ib {
                var maxValue = -Float.infinity
                var maxIndex = -JZ
                for j in -JZ...JZ {
                    var t0 = (Float(0), Float(0), Float(0))
                    var t1 = (Float(0), Float(0), Float(0))
                    for p in 0..<3 {
                        var a: Float = 0, b: Float = 0
                        for n in 0..<7 {
                            let offset = j + JSTRT + Self.NSSY * n + p * 36 * Self.NSSY
                            if offset >= 0 && offset < NHSYM {
                                a += sb[(i + Self.NFOS * costas[p][n]) * NHSYM + offset]
                                for freq in 0..<7 {
                                    b += sb[(i + Self.NFOS * freq) * NHSYM + offset]
                                }
                            }
                        }
                        switch p {
                        case 0: t0.0 = a; t1.0 = b
                        case 1: t0.1 = a; t1.1 = b
                        default: t0.2 = a; t1.2 = b
                        }
                    }
                    func cs(_ tx: Float, _ t0v: Float) -> Float { tx / ((t0v - tx) / 6.0) }
                    let s012 = cs(t0.0 + t0.1 + t0.2, t1.0 + t1.1 + t1.2)
                    let s01 = cs(t0.0 + t0.1, t1.0 + t1.1)
                    let s12 = cs(t0.1 + t0.2, t1.1 + t1.2)
                    let v = max(s012, max(s01, s12))
                    if v > maxValue {
                        maxValue = v
                        maxIndex = j
                    }
                }
                entries.append(Sync(freq: DF * Float(i), step: TSTEP * (Float(maxIndex) + 0.5), sync: maxValue))
            }
        }

        if entries.isEmpty { return [] }

        // Normalise to the 40th percentile.
        let sortedSyncs = entries.map { $0.sync.isNaN ? -Float.infinity : $0.sync }.sorted()
        let norm = sortedSyncs[sortedSyncs.count * 4 / 10]
        for k in entries.indices { entries[k].sync /= norm }

        // Candidate extraction in decreasing sync order, removing neighbours.
        let order = entries.indices.sorted { a, b in
            let sa = entries[a].sync, sbv = entries[b].sync
            let va = sa.isNaN ? -Float.infinity : sa
            let vb = sbv.isNaN ? -Float.infinity : sbv
            if va != vb { return va > vb }
            return a < b
        }
        var removed = [Bool](repeating: false, count: entries.count)
        var candidates: [Sync] = []
        for idx in order {
            if candidates.count >= Self.NMAXCAND { break }
            if removed[idx] { continue }
            let e = entries[idx]
            if e.sync < Self.ASYNCMIN || e.sync.isNaN { break }
            candidates.append(e)
            let lo = e.freq - AZ, hi = e.freq + AZ
            for k in entries.indices where !removed[k] && entries[k].freq >= lo && entries[k].freq <= hi {
                removed[k] = true
            }
        }
        return candidates
    }

    func baselinejs8(ia: Int, ib: Int) {
        let bmin = Int((Float(Self.BASELINE_MIN) / DF).rounded())
        let bmax = Int((Float(Self.BASELINE_MAX) / DF).rounded())
        let size = bmax - bmin + 1
        let nodeCount = baselineNodes.count
        let arm = size / (2 * nodeCount)

        for i in bmin..<(bmin + size) { savg[i] = 10 * log10f(savg[i]) }

        var px = [Double](repeating: 0, count: nodeCount)
        var py = [Double](repeating: 0, count: nodeCount)
        for i in 0..<nodeCount {
            let node = Double(size) * baselineNodes[i]
            let base = Int(node.rounded())
            let lo = min(max(base - arm, 0), size)
            let hi = min(max(base + arm, 0), size)
            var span = Array(savg[(bmin + lo)..<(bmin + hi)])
            let n = span.count * Self.BASELINE_SAMPLE / 100
            span.sort()
            px[i] = node
            py[i] = Double(span[n])
        }

        let c = Self.solveVandermonde(x: px, y: py)

        let last = Float(size - 1)
        for i in 0..<NSPS { savg[i] = 0 }
        for i in ia...ib {
            let x = Double(Float(i - ia) * last / Float(ib - ia))
            var baseline = 0.0
            var exponent = 1.0
            var k = 0
            while k < c.count {
                baseline += (c[k] + c[k + 1] * x) * exponent
                exponent *= x * x
                k += 2
            }
            savg[i] = Float(baseline) + 0.65
        }
    }

    /// Solve V c = y for the polynomial coefficients (Gaussian elimination with
    /// partial pivoting; V is square here).
    static func solveVandermonde(x: [Double], y: [Double]) -> [Double] {
        let n = x.count
        var a = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for r in 0..<n {
            var v = 1.0
            for col in 0..<n {
                a[r][col] = v
                v *= x[r]
            }
            a[r][n] = y[r]
        }
        for col in 0..<n {
            var piv = col
            for r in (col + 1)..<n where abs(a[r][col]) > abs(a[piv][col]) { piv = r }
            if piv != col { a.swapAt(piv, col) }
            let d = a[col][col]
            if d == 0 { continue }
            for r in 0..<n where r != col {
                let f = a[r][col] / d
                if f != 0 {
                    for k in col...n { a[r][k] -= f * a[col][k] }
                }
            }
        }
        return (0..<n).map { a[$0][$0] == 0 ? 0 : a[$0][n] / a[$0][$0] }
    }

    // MARK: - Downsampling

    func computeBasebandFFT() {
        for i in 0..<NDFFT1 { bbIn[i] = i < NMAX ? dd[i] : 0 }
        bbIn.withUnsafeBufferPointer { inb in
            dsCx.withUnsafeMutableBufferPointer { outb in
                fftBB.forward(inb.baseAddress!, outb.baseAddress!)
            }
        }
    }

    func js8Downsample(_ f0: Float) {
        let df = 12000.0 / Float(NDFFT1)
        let baud = 12000.0 / Float(NSPS)
        let ft = f0 + 8.5 * baud
        let fb = f0 - 1.5 * baud
        let i0 = Int((f0 / df).rounded())
        let it = min(Int((ft / df).rounded()), NDFFT1 / 2)
        let ib = max(0, Int((fb / df).rounded()))
        let nddSize = NDD + 1
        let rangeSize = it - ib + 1

        for i in 0..<NDFFT2 { cd0[i] = .zero }
        for i in 0..<rangeSize { cd0[i] = dsCx[ib + i] }

        for i in 0..<nddSize { cd0[i] = cd0[i] * taperHead[i] }
        for i in 0..<nddSize { cd0[rangeSize - nddSize + i] = cd0[rangeSize - nddSize + i] * taperTail[i] }

        // rotate left by (i0 - ib) within [0, NDFFT2)
        let shift = i0 - ib
        if shift > 0 {
            let tmp = Array(cd0[0..<NDFFT2])
            for i in 0..<NDFFT2 { cd0[i] = tmp[(i + shift) % NDFFT2] }
        }

        cd0.withUnsafeMutableBufferPointer { fftDS.inverse($0.baseAddress!) }

        let factor = 1.0 / sqrtf(Float(NDFFT1) * Float(NDFFT2))
        for i in 0..<Self.NP { cd0[i] = cd0[i] * factor }
    }

    func syncjs8d(_ i0: Int, _ delf: Float) -> Float {
        let baseDphi = Self.TAU * (1.0 / (12000.0 / Float(NDOWN)))
        var freqAdjust = [Complex](repeating: Complex(1, 0), count: NDOWNSPS)
        if delf != 0 {
            let dphi = baseDphi * delf
            var phi: Float = 0
            for i in 0..<NDOWNSPS {
                freqAdjust[i] = .polar(1, phi)
                phi = fmodf(phi + dphi, Self.TAU)
                if phi < 0 { phi += Self.TAU }
            }
        }
        var sync: Float = 0
        for i in 0..<3 {
            for j in 0..<7 {
                let offset = 36 * i * NDOWNSPS + i0 + j * NDOWNSPS
                if offset >= 0 && offset + NDOWNSPS <= MODE_NP2 {
                    var acc = Complex.zero
                    let base = (i * 7 + j) * NDOWNSPS
                    for k in 0..<NDOWNSPS {
                        acc += cd0[offset + k] * (freqAdjust[k] * csyncs[base + k]).conj
                    }
                    sync += acc.norm
                }
            }
        }
        return sync
    }

    // MARK: - Demodulation and decoding

    func js8dec(lsubtract: Bool, f1: inout Float, xdt: inout Float, nharderrors: inout Int, xsnr: inout Float) -> (Int, String)? {
        let FR = 12000.0 / Float(NFFT1)
        let FS2 = 12000.0 / Float(NDOWN)
        let DT2 = 1.0 / FS2

        let index = Int((f1 / FR).rounded())
        let scaled = 0.1 * (savg[min(max(index, 0), NSPS - 1)] - BASESUB)
        let xbase = powf(10, scaled)

        var delfbest: Float = 0
        var ibest = 0

        js8Downsample(f1)

        var i0 = Int(((xdt + ASTART) * FS2).rounded())
        var smax: Float = 0
        for idt in (i0 - NQSYMBOL)...(i0 + NQSYMBOL) {
            let sy = syncjs8d(idt, 0)
            if sy > smax {
                smax = sy
                ibest = idt
            }
        }

        let xdt2 = Float(ibest) * DT2
        i0 = Int((xdt2 * FS2).rounded())
        smax = 0
        for ifr in -Self.NFSRCH...Self.NFSRCH {
            let delf = Float(ifr) * 0.5
            let sy = syncjs8d(i0, delf)
            if sy > smax {
                smax = sy
                delfbest = delf
            }
        }

        let dphi = -delfbest * ((2 * Float.pi) / FS2)
        let wstep = Complex.polar(1, dphi)
        var w = Complex(1, 0)
        for i in 0..<Self.NP2 {
            w *= wstep
            cd0[i] *= w
        }

        xdt = xdt2
        f1 += delfbest

        let sync = syncjs8d(i0, 0)

        let NN = Self.NN
        var s2 = [Float](repeating: 0, count: Self.NROWS * NN) // [row][k]
        for k in 0..<NN {
            let i1 = ibest + k * NDOWNSPS
            for i in 0..<NDOWNSPS { csymb[i] = .zero }
            if i1 >= 0 && i1 + NDOWNSPS <= Self.NP2 {
                for i in 0..<NDOWNSPS { csymb[i] = cd0[i1 + i] }
            }
            csymb.withUnsafeMutableBufferPointer { fftCS.forward($0.baseAddress!) }
            for i in 0..<Self.NROWS { s2[i * NN + k] = csymb[i].abs / 1000 }
        }

        var nsync = 0
        for c in 0..<3 {
            let offset = c * 36
            for column in 0..<7 {
                var maxRow = 0
                var maxVal = s2[offset + column]
                for r in 1..<Self.NROWS where s2[r * NN + offset + column] > maxVal {
                    maxVal = s2[r * NN + offset + column]
                    maxRow = r
                }
                if costas[c][column] == maxRow { nsync += 1 }
            }
        }
        if nsync <= 6 { return nil }

        let ND = Self.ND
        var llr0 = [Float](repeating: 0, count: 3 * ND)
        var llr1 = [Float](repeating: 0, count: 3 * ND)
        var ps = [Float](repeating: 0, count: 8)
        for j in 0..<ND {
            let col = j < 29 ? 7 + j : 43 + (j - 29)
            for i in 0..<8 { ps[i] = s2[i * NN + col] }
            llr0[3 * j] = max(ps[4], ps[5], ps[6], ps[7]) - max(ps[0], ps[1], ps[2], ps[3])
            llr0[3 * j + 1] = max(ps[2], ps[3], ps[6], ps[7]) - max(ps[0], ps[1], ps[4], ps[5])
            llr0[3 * j + 2] = max(ps[1], ps[3], ps[5], ps[7]) - max(ps[0], ps[2], ps[4], ps[6])
            for i in 0..<8 { ps[i] = logf(ps[i] + 1e-32) }
            llr1[3 * j] = max(ps[4], ps[5], ps[6], ps[7]) - max(ps[0], ps[1], ps[2], ps[3])
            llr1[3 * j + 1] = max(ps[2], ps[3], ps[6], ps[7]) - max(ps[0], ps[1], ps[4], ps[5])
            llr1[3 * j + 2] = max(ps[1], ps[3], ps[5], ps[7]) - max(ps[0], ps[2], ps[4], ps[6])
        }

        func normalize(_ llr: inout [Float]) {
            var sum: Float = 0, sumsq: Float = 0
            for v in llr { sum += v; sumsq += v * v }
            let av = sum / Float(llr.count)
            let av2 = sumsq / Float(llr.count)
            let variance = av2 - av * av
            let sig = (variance > 0 ? variance : av2).squareRoot()
            for i in llr.indices { llr[i] = (llr[i] / sig) * 2.83 }
        }
        normalize(&llr0)
        normalize(&llr1)

        var decoded = [Int8](repeating: 0, count: JS8Codec.K)
        var cw = [Int8](repeating: 0, count: JS8Codec.N)

        for ipass in 1...4 {
            if ipass == 3 { for i in 0..<24 { llr0[i] = 0 } }
            else if ipass == 4 { for i in 24..<48 { llr0[i] = 0 } }
            let llr = ipass == 2 ? llr1 : llr0

            nharderrors = llr.withUnsafeBufferPointer { JS8Codec.bpDecode($0.baseAddress!, &decoded, &cw) }
            xsnr = -99

            if cw.allSatisfy({ $0 == 0 }) { continue }

            if nharderrors >= 0 && nharderrors < 60 &&
                !(sync < 2.0 && nharderrors > 35) &&
                !(ipass > 2 && nharderrors > 39) &&
                !(ipass == 4 && nharderrors > 30) {
                if JS8Codec.checkCRC12(decoded) {
                    let message = JS8Codec.extractMessage(decoded)
                    let i3bit = (Int(decoded[72]) << 2) | (Int(decoded[73]) << 1) | Int(decoded[74])
                    guard let itone = JS8Codec.encode(type: i3bit, frame: message, costas: costas) else { return nil }

                    if lsubtract { subtractjs8(genjs8refsig(itone, f1), xdt2) }

                    var xsig: Float = 0
                    for i in 0..<itone.count { xsig += powf(s2[itone[i] * NN + i], 2) }

                    xsnr = max(10 * log10f(max(xsig / xbase - 1, 1.259e-10)) - 32, -60)
                    return (i3bit, message)
                }
            } else {
                nharderrors = -1
            }
        }
        return nil
    }

    func genjs8refsig(_ itone: [Int], _ f0: Float) -> [Complex] {
        let bfpi = Self.TAU * f0 * (1.0 / 12000.0)
        var phi: Float = 0
        var cref = [Complex]()
        cref.reserveCapacity(Self.NN * NSPS)
        for i in 0..<Self.NN {
            let dphi = bfpi + Self.TAU * Float(itone[i]) / Float(NSPS)
            for _ in 0..<NSPS {
                cref.append(.polar(1, phi))
                phi = fmodf(phi + dphi, Self.TAU)
            }
        }
        return cref
    }

    func subtractjs8(_ cref: [Complex], _ dt: Float) {
        let nstart = Int(dt * 12000)
        let crefStart = nstart < 0 ? -nstart : 0
        let ddStart = nstart > 0 ? nstart : 0
        let size = min(cref.count - crefStart, dd.count - ddStart)
        if size <= 0 { return }

        for i in 0..<size {
            cfilt[i] = cref[crefStart + i].conj * dd[ddStart + i]
        }
        for i in size..<NMAX { cfilt[i] = .zero }

        cfilt.withUnsafeMutableBufferPointer { fftCF.forward($0.baseAddress!) }
        for i in 0..<NMAX { cfilt[i] = cfilt[i] * filter[i] }
        cfilt.withUnsafeMutableBufferPointer { fftCF.inverse($0.baseAddress!) }

        for i in 0..<size {
            dd[ddStart + i] -= 2 * (cfilt[i] * cref[crefStart + i]).re
        }
    }
}
