import XCTest
@testable import JS8Core

final class WatchMatcherTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(WatchMatcher.normalize(" k4lmb "), "K4LMB")
        XCTAssertEqual(WatchMatcher.normalize("#ares"), "ARES")
        XCTAssertEqual(WatchMatcher.normalize("@ares"), "@ARES")
        XCTAssertNil(WatchMatcher.normalize(""))
        XCTAssertNil(WatchMatcher.normalize("@"))
        XCTAssertNil(WatchMatcher.normalize("TWO WORDS"))
    }

    func testCallsigns() {
        XCTAssertEqual(WatchMatcher.firstMatch(in: "K4LMB: NR5P GM NATHAN", terms: ["K4LMB"]), 0)
        XCTAssertEqual(WatchMatcher.firstMatch(in: "K4LMB/P: @HB HEARTBEAT EM73", terms: ["K4LMB"]), 0)
        XCTAssertEqual(WatchMatcher.firstMatch(in: "W7GTK: K4LMB SNR?", terms: ["K4LMB"]), 0)
        XCTAssertNil(WatchMatcher.firstMatch(in: "KK4LMB: HELLO", terms: ["K4LMB"]))
        XCTAssertNil(WatchMatcher.firstMatch(in: "K4LMB: HELLO", terms: ["K4LMB/P"]))
    }

    func testGroupsAndWords() {
        XCTAssertEqual(WatchMatcher.firstMatch(in: "N0VBQ: @ARES NET TONIGHT", terms: ["ARES"]), 0)
        XCTAssertEqual(WatchMatcher.firstMatch(in: "N0VBQ: @ARES NET TONIGHT", terms: ["@ARES"]), 0)
        XCTAssertEqual(WatchMatcher.firstMatch(in: "N0VBQ: W7GTK ARES DRILL SAT.", terms: ["ARES"]), 0)
        XCTAssertNil(WatchMatcher.firstMatch(in: "N0VBQ: W7GTK ARES DRILL", terms: ["@ARES"]))
        XCTAssertNil(WatchMatcher.firstMatch(in: "N0VBQ: W7GTK SQUARES", terms: ["ARES"]))
    }

    func testFirstTermWins() {
        XCTAssertEqual(WatchMatcher.firstMatch(in: "K4LMB: @ARES CHECK IN", terms: ["@ARES", "K4LMB"]), 0)
        XCTAssertEqual(WatchMatcher.firstMatch(in: "K4LMB: @ARES CHECK IN", terms: ["W7GTK", "K4LMB"]), 1)
        XCTAssertNil(WatchMatcher.firstMatch(in: "K4LMB: HELLO", terms: []))
    }
}
