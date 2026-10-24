import Foundation

/// Port of JS8Call's Varicode: message framing (heartbeat, compound, directed
/// and data frames), callsign/grid packing, Huffman and JSC text coding, and
/// the buildMessageFrames() splitter. Behaviour mirrors Varicode.cpp.
public enum Varicode {
    // MARK: Transmission and frame types

    public struct TransmissionType: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let normal: TransmissionType = []          // 000
        public static let first = TransmissionType(rawValue: 1)  // 001
        public static let last = TransmissionType(rawValue: 2)   // 010
        public static let data = TransmissionType(rawValue: 4)   // 100
    }

    public enum FrameType: Int, Sendable {
        case heartbeat = 0
        case compound = 1
        case compoundDirected = 2
        case directed = 3
        case data = 4
        case dataCompressed = 6
        case unknown = 255
    }

    // MARK: Tables

    static let alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-./?"
    static let alphabetChars: [unichar] = Array(alphabet.utf16)
    static let nalphabet = 41
    static let alphabet72Chars: [unichar] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-+/?.".utf16)
    static let alphanumericChars: [unichar] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ /@".utf16)

    static let gridPattern = #"((?<grid>[A-X]{2}[0-9]{2}(?:[A-X]{2}(?:[0-9]{2})?)*)+)"#
    static let baseCallsignPattern = #"((?<callsign>\b(?<base>([0-9A-Z])?([0-9A-Z])([0-9])([A-Z])?([A-Z])?([A-Z])?)(?<portable>[/][P])?\b))"#
    static let compoundCallsignPattern = #"((?<callsign>(?:[@]?|\b)(?<extended>[A-Z0-9\/@][A-Z0-9\/]{0,2}[\/]?[A-Z0-9\/]{0,3}[\/]?[A-Z0-9\/]{0,3})\b))"#
    static let packCallsignPattern = #"(([0-9A-Z ])([0-9A-Z])([0-9])([A-Z ])([A-Z ])([A-Z ]))"#

    /// Directed commands. Order matches the QMap key ordering where it matters
    /// for reverse lookup (see `commandName(for:)`).
    public static let directedCommands: [(String, Int)] = [
        (" HEARTBEAT", -1), (" HB", -1), (" CQ", -1),
        (" SNR?", 0), ("?", 0),
        (" DIT DIT", 1),
        (" HEARING?", 3),
        (" GRID?", 4),
        (">", 5),
        (" STATUS?", 6),
        (" STATUS", 7),
        (" HEARING", 8),
        (" MSG", 9),
        (" MSG TO:", 10),
        (" QUERY", 11),
        (" QUERY MSGS", 12), (" QUERY MSGS?", 12),
        (" QUERY CALL", 13),
        (" GRID", 15),
        (" INFO?", 16), (" INFO", 17),
        (" FB", 18), (" HW CPY?", 19), (" SK", 20), (" RR", 21),
        (" QSL?", 22), (" QSL", 23),
        (" CMD", 24),
        (" SNR", 25), (" NO", 26), (" YES", 27), (" 73", 28),
        (" NACK", 2), (" ACK", 14),
        (" HEARTBEAT SNR", 29),
        (" AGN?", 30), ("  ", 31), (" ", 31),
    ]
    static let directedMap: [String: Int] = Dictionary(directedCommands, uniquingKeysWith: { a, _ in a })
    static let sortedDirectedKeys: [String] = directedCommands.map { $0.0 }.sorted { qLess($0, $1) }

    static let allowedCmds: Set<Int> = Set(-1...31)
    static let autoreplyCmds: Set<Int> = [0, 2, 3, 4, 6, 9, 10, 11, 12, 13, 14, 16, 30]
    static let bufferedCmds: Set<Int> = [5, 9, 10, 11, 12, 13, 15, 24]
    static let snrCmds: Set<Int> = [25, 29]
    static let checksumCmds: [Int: Int] = [5: 16, 9: 16, 10: 16, 11: 16, 12: 16, 13: 16, 15: 0, 24: 16]

    static let callsignPattern = "(?<callsign>[@]?[A-Z0-9/]+)"
    static let optionalCmdPattern = #"(?<cmd>\s?(?:AGN[?]|QSL[?]|HW CPY[?]|MSG TO[:]|SNR[?]|INFO[?]|GRID[?]|STATUS[?]|QUERY MSGS[?]|HEARING[?]|(?:(?:STATUS|HEARING|QUERY CALL|QUERY MSGS|QUERY|CMD|MSG|NACK|ACK|73|YES|NO|HEARTBEAT SNR|SNR|QSL|RR|SK|FB|INFO|GRID|DIT DIT)(?=[ ]|$))|[?> ]))?"#
    static let optionalGridPattern = #"(?<grid>\s?[A-R]{2}[0-9]{2})?"#
    static let optionalNumPattern = #"(?<num>(?<=SNR)\s?[-+]?(?:3[01]|[0-2]?[0-9]))?"#

    static let directedRe = QRegex("^" + callsignPattern + optionalCmdPattern + optionalNumPattern)
    static let heartbeatRe = QRegex(#"^\s*(?<callsign>[@](?:ALLCALL|HB)\s+)?(?<type>CQ CQ CQ|CQ DX|CQ QRP|CQ CONTEST|CQ FIELD|CQ FD|CQ CQ|CQ|HB|HEARTBEAT(?!\s+SNR))(?:\s(?<grid>[A-R]{2}[0-9]{2}))?\b"#)
    static let compoundRe = QRegex(#"^\s*[`]"# + callsignPattern + "(?<extra>" + optionalGridPattern + optionalCmdPattern + optionalNumPattern + ")")
    static let gridRe = QRegex(gridPattern)
    static let baseCallsignRe = QRegex(baseCallsignPattern)
    static let compoundCallsignRe = QRegex(compoundCallsignPattern)
    static let compoundCallsignAnchoredRe = QRegex("^" + compoundCallsignPattern)
    static let packCallsignRe = QRegex(packCallsignPattern)
    static let alnumMixRe = QRegex("[0-9][A-Z]|[A-Z][0-9]")

    public static let huffTable: [(String, String)] = [
        (" ", "01"), ("E", "100"), ("T", "1101"), ("A", "0011"), ("O", "11111"), ("I", "11100"),
        ("N", "10111"), ("S", "10100"), ("H", "00011"), ("R", "00000"), ("D", "111011"), ("L", "110011"),
        ("C", "110001"), ("U", "101101"), ("M", "101011"), ("W", "001011"), ("F", "001001"), ("G", "000101"),
        ("Y", "000011"), ("P", "1111011"), ("B", "1111001"), (".", "1110100"), ("V", "1100101"),
        ("K", "1100100"), ("-", "1100001"), ("+", "1100000"), ("?", "1011001"), ("!", "1011000"),
        ("\"", "1010101"), ("X", "1010100"), ("0", "0010101"), ("J", "0010100"), ("1", "0010001"),
        ("Q", "0010000"), ("2", "0001001"), ("Z", "0001000"), ("3", "0000101"), ("5", "0000100"),
        ("4", "11110101"), ("9", "11110100"), ("8", "11110001"), ("6", "11110000"), ("7", "11101011"),
        ("/", "11101010"),
    ]
    static let huffValid: Set<String> = Set(huffTable.map { $0.0 })
    static let huffDict: [String: [Bool]] = Dictionary(uniqueKeysWithValues: huffTable.map { ($0.0, $0.1.map { $0 == "1" }) })

    static let nbasecall: UInt32 = 37 * 36 * 10 * 27 * 27 * 27
    static let nbasegrid: UInt16 = 180 * 180
    static let nusergrid: UInt16 = nbasegrid + 10
    static let nmaxgrid: UInt16 = (1 << 15) - 1

    public static let groupCalls: [String] = [
        "@ALLCALL", "@JS8NET", "@DX/NA", "@DX/SA", "@DX/EU", "@DX/AS", "@DX/AF", "@DX/OC", "@DX/AN",
        "@REGION/1", "@REGION/2", "@REGION/3",
        "@GROUP/0", "@GROUP/1", "@GROUP/2", "@GROUP/3", "@GROUP/4", "@GROUP/5", "@GROUP/6", "@GROUP/7", "@GROUP/8", "@GROUP/9",
        "@COMMAND", "@CONTROL", "@NET", "@NTS",
        "@RESERVE/0", "@RESERVE/1", "@RESERVE/2", "@RESERVE/3", "@RESERVE/4",
        "@APRSIS", "@RAGCHEW", "@JS8", "@EMCOMM", "@ARES", "@MARS", "@AMRRON", "@RACES", "@RAYNET",
        "@RADAR", "@SKYWARN", "@CQ", "@HB", "@QSO", "@QSOPARTY", "@CONTEST", "@FIELDDAY", "@SOTA",
        "@IOTA", "@POTA", "@QRP", "@QRO",
    ]
    static let basecalls: [String: UInt32] = {
        var m: [String: UInt32] = ["<....>": nbasecall + 1]
        for (i, g) in groupCalls.enumerated() { m[g] = nbasecall + 2 + UInt32(i) }
        return m
    }()
    static let basecallsByValue: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        // QMap iteration is key-ordered; first key wins on duplicates (none).
        for k in basecalls.keys.sorted(by: qLess) where m[basecalls[k]!] == nil { m[basecalls[k]!] = k }
        return m
    }()

    static let cqs: [Int: String] = [0: "CQ CQ CQ", 1: "CQ DX", 2: "CQ QRP", 3: "CQ CONTEST", 4: "CQ FIELD", 5: "CQ FD", 6: "CQ CQ", 7: "CQ"]
    static let hbs: [Int: String] = [0: "HB", 1: "HB", 2: "HB", 3: "HB", 4: "HB", 5: "HB", 6: "HB", 7: "HB"]

    /// QString ordering (UTF-16 code unit comparison).
    static func qLess(_ a: String, _ b: String) -> Bool {
        let ua = Array(a.utf16), ub = Array(b.utf16)
        for i in 0..<min(ua.count, ub.count) where ua[i] != ub[i] { return ua[i] < ub[i] }
        return ua.count < ub.count
    }

    /// QMap::key(value): the smallest key mapping to `value`.
    static func commandName(for value: Int) -> String {
        for k in sortedDirectedKeys where directedMap[k] == value { return k }
        return ""
    }

    // MARK: Utilities

    public static func rstrip(_ s: String) -> String {
        var u = Array(s.utf16)
        while let l = u.last, isSpace(l) { u.removeLast() }
        return String(decoding: u, as: UTF16.self)
    }

    public static func lstrip(_ s: String) -> String {
        let u = Array(s.utf16)
        var i = 0
        while i < u.count && isSpace(u[i]) { i += 1 }
        return String(decoding: u[i...], as: UTF16.self)
    }

    static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || (c >= 0x09 && c <= 0x0D) || c == 0x85 || c == 0xA0 || c == 0x1680 ||
            (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000
    }

    public static func cqString(_ n: Int) -> String { cqs[n] ?? "" }
    public static func hbString(_ n: Int) -> String { hbs[n] ?? "" }

    public static func startsWithCQ(_ text: String) -> Bool { cqs.values.contains { text.hasPrefix($0) } }
    public static func startsWithHB(_ text: String) -> Bool { hbs.values.contains { text.hasPrefix($0) } }

    /// "+05", "-12", "-05" (Qt arg() with zero fill keeps the sign first).
    public static func formatSNR(_ snr: Int) -> String {
        if snr < -60 || snr > 60 { return "" }
        let mag = abs(snr)
        if snr < 0 { return "-" + String(format: "%02d", mag) }
        return "+" + String(format: "%02d", mag)
    }

    // MARK: Checksums

    static func crc16Kermit(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for b in data {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        }
        return crc
    }

    static func crc32Bzip2(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc ^= UInt32(b) << 24
            for _ in 0..<8 { crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }

    public static func checksum16(_ input: String) -> String {
        var c = pack16bits(crc16Kermit(Array(input.utf8)))
        if c.u16Count < 3 { c += " ".qRepeated(3 - c.u16Count) }
        return c
    }

    public static func checksum16Valid(_ checksum: String, _ input: String) -> Bool {
        pack16bits(crc16Kermit(Array(input.utf8))) == checksum
    }

    public static func checksum32(_ input: String) -> String {
        var c = pack32bits(crc32Bzip2(Array(input.utf8)))
        if c.u16Count < 6 { c += " ".qRepeated(6 - c.u16Count) }
        return c
    }

    public static func checksum32Valid(_ checksum: String, _ input: String) -> Bool {
        pack32bits(crc32Bzip2(Array(input.utf8))) == checksum
    }

    // MARK: Callsign and grid parsing

    public static func parseCallsigns(_ input: String) -> [String] {
        var calls: [String] = []
        for m in compoundCallsignRe.globalMatch(input) {
            let callsign = m.captured("callsign").qTrimmed()
            if !isValidCallsign(callsign).valid { continue }
            if gridRe.hasMatch(callsign) { continue }
            calls.append(callsign)
        }
        return calls
    }

    public static func parseGrids(_ input: String) -> [String] {
        gridRe.globalMatch(input).map { $0.captured("grid") }.filter { $0 != "RR73" }
    }

    // MARK: Huffman

    static func huffEncode(_ text: String) -> [(Int, [Bool])] {
        // all keys are single characters; sorted by length desc then reverse
        // lexical, which for single characters is simply a direct lookup.
        var out: [(Int, [Bool])] = []
        for u in text.utf16 {
            let ch = String(decoding: [u], as: UTF16.self)
            if let bits = huffDict[ch] { out.append((1, bits)) }
        }
        return out
    }

    static func huffDecode(_ bitvec: [Bool]) -> String {
        var text = ""
        var i = 0
        outer: while i < bitvec.count {
            for (key, code) in huffTable {
                let bits = huffDict[key]!
                if i + bits.count <= bitvec.count && Array(bitvec[i..<(i + bits.count)]) == bits {
                    text += key
                    i += code.count
                    continue outer
                }
            }
            break
        }
        return text
    }

    // MARK: Base-41 / 72-bit packing

    static func pack16bits(_ packed: UInt16) -> String {
        let p = Int(packed)
        let n = nalphabet
        var out: [unichar] = []
        var tmp = p / (n * n)
        out.append(alphabetChars[tmp])
        tmp = (p - tmp * (n * n)) / n
        out.append(alphabetChars[tmp])
        out.append(alphabetChars[p % n])
        return String(decoding: out, as: UTF16.self)
    }

    static func unpack16bits(_ value: String) -> UInt16 {
        let u = Array(value.utf16)
        guard u.count >= 3 else { return 0 }
        func idx(_ c: unichar) -> Int { alphabetChars.firstIndex(of: c) ?? -1 }
        let unpacked = nalphabet * nalphabet * idx(u[0]) + nalphabet * idx(u[1]) + idx(u[2])
        if unpacked > 65535 || unpacked < 0 { return 0 }
        return UInt16(unpacked)
    }

    static func pack32bits(_ packed: UInt32) -> String {
        pack16bits(UInt16(packed >> 16)) + pack16bits(UInt16(packed & 0xFFFF))
    }

    static func unpack72bits(_ text: String) -> (UInt64, UInt8) {
        let u = Array(text.utf16)
        func idx(_ c: unichar) -> Int { alphabet72Chars.firstIndex(of: c) ?? -1 }
        var value: UInt64 = 0
        for i in 0..<10 {
            value |= UInt64(bitPattern: Int64(idx(u[i]))) << UInt64(58 - 6 * i)
        }
        let remHigh = UInt8(truncatingIfNeeded: idx(u[10]))
        value |= UInt64(remHigh >> 2)
        let remLow = UInt8(truncatingIfNeeded: idx(u[11]))
        let rem = ((remHigh & 0x3) << 6) | remLow
        return (value, rem)
    }

    static func pack72bits(_ value: UInt64, _ rem: UInt8) -> String {
        var packed = [unichar](repeating: 0, count: 12)
        let remHigh = UInt8((value & 0xF) << 2) | (rem >> 6)
        let remLow = rem & 0x3F
        var v = value >> 4
        packed[11] = alphabet72Chars[Int(remLow)]
        packed[10] = alphabet72Chars[Int(remHigh)]
        for i in 0..<10 {
            packed[9 - i] = alphabet72Chars[Int(v & 0x3F)]
            v >>= 6
        }
        return String(decoding: packed, as: UTF16.self)
    }

    // MARK: Alphanumeric / callsign packing

    static func alnumIndex(_ c: unichar) -> UInt64 {
        UInt64(alphanumericChars.firstIndex(of: c) ?? -1 &+ 0)
    }

    static func packAlphaNumeric50(_ value: String) -> UInt64 {
        var word = Array(value.utf16.filter { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || c == 0x20 || c == 0x2F || c == 0x40
        })
        let slash: unichar = 0x2F, space: unichar = 0x20
        if word.count > 3 && word[3] != slash { word.insert(space, at: 3) }
        if word.count > 7 && word[7] != slash { word.insert(space, at: 7) }
        while word.count < 11 { word.append(space) }

        func ix(_ i: Int) -> UInt64 {
            if let f = alphanumericChars.firstIndex(of: word[i]) { return UInt64(f) }
            return UInt64.max // indexOf == -1 (cannot occur after filtering)
        }
        let a = UInt64(38 * 38 * 38) * 2 * 38 * 38 * 38 * 2 * 38 * 38 * ix(0)
        let b = UInt64(38 * 38 * 38) * 2 * 38 * 38 * 38 * 2 * 38 * ix(1)
        let c = UInt64(38 * 38 * 38) * 2 * 38 * 38 * 38 * 2 * ix(2)
        let d = UInt64(38 * 38 * 38) * 2 * 38 * 38 * 38 * (word[3] == slash ? 1 : 0)
        let e = UInt64(38 * 38 * 38) * 2 * 38 * 38 * ix(4)
        let f = UInt64(38 * 38 * 38) * 2 * 38 * ix(5)
        let g = UInt64(38 * 38 * 38) * 2 * ix(6)
        let h = UInt64(38 * 38 * 38) * (word[7] == slash ? 1 : 0)
        let i = UInt64(38 * 38) * ix(8)
        let j = UInt64(38) * ix(9)
        let k = ix(10)
        return a &+ b &+ c &+ d &+ e &+ f &+ g &+ h &+ i &+ j &+ k
    }

    static func unpackAlphaNumeric50(_ packedIn: UInt64) -> String {
        var packed = packedIn
        var word = [unichar](repeating: 0x20, count: 11)
        func take(_ m: UInt64) -> Int {
            let t = packed % m
            packed /= m
            return Int(t)
        }
        word[10] = alphanumericChars[take(38)]
        word[9] = alphanumericChars[take(38)]
        word[8] = alphanumericChars[take(38)]
        word[7] = take(2) != 0 ? 0x2F : 0x20
        word[6] = alphanumericChars[take(38)]
        word[5] = alphanumericChars[take(38)]
        word[4] = alphanumericChars[take(38)]
        word[3] = take(2) != 0 ? 0x2F : 0x20
        word[2] = alphanumericChars[take(38)]
        word[1] = alphanumericChars[take(38)]
        word[0] = alphanumericChars[min(take(39), alphanumericChars.count - 1)]
        return String(decoding: word.filter { $0 != 0x20 }, as: UTF16.self)
    }

    /// Returns (packed, portable). Packed 0 means unpackable.
    static func packCallsign(_ value: String) -> (UInt32, Bool) {
        var callsign = value.uppercased().qTrimmed()
        if let v = basecalls[callsign] { return (v, false) }
        var portable = false
        if callsign.hasSuffix("/P") {
            callsign = callsign.qLeft(callsign.u16Count - 2)
            portable = true
        }
        if callsign.hasPrefix("3DA0") { callsign = "3D0" + callsign.qMid(4) }
        if callsign.hasPrefix("3X") && callsign.u16Count > 2 {
            let c = callsign.qAt(2)
            if c >= 0x41 && c <= 0x5A { callsign = "Q" + callsign.qMid(2) }
        }
        let slen = callsign.u16Count
        if slen < 2 || slen > 6 { return (0, portable) }

        var permutations = [callsign]
        switch slen {
        case 2: permutations.append(" " + callsign + "   ")
        case 3: permutations.append(" " + callsign + "  "); permutations.append(callsign + "   ")
        case 4: permutations.append(" " + callsign + " "); permutations.append(callsign + "  ")
        case 5: permutations.append(" " + callsign); permutations.append(callsign + " ")
        default: break
        }
        var matched = ""
        for p in permutations {
            if let m = packCallsignRe.match(p) { matched = m.captured(0) }
        }
        if matched.isEmpty || matched.u16Count < 6 { return (0, portable) }
        let u = Array(matched.utf16)
        func ix(_ c: unichar) -> UInt32 { UInt32(alphanumericChars.firstIndex(of: c)!) }
        var packed = ix(u[0])
        packed = 36 &* packed &+ ix(u[1])
        packed = 10 &* packed &+ ix(u[2])
        packed = 27 &* packed &+ ix(u[3]) &- 10
        packed = 27 &* packed &+ ix(u[4]) &- 10
        packed = 27 &* packed &+ ix(u[5]) &- 10
        return (packed, portable)
    }

    static func unpackCallsign(_ valueIn: UInt32, portable: Bool) -> String {
        if let k = basecallsByValue[valueIn] { return k }
        var value = valueIn
        var word = [unichar](repeating: 0x20, count: 6)
        func ch(_ i: UInt32) -> unichar { Int(i) < alphanumericChars.count ? alphanumericChars[Int(i)] : 0x3F }
        word[5] = ch(value % 27 + 10); value /= 27
        word[4] = ch(value % 27 + 10); value /= 27
        word[3] = ch(value % 27 + 10); value /= 27
        word[2] = ch(value % 10); value /= 10
        word[1] = ch(value % 36); value /= 36
        word[0] = ch(value)
        var callsign = String(decoding: word, as: UTF16.self)
        if callsign.hasPrefix("3D0") { callsign = "3DA0" + callsign.qMid(3) }
        if callsign.hasPrefix("Q") && callsign.u16Count > 1 {
            let c = callsign.qAt(1)
            if c >= 0x41 && c <= 0x5A { callsign = "3X" + callsign.qMid(1) }
        }
        if portable { callsign = callsign.qTrimmed() + "/P" }
        return callsign.qTrimmed()
    }

    public static func deg2grid(_ dlongIn: Float, _ dlat: Float) -> String {
        var dlong = dlongIn
        if dlong < -180 { dlong += 360 }
        if dlong > 180 { dlong -= 360 }
        let nlong = Int(60.0 * (180.0 - Double(dlong)) / 5)
        var n1 = nlong / 240
        var n2 = (nlong - 240 * n1) / 24
        var n3 = nlong - 240 * n1 - 24 * n2
        var g = [unichar](repeating: 0, count: 6)
        g[0] = unichar(65 + n1); g[2] = unichar(48 + n2); g[4] = unichar(97 + n3)
        let nlat = Int(60.0 * (Double(dlat) + 90) / 2.5)
        n1 = nlat / 240
        n2 = (nlat - 240 * n1) / 24
        n3 = nlat - 240 * n1 - 24 * n2
        g[1] = unichar(65 + n1); g[3] = unichar(48 + n2); g[5] = unichar(97 + n3)
        return String(decoding: g, as: UTF16.self)
    }

    /// (longitude, latitude) of the centre of a grid square.
    public static func grid2deg(_ grid: String) -> (Float, Float) {
        var g = grid
        if g.u16Count < 6 { g = grid.qLeft(4) + "mm" }
        g = g.qLeft(4).uppercased() + g.qRight(2).lowercased()
        let u = Array(g.utf16).map { Int($0) }
        let nlong = 180 - 20 * (u[0] - 65)
        let n20d = 2 * (u[2] - 48)
        let xminlong = Float(5.0 * (Double(u[4] - 97) + 0.5))
        let dlong = Float(nlong - n20d) - xminlong / 60.0
        let nlat = -90 + 10 * (u[1] - 65) + u[3] - 48
        let xminlat = Float(2.5 * (Double(u[5] - 97) + 0.5))
        let dlat = Float(nlat) + xminlat / 60.0
        return (dlong, dlat)
    }

    static func packGrid(_ value: String) -> UInt16 {
        let grid = value.qTrimmed()
        if grid.u16Count < 4 { return (1 << 15) - 1 }
        let (lon, lat) = grid2deg(grid.qLeft(4))
        let ilong = Int(lon)
        let ilat = Int(lat + 90)
        return UInt16(truncatingIfNeeded: ((ilong + 180) / 2) * 180 + ilat)
    }

    static func unpackGrid(_ value: UInt16) -> String {
        if value > nbasegrid { return "" }
        let dlat = Float(Int(value) % 180 - 90)
        let dlong = Float(Int(value) / 180 * 2 - 180 + 2)
        return deg2grid(dlong, dlat).qLeft(4)
    }

    static func packNum(_ num: String) -> (UInt8, Bool) {
        if num.isEmpty { return (0, false) }
        let parsed = Int(num.qTrimmedForInt())
        let inum = max(-30, min(parsed ?? 0, 31))
        return (UInt8(inum + 30 + 1), parsed != nil)
    }

    static func packCmd(_ cmd: Int, _ num: UInt8) -> UInt8 {
        let cmdStr = commandName(for: cmd)
        if isSNRCommand(cmdStr) {
            var value = UInt8(((1 << 1) | (cmdStr == " HEARTBEAT SNR" ? 1 : 0)) << 6)
            value = value &+ (num & 0x3F)
            return value
        }
        return UInt8(cmd & 0x7F)
    }

    static func unpackCmd(_ value: UInt8) -> (Int, UInt8) {
        if value & 0x80 != 0 {
            let num = value & 0x3F
            var cmd = directedMap[" SNR"]!
            if value & 0x40 != 0 { cmd = directedMap[" HEARTBEAT SNR"]! }
            return (cmd, num)
        }
        return (Int(value & 0x7F), 0)
    }

    public static func isSNRCommand(_ cmd: String) -> Bool {
        guard let v = directedMap[cmd] else { return false }
        return snrCmds.contains(v)
    }

    public static func isCommandAllowed(_ cmd: String) -> Bool {
        guard let v = directedMap[cmd] else { return false }
        return allowedCmds.contains(v)
    }

    public static func isCommandBuffered(_ cmd: String) -> Bool {
        guard let v = directedMap[cmd] else { return false }
        return cmd.contains(" ") || bufferedCmds.contains(v)
    }

    public static func isCommandChecksumed(_ cmd: String) -> Int {
        guard let v = directedMap[cmd], let c = checksumCmds[v] else { return 0 }
        return c
    }

    public static func isCommandAutoreply(_ cmd: String) -> Bool {
        guard let v = directedMap[cmd] else { return false }
        return autoreplyCmds.contains(v)
    }

    static func isValidCompoundCallsign(_ callsign: String) -> Bool {
        let slashCount = callsign.utf16.filter { $0 == 0x2F }.count
        if callsign.u16Count - slashCount > 9 { return false }
        let idx = callsign.qIndexOf("/")
        if idx != -1 { return basecalls[callsign.qLeft(idx)] == nil }
        if callsign.hasPrefix("@") { return true }
        if callsign.u16Count > 2 && alnumMixRe.hasMatch(callsign) { return true }
        return false
    }

    public static func isValidCallsign(_ callsign: String) -> (valid: Bool, compound: Bool) {
        if basecalls[callsign] != nil { return (true, false) }
        if let m = baseCallsignRe.match(callsign), m.capturedLength0 == callsign.u16Count {
            return (callsign.u16Count > 2 && alnumMixRe.hasMatch(callsign), false)
        }
        if let m = compoundCallsignAnchoredRe.match(callsign), m.capturedLength0 == callsign.u16Count {
            let valid = isValidCompoundCallsign(m.captured(0))
            return (valid, valid)
        }
        return (false, false)
    }

    public static func isCompoundCallsign(_ callsign: String) -> Bool {
        if basecalls[callsign] != nil && !callsign.hasPrefix("@") { return false }
        if let m = baseCallsignRe.match(callsign), m.capturedLength0 == callsign.u16Count { return false }
        guard let m = compoundCallsignAnchoredRe.match(callsign), m.capturedLength0 == callsign.u16Count else { return false }
        return isValidCompoundCallsign(m.captured(0))
    }

    public static func isGroupAllowed(_ group: String) -> Bool { group != "@APRSIS" && group != "@JS8NET" }

    /// Radio::base_callsign — split on the first '/' and keep the larger part.
    public static func baseCallsign(_ callsign: String) -> String {
        var c = callsign
        let slash = c.qIndexOf("/")
        if slash >= 0 {
            let right = c.u16Count - slash - 1
            c = right >= slash ? c.qMid(slash + 1) : c.qLeft(slash)
        }
        return c.uppercased()
    }

    // MARK: Heartbeat / compound frames

    static func packHeartbeatMessage(_ text: String, _ callsign: String) -> (String, Int) {
        guard let parsed = heartbeatRe.match(text) else { return ("", 0) }
        let extra = parsed.captured("grid")
        let type = parsed.captured("type")
        let isAlt = type.hasPrefix("CQ")
        if callsign.isEmpty { return ("", 0) }

        var packedExtra = nmaxgrid
        if extra.u16Count == 4 && gridRe.hasMatch(extra) { packedExtra = packGrid(extra) }

        var number = hbs.keys.sorted().first { hbs[$0] == type } ?? 0
        if isAlt {
            packedExtra |= (1 << 15)
            number = cqs.keys.sorted().first { cqs[$0] == type } ?? 0
        }
        let frame = packCompoundFrame(callsign, FrameType.heartbeat.rawValue, packedExtra, UInt8(number))
        if frame.isEmpty { return ("", 0) }
        return (frame, parsed.capturedLength0)
    }

    struct HeartbeatInfo {
        var parts: [String]
        var type: Int
        var isAlt: Bool
        var bits3: Int
    }

    static func unpackHeartbeatMessage(_ text: String) -> HeartbeatInfo? {
        guard let f = unpackCompoundFrame(text), f.type == FrameType.heartbeat.rawValue else { return nil }
        var parts = f.parts
        parts.append(unpackGrid(f.num & ((1 << 15) - 1)))
        return HeartbeatInfo(parts: parts, type: f.type, isAlt: f.num & (1 << 15) != 0, bits3: Int(f.bits3))
    }

    static func packCompoundMessage(_ text: String) -> (String, Int) {
        guard let parsed = compoundRe.match(text) else { return ("", 0) }
        let callsign = parsed.captured("callsign")
        let grid = parsed.captured("grid")
        let cmd = parsed.captured("cmd")
        let num = parsed.captured("num").qTrimmed()
        if callsign.isEmpty { return ("", 0) }

        var type = FrameType.compound.rawValue
        var extra = nmaxgrid
        if !cmd.isEmpty, directedMap[cmd] != nil, isCommandAllowed(cmd) {
            let inum = packNum(num).0
            extra = nusergrid &+ UInt16(packCmd(directedMap[cmd]!, inum))
            type = FrameType.compoundDirected.rawValue
        } else if !grid.isEmpty {
            extra = packGrid(grid)
        }
        let frame = packCompoundFrame(callsign, type, extra, 0)
        return (frame, parsed.capturedLength0)
    }

    struct CompoundInfo {
        var parts: [String]
        var type: Int
        var bits3: Int
    }

    static func unpackCompoundMessage(_ text: String) -> CompoundInfo? {
        guard let f = unpackCompoundFrame(text),
              f.type == FrameType.compound.rawValue || f.type == FrameType.compoundDirected.rawValue else { return nil }
        var parts = f.parts
        let extra = f.num
        if extra <= nbasegrid {
            parts.append(" " + unpackGrid(extra))
        } else if nusergrid <= extra && extra < nmaxgrid {
            let (cmd, num) = unpackCmd(UInt8(truncatingIfNeeded: extra - nusergrid))
            let cmdStr = commandName(for: cmd)
            parts.append(cmdStr)
            if isSNRCommand(cmdStr) { parts.append(formatSNR(Int(num) - 31)) }
        }
        return CompoundInfo(parts: parts, type: f.type, bits3: Int(f.bits3))
    }

    static func packCompoundFrame(_ callsign: String, _ type: Int, _ num: UInt16, _ bits3: UInt8) -> String {
        if type == FrameType.data.rawValue || type == FrameType.directed.rawValue { return "" }
        let packedCallsign = packAlphaNumeric50(callsign)
        if packedCallsign == 0 { return "" }
        let packed11 = (num & (((1 << 11) - 1) << 5)) >> 5
        let packed5 = UInt8(num & 0x1F)
        let packed8 = (packed5 << 3) | bits3
        let bits = Bits.intToBits(UInt64(type), expected: 3) +
            Bits.intToBits(packedCallsign, expected: 50) +
            Bits.intToBits(UInt64(packed11), expected: 11)
        return pack72bits(Bits.bitsToInt(bits), packed8)
    }

    struct CompoundFrame {
        var parts: [String]
        var type: Int
        var num: UInt16
        var bits3: UInt8
    }

    static func unpackCompoundFrame(_ text: String) -> CompoundFrame? {
        if text.u16Count < 12 || text.contains(" ") { return nil }
        let (value, packed8) = unpack72bits(text)
        let bits = Bits.intToBits(value, expected: 64)
        let packed5 = packed8 >> 3
        let packed3 = packed8 & 0x7
        let flag = Int(Bits.bitsToInt(Bits.mid(bits, 0, 3)))
        if flag == FrameType.data.rawValue || flag == FrameType.directed.rawValue { return nil }
        let packedCallsign = Bits.bitsToInt(Bits.mid(bits, 3, 50))
        let packed11 = UInt16(truncatingIfNeeded: Bits.bitsToInt(Bits.mid(bits, 53, 11)))
        let callsign = unpackAlphaNumeric50(packedCallsign)
        let num = (packed11 << 5) | UInt16(packed5)
        return CompoundFrame(parts: [callsign, ""], type: flag, num: num, bits3: packed3)
    }

    // MARK: Directed frames

    struct DirectedPack {
        var frame: String
        var n: Int
        var to: String = ""
        var toCompound = false
        var cmd: String = ""
        var num: String = ""
    }

    static func packDirectedMessage(_ text: String, _ mycall: String) -> DirectedPack {
        var result = DirectedPack(frame: "", n: 0)
        guard let match = directedRe.match(text) else { return result }

        var from = mycall
        if isCompoundCallsign(from) { from = "<....>" }
        var to = match.captured("callsign")
        let cmd = match.captured("cmd")
        let num = match.captured("num")

        if cmd.isEmpty { return result }

        let v = isValidCallsign(to)
        let validTo = to != mycall && v.valid
        if !validTo { return result }

        result.to = to
        result.toCompound = v.compound
        if v.compound { to = "<....>" }

        if !isCommandAllowed(cmd) && !isCommandAllowed(cmd.qTrimmed()) { return result }

        let (inum, numOK) = packNum(num.qTrimmed())
        if numOK { result.num = num }

        let (packedFrom, portableFrom) = packCallsign(from)
        let (packedTo, portableTo) = packCallsign(to)
        if packedFrom == 0 || packedTo == 0 { return result }

        var cmdOut = ""
        var packedCmd = 0
        if let c = directedMap[cmd] {
            cmdOut = cmd
            packedCmd = c
        }
        if let c = directedMap[cmd.qTrimmed()] {
            cmdOut = cmd.qTrimmed()
            packedCmd = c
        }
        let flag = FrameType.directed.rawValue
        let packedExtra = UInt8(truncatingIfNeeded: ((portableFrom ? 1 : 0) << 7) + ((portableTo ? 1 : 0) << 6) + Int(inum))

        let pcmd = ((packedCmd % 32) + 32) % 32
        let bits = Bits.intToBits(UInt64(flag), expected: 3) +
            Bits.intToBits(UInt64(packedFrom), expected: 28) +
            Bits.intToBits(UInt64(packedTo), expected: 28) +
            Bits.intToBits(UInt64(pcmd), expected: 5)
        result.cmd = cmdOut
        result.n = match.capturedLength0
        result.frame = pack72bits(Bits.bitsToInt(bits), packedExtra)
        return result
    }

    static func unpackDirectedMessage(_ text: String) -> (parts: [String], type: Int)? {
        if text.u16Count < 12 || text.contains(" ") { return nil }
        let (value, extraIn) = unpack72bits(text)
        let bits = Bits.intToBits(value, expected: 64)
        let flag = Int(Bits.bitsToInt(Bits.mid(bits, 0, 3)))
        if flag != FrameType.directed.rawValue { return nil }
        let packedFrom = UInt32(truncatingIfNeeded: Bits.bitsToInt(Bits.mid(bits, 3, 28)))
        let packedTo = UInt32(truncatingIfNeeded: Bits.bitsToInt(Bits.mid(bits, 31, 28)))
        let packedCmd = Int(Bits.bitsToInt(Bits.mid(bits, 59, 5)))
        let portableFrom = (extraIn >> 7) & 1 == 1
        let portableTo = (extraIn >> 6) & 1 == 1
        let extra = Int(extraIn % 64)

        let from = unpackCallsign(packedFrom, portable: portableFrom)
        let to = unpackCallsign(packedTo, portable: portableTo)
        let cmd = commandName(for: packedCmd % 32)
        var parts = [from, to, cmd]
        if extra != 0 {
            if isSNRCommand(cmd) {
                parts.append(formatSNR(extra - 31))
            } else {
                parts.append(String(extra - 31))
            }
        }
        return (parts, flag)
    }

    // MARK: Data frames

    static func padFrame(_ frameBitsIn: [Bool]) -> String {
        var frameBits = frameBitsIn
        let pad = 72 - frameBits.count
        if pad > 0 {
            for i in 0..<pad { frameBits.append(i != 0) }
        }
        let value = Bits.bitsToInt(frameBits, 0, 64)
        let rem = UInt8(Bits.bitsToInt(frameBits, 64, 8))
        return pack72bits(value, rem)
    }

    static func packHuffMessage(_ input: String, prefix: [Bool]) -> (String, Int) {
        for u in input.utf16 {
            let ch = String(decoding: [u], as: UTF16.self).uppercased()
            if !huffValid.contains(ch) { return ("", 0) }
        }
        var frameBits = prefix
        var i = 0
        for (n, bits) in huffEncode(input) {
            if frameBits.count + bits.count < 72 {
                frameBits += bits
                i += n
                continue
            }
            break
        }
        return (padFrame(frameBits), i)
    }

    static func packCompressedMessage(_ input: String, prefix: [Bool]) -> (String, Int) {
        var frameBits = prefix
        var i = 0
        for (bits, chars) in JSC.shared.compress(input) {
            if frameBits.count + bits.count < 72 {
                frameBits += bits
                i += chars
                continue
            }
            break
        }
        return (padFrame(frameBits), i)
    }

    static func packDataMessage(_ input: String) -> (String, Int) {
        let (huffFrame, huffChars) = packHuffMessage(input, prefix: [true, false])
        let (compFrame, compChars) = packCompressedMessage(input, prefix: [true, true])
        if huffChars > compChars { return (huffFrame, huffChars) }
        return (compFrame, compChars)
    }

    static func unpackDataMessage(_ text: String) -> String {
        if text.u16Count < 12 || text.contains(" ") { return "" }
        let (value, rem) = unpack72bits(text)
        var bits = Bits.intToBits(value, expected: 64) + Bits.intToBits(UInt64(rem), expected: 8)
        if !bits[0] { return "" }
        bits = Bits.mid(bits, 1)
        let compressed = bits[0]
        let n = bits.lastIndex(of: false) ?? -1
        bits = Bits.mid(bits, 1, n - 1)
        if compressed { return JSC.shared.decompress(bits) }
        return huffDecode(bits)
    }

    static func packFastDataMessage(_ input: String) -> (String, Int) {
        packCompressedMessage(input, prefix: [])
    }

    static func unpackFastDataMessage(_ text: String) -> String {
        if text.u16Count < 12 || text.contains(" ") { return "" }
        let (value, rem) = unpack72bits(text)
        var bits = Bits.intToBits(value, expected: 64) + Bits.intToBits(UInt64(rem), expected: 8)
        let n = bits.lastIndex(of: false) ?? -1
        bits = Bits.mid(bits, 0, n)
        return JSC.shared.decompress(bits)
    }

    // MARK: Message framing

    public struct MessageInfo: Sendable {
        public var dirTo = ""
        public var dirCmd = ""
        public var dirNum = ""
    }

    public struct Frame: Sendable, Hashable {
        public var frame: String
        public var type: Int
    }

    /// Split `text` into JS8 frames exactly as JS8Call does.
    public static func buildMessageFrames(mycall: String, mygrid: String, selectedCall: String, text: String,
                                          forceIdentify forceIdentifyIn: Bool, forceData: Bool,
                                          submode: JS8Submode, info: inout MessageInfo) -> [Frame] {
        let mycallCompound = isCompoundCallsign(mycall)
        var allFrames: [Frame] = []
        var forceIdentify = forceIdentifyIn

        for lineIn in [text] {
            var line = lineIn
            var lineFrames: [Frame] = []
            var hasDirected = false
            var hasData = false
            if forceData {
                forceIdentify = false
                hasData = true
            }

            if line.hasPrefix(mycall + ":") || line.hasPrefix(mycall + " ") {
                line = lstrip(line.qMid(mycall.u16Count + 1))
            }

            if !selectedCall.isEmpty && !line.hasPrefix(selectedCall) && !line.hasPrefix("`") && !forceData {
                let startsWithBase = line.hasPrefix("@ALLCALL") || startsWithCQ(line) || startsWithHB(line)
                let calls = parseCallsigns(line)
                let startsWithStandard = !calls.isEmpty && line.hasPrefix(calls[0]) && calls[0].u16Count > 3
                if !(startsWithBase || startsWithStandard) {
                    let sep = line.hasPrefix(" ") ? "" : " "
                    line = selectedCall + sep + line
                }
            }

            while line.u16Count > 0 {
                var frame = ""
                var useBcn = false, useCmp = false, useDir = false, useDat = false

                let (bcnFrame, l) = packHeartbeatMessage(line, mycall)
                let (cmpFrame, o) = packCompoundMessage(line)
                let dir = packDirectedMessage(line, mycall)
                let n = dir.n

                let isLikelyDataFrame = lineFrames.isEmpty && selectedCall.isEmpty && dir.to.isEmpty && l == 0 && o == 0
                if forceIdentify && isLikelyDataFrame && !line.contains(mycall) {
                    line = "\(mycall): \(line)"
                }

                let datFrame: String
                let m: Int
                let fastDataFrame: Bool
                if submode == .normal {
                    (datFrame, m) = packDataMessage(line)
                    fastDataFrame = false
                } else {
                    (datFrame, m) = packFastDataMessage(line)
                    fastDataFrame = true
                }

                if !hasDirected && !hasData && l > 0 {
                    useBcn = true
                    hasDirected = false
                    frame = bcnFrame
                } else if !hasDirected && !hasData && o > 0 {
                    useCmp = true
                    hasDirected = false
                    frame = cmpFrame
                } else if !hasDirected && !hasData && n > 0 {
                    useDir = true
                    hasDirected = true
                    frame = dir.frame
                } else if m > 0 {
                    useDat = true
                    hasData = true
                    frame = datFrame
                }

                if useBcn {
                    lineFrames.append(Frame(frame: frame, type: 0))
                    line = line.qMid(l)
                }
                if useCmp {
                    lineFrames.append(Frame(frame: frame, type: 0))
                    line = line.qMid(o)
                }
                if useDir {
                    var shouldUseStandardFrame = true
                    if mycallCompound || dir.toCompound {
                        let (deFrame, _) = packCompoundMessage("`\(mycall) \(mygrid)")
                        if !deFrame.isEmpty { lineFrames.append(Frame(frame: deFrame, type: 0)) }
                        let (dcFrame, _) = packCompoundMessage("`\(dir.to)\(dir.cmd)\(dir.num)")
                        if !dcFrame.isEmpty { lineFrames.append(Frame(frame: dcFrame, type: 0)) }
                        shouldUseStandardFrame = false
                    }
                    if shouldUseStandardFrame { lineFrames.append(Frame(frame: frame, type: 0)) }

                    line = line.qMid(n)

                    if isCommandBuffered(dir.cmd) && !line.isEmpty {
                        line = lstrip(line)
                        let skipAprs = dir.to.caseInsensitiveCompare("@APRSIS") == .orderedSame &&
                            (dir.cmd == " MSG" || dir.cmd == " MSG TO:")
                        let checksumSize = skipAprs ? 0 : isCommandChecksumed(dir.cmd)
                        if checksumSize == 32 {
                            line = line + " " + checksum32(line)
                        } else if checksumSize == 16 {
                            line = line + " " + checksum16(line)
                        }
                    }
                    info.dirCmd = dir.cmd
                    info.dirTo = dir.to
                    info.dirNum = dir.num
                }
                if useDat {
                    lineFrames.append(Frame(frame: frame, type: fastDataFrame ? TransmissionType.data.rawValue : 0))
                    line = line.qMid(m)
                }
                if !useBcn && !useCmp && !useDir && !useDat {
                    // Nothing could be packed (e.g. unsupported characters); stop.
                    break
                }
            }

            if !lineFrames.isEmpty {
                lineFrames[0].type |= TransmissionType.first.rawValue
                lineFrames[lineFrames.count - 1].type |= TransmissionType.last.rawValue
            }
            allFrames += lineFrames
        }
        return allFrames
    }

    public static func buildMessageFrames(mycall: String, mygrid: String, selectedCall: String, text: String,
                                          forceIdentify: Bool, forceData: Bool, submode: JS8Submode) -> [Frame] {
        var info = MessageInfo()
        return buildMessageFrames(mycall: mycall, mygrid: mygrid, selectedCall: selectedCall, text: text,
                                  forceIdentify: forceIdentify, forceData: forceData, submode: submode, info: &info)
    }
}

extension String {
    /// QString::toInt tolerates surrounding whitespace and a leading '+'.
    func qTrimmedForInt() -> String {
        var t = qTrimmed()
        if t.hasPrefix("+") { t.removeFirst() }
        return t
    }
}
