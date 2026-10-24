import Foundation

/// JS8 channel coding: the 12-character frame alphabet, CRC-12, the LDPC
/// (174,87) generator and belief-propagation decoder, and tone mapping.
/// A faithful port of the encoder and BP decoder in JS8Call's JS8.cpp.
public enum JS8Codec {
    static let N = 174
    static let K = 87
    static let M = N - K

    /// Frame alphabet; each character carries 6 bits.
    public static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-+")
    static let alphabetBytes: [UInt8] = alphabet.map { $0.asciiValue! }

    static let alphabetWord: [UInt8] = {
        var words = [UInt8](repeating: 0xFF, count: 256)
        for (i, b) in alphabetBytes.enumerated() { words[Int(b)] = UInt8(i) }
        return words
    }()

    public static func isValidFrame(_ frame: String) -> Bool {
        let bytes = Array(frame.utf8)
        return bytes.count == 12 && bytes.allSatisfy { alphabetWord[Int($0)] != 0xFF }
    }

    /// boost::augmented_crc<12, 0xc06>(data) ^ 42
    static func crc12(_ bytes: [UInt8]) -> UInt16 {
        var rem: UInt32 = 0
        for byte in bytes {
            for bit in stride(from: 7, through: 0, by: -1) {
                let top = (rem >> 11) & 1
                rem = ((rem << 1) | UInt32((byte >> UInt8(bit)) & 1)) & 0xFFF
                if top != 0 { rem ^= 0xC06 }
            }
        }
        return UInt16(rem) ^ 42
    }

    static func checkCRC12(_ decoded: [Int8]) -> Bool {
        var bits = [UInt8](repeating: 0, count: 11)
        for i in 0..<K where decoded[i] != 0 {
            bits[i / 8] |= UInt8(1 << (7 - (i % 8)))
        }
        let crc = (UInt16(bits[9] & 0x1F) << 7) | (UInt16(bits[10]) >> 1)
        bits[9] &= 0xE0
        bits[10] = 0
        return crc == crc12(bits)
    }

    static func extractMessage(_ decoded: [Int8]) -> String {
        var s = ""
        s.reserveCapacity(12)
        for i in 0..<12 {
            var w = 0
            for b in 0..<6 { w = (w << 1) | Int(decoded[i * 6 + b]) }
            s.append(alphabet[w])
        }
        return s
    }

    /// Parity matrix: parity[row][col] for 87x87.
    static let parity: [[Bool]] = {
        LDPCTables.parityHex.map { hex in
            var row: [Bool] = []
            row.reserveCapacity(87)
            for c in hex {
                let v = c.hexDigitValue!
                for mask in [8, 4, 2, 1] where row.count < 87 {
                    row.append(v & mask != 0)
                }
            }
            return row
        }
    }()

    /// Encode a 12-character frame with a 3-bit frame type into 79 tones.
    /// Returns nil if the frame contains characters outside the alphabet.
    public static func encode(type: Int, frame: String, costas: [[Int]]) -> [Int]? {
        let chars = Array(frame.utf8)
        guard chars.count >= 12 else { return nil }
        var words = [UInt32](repeating: 0, count: 12)
        for i in 0..<12 {
            let w = alphabetWord[Int(chars[i])]
            if w == 0xFF { return nil }
            words[i] = UInt32(w)
        }

        var bytes = [UInt8](repeating: 0, count: 11)
        var j = 0
        for i in stride(from: 0, to: 12, by: 4) {
            let v = (words[i] << 18) | (words[i + 1] << 12) | (words[i + 2] << 6) | words[i + 3]
            bytes[j] = UInt8((v >> 16) & 0xFF)
            bytes[j + 1] = UInt8((v >> 8) & 0xFF)
            bytes[j + 2] = UInt8(v & 0xFF)
            j += 3
        }
        bytes[9] = UInt8((type & 0b111) << 5)
        let crc = crc12(bytes)
        bytes[9] |= UInt8((crc >> 7) & 0x1F)
        bytes[10] = UInt8((crc & 0x7F) << 1)

        var tones = [Int](repeating: 0, count: 79)
        for (k, array) in costas.enumerated() {
            for c in 0..<7 { tones[k * 36 + c] = array[c] }
        }

        func bit(_ i: Int) -> Bool { bytes[i / 8] & UInt8(0x80 >> (i % 8)) != 0 }

        var parityIndex = 7
        var outputIndex = 43
        var outputBits = 0
        var parityWord = 0
        var outputWord = 0
        for i in 0..<87 {
            var parityBits = 0
            let row = parity[i]
            for jj in 0..<87 where row[jj] && bit(jj) { parityBits += 1 }
            parityWord = (parityWord << 1) | (parityBits & 1)
            outputWord = (outputWord << 1) | (bit(i) ? 1 : 0)
            outputBits += 1
            if outputBits == 3 {
                tones[parityIndex] = parityWord
                tones[outputIndex] = outputWord
                parityIndex += 1
                outputIndex += 1
                parityWord = 0
                outputWord = 0
                outputBits = 0
            }
        }
        return tones
    }

    // MARK: - Belief propagation

    static let BP_MAX_ROWS = 7
    static let BP_MAX_CHECKS = 3
    static let BP_MAX_ITERATIONS = 30

    static let mn: [Int] = LDPCTables.Mn.flatMap { [$0.0, $0.1, $0.2] }
    static let nmCount: [Int] = LDPCTables.Nm.map { $0.0 }
    static let nm: [Int] = LDPCTables.Nm.flatMap { $0.1 }

    /// Returns the number of hard errors, or -1 on failure.
    static func bpDecode(_ llr: UnsafePointer<Float>, _ decoded: inout [Int8], _ cw: inout [Int8]) -> Int {
        var tov = [Float](repeating: 0, count: N * BP_MAX_CHECKS)
        var toc = [Float](repeating: 0, count: M * BP_MAX_ROWS)
        var tanhtoc = [Float](repeating: 0, count: M * BP_MAX_ROWS)
        var zn = [Float](repeating: 0, count: N)

        for i in 0..<M {
            for j in 0..<nmCount[i] {
                toc[i * BP_MAX_ROWS + j] = llr[nm[i * BP_MAX_ROWS + j]]
            }
        }

        var ncnt = 0
        var nclast = 0

        for iter in 0...BP_MAX_ITERATIONS {
            for i in 0..<N {
                zn[i] = llr[i] + (tov[i * 3] + tov[i * 3 + 1] + tov[i * 3 + 2])
            }
            for i in 0..<N { cw[i] = zn[i] > 0 ? 1 : 0 }

            var ncheck = 0
            for i in 0..<M {
                var synd = 0
                for j in 0..<nmCount[i] { synd += Int(cw[nm[i * BP_MAX_ROWS + j]]) }
                if synd % 2 != 0 { ncheck += 1 }
            }

            if ncheck == 0 {
                for i in 0..<K { decoded[i] = cw[M + i] }
                var nerr = 0
                for i in 0..<N where Float(2 * Int(cw[i]) - 1) * llr[i] < 0 { nerr += 1 }
                return nerr
            }

            if iter > 0 {
                let nd = ncheck - nclast
                ncnt = nd < 0 ? 0 : ncnt + 1
                if ncnt >= 5 && iter >= 10 && ncheck > 15 { return -1 }
            }
            nclast = ncheck

            for i in 0..<M {
                for j in 0..<nmCount[i] {
                    let ibj = nm[i * BP_MAX_ROWS + j]
                    var v = zn[ibj]
                    for k in 0..<BP_MAX_CHECKS where mn[ibj * 3 + k] == i {
                        v -= tov[ibj * 3 + k]
                    }
                    toc[i * BP_MAX_ROWS + j] = v
                }
            }

            for i in 0..<(M * BP_MAX_ROWS) {
                tanhtoc[i] = tanh(-toc[i] / 2)
            }

            for i in 0..<N {
                for j in 0..<BP_MAX_CHECKS {
                    let ichk = mn[i * 3 + j]
                    if ichk >= 0 {
                        var tmn: Float = 1
                        for k in 0..<nmCount[ichk] where nm[ichk * BP_MAX_ROWS + k] != i {
                            tmn *= tanhtoc[ichk * BP_MAX_ROWS + k]
                        }
                        tov[i * 3 + j] = 2 * atanh(-tmn)
                    }
                }
            }
        }
        return -1
    }
}
