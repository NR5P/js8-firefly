import Foundation

/// Matches decoded text against a watch list of callsigns, @GROUPs and words,
/// like JS8Call's highlight words: whole words only, case-insensitive.
///
/// A plain word also matches the group of that name ("ARES" matches "@ARES"),
/// and a base callsign also matches its portable forms ("K4LMB" matches "K4LMB/P").
public enum WatchMatcher {
    /// Upper-cases a watch term and drops a leading "#"; nil if it is empty or more than one word.
    public static func normalize(_ term: String) -> String? {
        var t = term.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        while t.hasPrefix("#") { t.removeFirst() }
        guard !t.isEmpty, t != "@", !t.contains(where: \.isWhitespace) else { return nil }
        return t
    }

    /// The words of a decoded line: runs of letters, digits, "/" and "@".
    public static func words(in text: String) -> [String] {
        text.uppercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) && $0 != "/" && $0 != "@" }
            .map(String.init)
    }

    public static func matches(word: String, term: String) -> Bool {
        if word == term { return true }
        if term.hasPrefix("@") { return false }
        if word == "@" + term { return true }
        return word.contains("/") && !term.contains("/") && Varicode.baseCallsign(word) == term
    }

    /// Index of the first of `terms` (already normalized) found in `text`.
    public static func firstMatch(in text: String, terms: [String]) -> Int? {
        guard !terms.isEmpty else { return nil }
        let ws = words(in: text)
        return terms.firstIndex { term in ws.contains { matches(word: $0, term: term) } }
    }
}
