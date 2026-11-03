import XCTest
@testable import JS8Core

final class WatchColorTests: XCTestCase {
    /// Theme.tx in the app: the coral used for traffic addressed to our call.
    private let directedRed = (red: 1.0, green: 0.36, blue: 0.30)
    /// Theme.bg in the app.
    private let background = (red: 0.035, green: 0.045, blue: 0.075)

    func testCrimsonIsOffered() {
        XCTAssertEqual(WatchColor.allCases, [.gold, .magenta, .violet, .lime, .orange, .crimson, .pearl])
        XCTAssertEqual(WatchColor.crimson.name, "Crimson")
    }

    func testNewItemsDefaultToGold() {
        XCTAssertEqual(WatchItem(term: "EMERGENCY").color, .gold)
    }

    func testCrimsonRoundTrips() throws {
        let item = WatchItem(term: "EMERGENCY", color: .crimson)
        let data = try JSONEncoder().encode([item])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"color\":\"crimson\""))
        XCTAssertEqual(try JSONDecoder().decode([WatchItem].self, from: data), [item])
    }

    func testListsSavedBeforeCrimsonStillLoad() throws {
        let saved = """
        [{"id":"96975E04-FBAE-43D9-B4D1-E72FD70934C9","term":"K4LMB","color":"gold"},
         {"id":"AF505908-C599-4B2B-9D4A-944E805C0FE8","term":"ARES","color":"magenta"}]
        """
        let items = try JSONDecoder().decode([WatchItem].self, from: Data(saved.utf8))
        XCTAssertEqual(items.map(\.term), ["K4LMB", "ARES"])
        XCTAssertEqual(items.map(\.color), [.gold, .magenta])
    }

    func testUnknownColorFallsBackToGold() throws {
        let saved = #"[{"id":"96975E04-FBAE-43D9-B4D1-E72FD70934C9","term":"K4LMB","color":"teal"}]"#
        let items = try JSONDecoder().decode([WatchItem].self, from: Data(saved.utf8))
        XCTAssertEqual(items.first?.color, .gold)
    }

    func testCrimsonStandsApartFromDirectedRed() {
        let crimson = WatchColor.crimson.rgb
        XCTAssertGreaterThan(distance(crimson, directedRed), 0.3)
        // A deep red: clearly darker than the coral, not just a shade off it.
        XCTAssertGreaterThan(contrast(directedRed, crimson), 1.5)
    }

    func testCrimsonStandsApartFromOtherWatchColors() {
        for other in WatchColor.allCases where other != .crimson {
            XCTAssertGreaterThan(distance(WatchColor.crimson.rgb, other.rgb), 0.3, "crimson vs \(other)")
        }
    }

    func testCrimsonShowsOnTheDarkBackground() {
        // WCAG's 3:1 for non-text UI.
        XCTAssertGreaterThanOrEqual(contrast(WatchColor.crimson.rgb, background), 3)
    }

    func testEmergencyMatches() {
        let term = WatchMatcher.normalize("emergency")
        XCTAssertEqual(term, "EMERGENCY")
        XCTAssertEqual(WatchMatcher.firstMatch(in: "W7GTK: @ARES EMERGENCY NET NOW ON 3578", terms: [term!]), 0)
        XCTAssertNil(WatchMatcher.firstMatch(in: "W7GTK: @ARES EMERGENCYNET", terms: [term!]))
    }

    private typealias RGB = (red: Double, green: Double, blue: Double)

    private func distance(_ a: RGB, _ b: RGB) -> Double {
        ((a.red - b.red) * (a.red - b.red) + (a.green - b.green) * (a.green - b.green)
            + (a.blue - b.blue) * (a.blue - b.blue)).squareRoot()
    }

    /// WCAG relative luminance.
    private func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
