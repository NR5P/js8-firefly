import Foundation

// Small helpers that reproduce the QString / QRegularExpression semantics the
// JS8Call protocol code relies on (UTF-16 indexing, mid() clamping, named
// captures). Keeping these semantics identical is what keeps frame packing
// byte-for-byte compatible with the desktop application.

extension String {
    var u16Count: Int { utf16.count }

    /// QString::mid(pos, len) semantics (len < 0 means "to the end").
    func qMid(_ pos: Int, _ len: Int = -1) -> String {
        let ns = self as NSString
        let size = ns.length
        if pos >= size { return "" }
        var p = pos
        var l = len
        if p < 0 {
            if l >= 0 { l += p }
            p = 0
        }
        if l < 0 || l > size - p { l = size - p }
        if l <= 0 { return "" }
        return ns.substring(with: NSRange(location: p, length: l))
    }

    func qLeft(_ n: Int) -> String {
        if n < 0 || n >= u16Count { return self }
        return (self as NSString).substring(to: n)
    }

    func qRight(_ n: Int) -> String {
        let size = u16Count
        if n < 0 || n >= size { return self }
        return (self as NSString).substring(from: size - n)
    }

    func qAt(_ i: Int) -> unichar { (self as NSString).character(at: i) }

    func qIndexOf(_ s: String, from: Int = 0) -> Int {
        let ns = self as NSString
        guard from <= ns.length else { return -1 }
        let r = ns.range(of: s, options: [.literal], range: NSRange(location: from, length: ns.length - from))
        return r.location == NSNotFound ? -1 : r.location
    }

    func qTrimmed() -> String {
        // QString::trimmed removes Unicode whitespace from both ends.
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func qRepeated(_ n: Int) -> String { n > 0 ? String(repeating: self, count: n) : "" }
}

/// Wrapper over NSRegularExpression with QRegularExpression-like accessors.
final class QRegex: @unchecked Sendable {
    let re: NSRegularExpression

    init(_ pattern: String) {
        do {
            re = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            fatalError("Invalid regex \(pattern): \(error)")
        }
    }

    func match(_ s: String, from: Int = 0) -> QMatch? {
        let ns = s as NSString
        guard from <= ns.length else { return nil }
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: from, length: ns.length - from)) else { return nil }
        return QMatch(m, ns)
    }

    func globalMatch(_ s: String) -> [QMatch] {
        let ns = s as NSString
        return re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)).map { QMatch($0, ns) }
    }

    func hasMatch(_ s: String) -> Bool { match(s) != nil }
}

struct QMatch {
    let result: NSTextCheckingResult
    let source: NSString

    init(_ r: NSTextCheckingResult, _ s: NSString) {
        result = r
        source = s
    }

    func captured(_ name: String) -> String {
        let r = result.range(withName: name)
        if r.location == NSNotFound { return "" }
        return source.substring(with: r)
    }

    func captured(_ index: Int = 0) -> String {
        let r = result.range(at: index)
        if r.location == NSNotFound { return "" }
        return source.substring(with: r)
    }

    func capturedStart(_ name: String) -> Int {
        let r = result.range(withName: name)
        return r.location == NSNotFound ? -1 : r.location
    }

    func capturedLength(_ name: String) -> Int {
        let r = result.range(withName: name)
        return r.location == NSNotFound ? 0 : r.length
    }

    var capturedLength0: Int { result.range.length }
    var capturedStart0: Int { result.range.location }
}
