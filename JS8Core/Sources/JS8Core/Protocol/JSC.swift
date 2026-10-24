import Foundation

/// JS8Call's dictionary compressor ("JSC"): (s,c)-dense coding over a
/// 262,144-entry word list. The tables are exported verbatim from JS8Call into
/// `jsc.bin` so that compression and decompression match the desktop app.
public final class JSC: @unchecked Sendable {
    public static let shared = JSC()

    struct Entry {
        let offset: Int   // into strings
        let length: Int   // strlen
        let size: Int     // declared size
        let index: Int
    }

    static let size = 262144

    let strings: [UInt8]
    let map: [Entry]
    let list: [Entry]
    let prefix: [Entry]
    private var cache: [String: Int] = [:]
    private let lock = NSLock()

    private init() {
        guard let url = Bundle.module.url(forResource: "jsc", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else {
            fatalError("jsc.bin resource missing")
        }
        let bytes = [UInt8](data)
        var pos = 4
        func u32() -> Int {
            let v = Int(bytes[pos]) | Int(bytes[pos + 1]) << 8 | Int(bytes[pos + 2]) << 16 | Int(bytes[pos + 3]) << 24
            pos += 4
            return v
        }
        func u8() -> Int {
            let v = Int(bytes[pos])
            pos += 1
            return v
        }
        let mapCount = u32(), listCount = u32(), prefixCount = u32()
        var strings: [UInt8] = []
        strings.reserveCapacity(bytes.count)
        func read(prefixed: Bool) -> Entry {
            let n = u8()
            let size = prefixed ? u32() : u8()
            let index = u32()
            let off = strings.count
            strings.append(contentsOf: bytes[pos..<(pos + n)])
            pos += n
            return Entry(offset: off, length: n, size: size, index: index)
        }
        var map: [Entry] = []
        map.reserveCapacity(mapCount)
        for _ in 0..<mapCount { map.append(read(prefixed: false)) }
        var list: [Entry] = []
        list.reserveCapacity(listCount)
        for _ in 0..<listCount { list.append(read(prefixed: false)) }
        var prefix: [Entry] = []
        for _ in 0..<prefixCount { prefix.append(read(prefixed: true)) }
        self.strings = strings
        self.map = map
        self.list = list
        self.prefix = prefix
    }

    /// Latin-1 decoding of a map entry string.
    func mapString(_ j: Int) -> String {
        let e = map[j]
        return String(decoding: strings[e.offset..<(e.offset + e.length)].map { UInt16($0) }, as: UTF16.self)
    }

    static func latin1(_ s: String) -> [UInt8] {
        s.utf16.map { $0 < 256 ? UInt8($0) : UInt8(ascii: "?") }
    }

    /// JSC::lookup — prefix match followed by strncmp over the list.
    func lookup(_ w: String) -> Int? {
        lock.lock()
        if let v = cache[w] {
            lock.unlock()
            return v
        }
        lock.unlock()
        let b = Self.latin1(w)
        guard let result = lookup(bytes: b) else { return nil }
        lock.lock()
        cache[w] = result
        lock.unlock()
        return result
    }

    private func lookup(bytes b: [UInt8]) -> Int? {
        let b0: UInt8 = b.first ?? 0
        var index = 0
        var count = 0
        var found = false
        for p in prefix {
            let first = p.length > 0 ? strings[p.offset] : 0
            if b0 != first { continue }
            if p.size == 1 {
                return list[p.index].index
            }
            index = p.index
            count = p.size
            found = true
            break
        }
        if !found { return nil }
        for i in index..<(index + count) {
            let e = list[i]
            if strncmpEqual(b, e) { return e.index }
        }
        return nil
    }

    private func strncmpEqual(_ b: [UInt8], _ e: Entry) -> Bool {
        let len = e.size
        for k in 0..<len {
            let c1: UInt8 = k < b.count ? b[k] : 0
            let c2: UInt8 = k < e.length ? strings[e.offset + k] : 0
            if c1 != c2 { return false }
            if c1 == 0 { return true }
        }
        return true
    }

    public func exists(_ w: String) -> Bool {
        guard let idx = lookup(w) else { return false }
        return map[idx].size == w.u16Count
    }

    static func codeword(index: Int, separate: Bool, bytesize: Int, s: Int, c: Int) -> [Bool] {
        var out: [[Bool]] = []
        let v = ((index % s) << 1) + (separate ? 1 : 0)
        out.insert(Bits.intToBits(UInt64(v), expected: bytesize + 1), at: 0)
        var x = index / s
        while x > 0 {
            x -= 1
            out.insert(Bits.intToBits(UInt64((x % c) + s), expected: bytesize), at: 0)
            x /= c
        }
        return out.flatMap { $0 }
    }

    /// Returns (codeword bits, characters consumed) pairs.
    public func compress(_ text: String) -> [([Bool], Int)] {
        var out: [([Bool], Int)] = []
        let b = 4, s = 7, c = (1 << 4) - s
        let words = text.components(separatedBy: " ")
        for (i, w0) in words.enumerated() {
            var w = w0
            let isLastWord = i == words.count - 1
            var isSpaceCharacter = false
            if w.isEmpty && !isLastWord {
                w = " "
                isSpaceCharacter = true
            }
            while !w.isEmpty {
                guard let index = lookup(w) else { break }
                let t = map[index]
                w = w.qMid(t.size)
                let isLast = w.isEmpty
                let shouldAppendSpace = isLast && !isSpaceCharacter && !isLastWord
                out.append((Self.codeword(index: index, separate: shouldAppendSpace, bytesize: b, s: s, c: c),
                            t.size + (shouldAppendSpace ? 1 : 0)))
            }
        }
        return out
    }

    public func decompress(_ bitvec: [Bool]) -> String {
        let s = 7, c = 16 - s
        var base = [Int](repeating: 0, count: 8)
        base[1] = s
        base[2] = base[1] + s * c
        base[3] = base[2] + s * c * c
        base[4] = base[3] + s * c * c * c
        base[5] = base[4] + s * c * c * c * c
        base[6] = base[5] + s * c * c * c * c * c
        base[7] = base[6] + s * c * c * c * c * c * c

        var bytes: [Int] = []
        var separators: [Int] = []
        var i = 0
        let count = bitvec.count
        while i < count {
            if i + 4 > count { break }
            let byte = Int(Bits.bitsToInt(bitvec, i, 4))
            bytes.append(byte)
            i += 4
            if byte < s {
                if count - i > 0 && bitvec[i] { separators.append(bytes.count - 1) }
                i += 1
            }
        }

        var out = ""
        var start = 0
        while start < bytes.count {
            var k = 0
            var j = 0
            while start + k < bytes.count && bytes[start + k] >= s {
                j = j * c + (bytes[start + k] - s)
                k += 1
            }
            if j >= Self.size { break }
            if start + k >= bytes.count { break }
            j = j * s + bytes[start + k] + base[k]
            if j >= Self.size { break }
            out += mapString(j)
            if let first = separators.first, first == start + k {
                out += " "
                separators.removeFirst()
            }
            start += k + 1
        }
        return out
    }

    /// Single-character entries in the prefix table (extended charset).
    public lazy var extendedChars: String = {
        var c = ""
        for p in prefix where p.size == 1 {
            c += String(decoding: [UInt16(strings[p.offset])], as: UTF16.self)
        }
        return c
    }()
}

enum Bits {
    static func intToBits(_ value: UInt64, expected: Int = 0) -> [Bool] {
        var bits: [Bool] = []
        var v = value
        while v != 0 {
            bits.insert(v & 1 == 1, at: 0)
            v >>= 1
        }
        if expected > 0 {
            while bits.count < expected { bits.insert(false, at: 0) }
        }
        return bits
    }

    static func bitsToInt(_ bits: [Bool]) -> UInt64 {
        var v: UInt64 = 0
        for b in bits { v = (v << 1) + (b ? 1 : 0) }
        return v
    }

    static func bitsToInt(_ bits: [Bool], _ start: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<n {
            let b = start + i < bits.count ? bits[start + i] : false
            v = (v << 1) + (b ? 1 : 0)
        }
        return v
    }

    /// QVector::mid semantics.
    static func mid(_ bits: [Bool], _ pos: Int, _ len: Int = -1) -> [Bool] {
        let size = bits.count
        if pos > size { return [] }
        var p = pos, l = len
        if p < 0 {
            if l >= 0 { l += p }
            p = 0
        }
        if l < 0 || l > size - p { l = size - p }
        if l <= 0 { return [] }
        return Array(bits[p..<(p + l)])
    }
}
