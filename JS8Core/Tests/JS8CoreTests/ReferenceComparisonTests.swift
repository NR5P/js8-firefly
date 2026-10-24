import XCTest
@testable import JS8Core

/// Cross-checks the Swift implementation against the original JS8Call code.
final class ReferenceComparisonTests: XCTestCase {
    var ref: RefHarness!

    override func setUpWithError() throws {
        try XCTSkipUnless(RefHarness.isAvailable, "reference harness not built")
        ref = try RefHarness()
    }

    func randomFrame<G: RandomNumberGenerator>(_ g: inout G) -> String {
        String((0..<12).map { _ in JS8Codec.alphabet[Int.random(in: 0..<64, using: &g)] })
    }

    func testEncodeMatchesReference() {
        var g = SeededGenerator(seed: 1)
        for submode in JS8Submode.allCases {
            for _ in 0..<200 {
                let frame = randomFrame(&g)
                let type = Int.random(in: 0..<8, using: &g)
                let tones = JS8Codec.encode(type: type, frame: frame, costas: submode.costas)!
                let expect = ref.call(["ENC", "\(type)", "\(submode.rawValue)", frame])
                XCTAssertEqual(tones.map(String.init).joined(), expect, "\(frame) type \(type) \(submode)")
            }
        }
    }

    func testDecodedTextMatchesReference() {
        var g = SeededGenerator(seed: 2)
        var mismatches = 0
        for i in 0..<4000 {
            let frame = randomFrame(&g)
            let type = i % 8
            let submode: JS8Submode = i % 3 == 0 ? .normal : .fast
            let dt = DecodedText(frame: frame, bits: type, submode: submode)
            let expect = ref.call(["DT", frame, "\(type)", "\(submode.rawValue)"])
            let got = [String(dt.frameType.rawValue), esc(dt.message), esc(dt.directed.joined(separator: "|")),
                       esc(dt.compoundCall), esc(dt.extra), "\(dt.isHeartbeat ? 1 : 0)\(dt.isAlt ? 1 : 0)"].joined(separator: "\t")
            if got != expect {
                mismatches += 1
                if mismatches < 15 { XCTFail("DT \(frame) \(type):\n got: \(got.debugDescription)\n ref: \(expect.debugDescription)") }
            }
        }
        XCTAssertEqual(mismatches, 0)
    }

    static let messages: [String] = [
        "HELLO WORLD HOW ARE YOU TODAY",
        "CQ CQ CQ EM73", "CQ DX FN42", "CQ", "HB EM73", "HEARTBEAT EM73",
        "@ALLCALL CQ CQ CQ EM73",
        "J1Y SNR?", "J1Y SNR -12", "J1Y SNR +05", "J1Y HEARTBEAT SNR -20", "J1Y GRID?", "J1Y INFO?", "J1Y STATUS?",
        "J1Y HEARING?", "J1Y ACK", "J1Y NACK", "J1Y 73", "J1Y AGN?", "J1Y QSL?", "J1Y QSL", "J1Y HW CPY?", "J1Y FB",
        "J1Y RR", "J1Y SK", "J1Y YES", "J1Y NO", "J1Y DIT DIT", "J1Y?",
        "J1Y MSG HELLO THERE THIS IS A STORED MESSAGE",
        "J1Y MSG TO:KN4CRD HELLO FROM THE FIELD",
        "J1Y QUERY MSGS", "J1Y QUERY MSGS?", "J1Y QUERY CALL W1AW", "J1Y QUERY MSG 12",
        "J1Y>KN4CRD HELLO VIA RELAY", "J1Y GRID EM73", "J1Y INFO QRP 5W WIRE ANTENNA",
        "J1Y STATUS IN THE FIELD", "J1Y CMD TEST", "J1Y HEARING W1AW K1JT",
        "@APRSIS GRID EM73", "@APRSIS CMD :EMAIL-2  :KN4CRD@EXAMPLE.COM TEST{01}",
        "@JS8NET HELLO", "@HB HEARTBEAT EM73",
        "VE3/W1AW: HELLO", "W1AW/P SNR?", "KN4CRD/P GRID?", "W1AW/MM HELLO",
        "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 1234567890",
        "WEATHER IS 72F SUNNY, WIND 5MPH. 73!",
        "TESTING lowercase text and punctuation ?!.-+/",
        "ÀÉÎÕÜ ACCENTED",
        "  LEADING AND TRAILING SPACES  ",
        "A", "AB CD", "E E E E E E E E E E E E E E E E E E",
        "CALLING K1JT W1AW N0CALL KN4CRD/P",
    ]

    func compareFrames(mycall: String, grid: String, selected: String, text: String, submode: JS8Submode,
                       forceIdentify: Bool, forceData: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let frames = Varicode.buildMessageFrames(mycall: mycall, mygrid: grid, selectedCall: selected, text: text,
                                                 forceIdentify: forceIdentify, forceData: forceData, submode: submode)
        let got = frames.map { f -> String in
            let dt = DecodedText(frame: f.frame, bits: f.type, submode: submode)
            return esc("\(f.frame):\(f.type):\(dt.message)")
        }.joined(separator: "\t")
        let expect = ref.call(["FRAMES", "\(submode.rawValue)", mycall, grid, selected,
                               forceIdentify ? "1" : "0", forceData ? "1" : "0", text])
        XCTAssertEqual(got, expect, "text=\(text.debugDescription) mycall=\(mycall) selected=\(selected) submode=\(submode)",
                       file: file, line: line)
    }

    func testMessageFramesMatchReference() {
        let calls = [("KN4CRD", "EM73"), ("W1AW/P", "FN31"), ("VE3/W1AW", "FN03"), ("K1JT", "FN20")]
        for submode in [JS8Submode.normal, .fast, .turbo, .slow] {
            for (mycall, grid) in calls {
                for text in Self.messages {
                    for selected in ["", "J1Y", "W1AW/MM", "@ALLCALL"] {
                        compareFrames(mycall: mycall, grid: grid, selected: selected, text: text, submode: submode,
                                      forceIdentify: true, forceData: false)
                    }
                    compareFrames(mycall: mycall, grid: grid, selected: "", text: text, submode: submode,
                                  forceIdentify: false, forceData: true)
                }
            }
        }
    }

    func testRandomTextFramesMatchReference() {
        var g = SeededGenerator(seed: 7)
        let words = ["THE", "AND", "RADIO", "ANTENNA", "73", "QTH", "NAME", "IS", "JOHN", "RIG", "QRP", "5W",
                     "WX", "SUNNY", "COPY", "TNX", "FER", "QSO", "CQ", "DE", "K", "BK", "HELLO", "WORLD",
                     "ZEBRA", "XYLOPHONE", "QUIZZICAL", "?", "!", ".", ",", "-", "+", "/", "@", "#", "12345",
                     "EM73", "FN42", "J1Y", "KN4CRD", "SNR", "MSG", "ACK"]
        for i in 0..<600 {
            let n = Int.random(in: 1...14, using: &g)
            let text = (0..<n).map { _ in words[Int.random(in: 0..<words.count, using: &g)] }.joined(separator: " ")
            let submode = JS8Submode.allCases[i % 5]
            let selected = i % 4 == 0 ? "J1Y" : ""
            compareFrames(mycall: "KN4CRD", grid: "EM73", selected: selected, text: text, submode: submode,
                          forceIdentify: i % 2 == 0, forceData: i % 7 == 0)
        }
    }
}

func esc(_ s: String) -> String {
    var out = ""
    for c in s.unicodeScalars {
        switch c {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default: out.unicodeScalars.append(c)
        }
    }
    return out
}

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
