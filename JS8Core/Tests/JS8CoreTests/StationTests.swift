import XCTest
@testable import JS8Core

/// End-to-end station tests: frames are modulated, mixed with noise, decoded
/// and fed to the other stations, exercising the full on-air path.
final class StationTests: XCTestCase {
    final class SimClock {
        var now: Date
        init(_ d: Date) { now = d }
    }

    var clock: SimClock!
    var noise = SeededGenerator(seed: 99)
    var decoders: [JS8Submode: JS8ModeDecoder] = [:]

    override func setUp() {
        // Start at a period boundary.
        clock = SimClock(Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 30)))
    }

    func makeStation(_ call: String, _ grid: String) -> JS8Station {
        var cfg = StationConfig()
        cfg.callsign = call
        cfg.grid = grid
        cfg.info = "QRP 5W IPHONE"
        cfg.status = "PORTABLE"
        let s = JS8Station(config: cfg, inbox: Inbox(url: nil), clock: { [unowned self] in self.clock.now })
        s.txDelay = 0
        return s
    }

    /// Run the air for up to `periods` periods.
    func run(_ stations: [JS8Station], periods: Int, submode: JS8Submode = .normal) {
        let p = Double(submode.period)
        let into = clock.now.timeIntervalSince1970.truncatingRemainder(dividingBy: p)
        if into != 0 { clock.now += p - into }
        for _ in 0..<periods {
            for s in stations { s.tick() }
            var audio = [Float](repeating: 0, count: submode.samplesPerPeriod)
            var transmitters: [JS8Station] = []
            for s in stations {
                if let req = s.pollTransmit(now: clock.now) {
                    let wave = JS8Modulator.synthesize(tones: req.tones, frequency: Double(req.offset), submode: req.submode, sampleRate: 12000)
                    let start = submode.startDelayMS * 12
                    for (i, v) in wave.enumerated() where start + i < audio.count { audio[start + i] += 400 * v }
                    transmitters.append(s)
                }
            }
            for i in audio.indices { audio[i] += 300 * gaussian(&noise) }
            let decoder = decoders[submode] ?? JS8ModeDecoder(submode: submode)
            decoders[submode] = decoder
            var decodes: [JS8RawDecode] = []
            _ = audio.withUnsafeBufferPointer { decoder.decode(samples: $0, nfqso: 1500) { decodes.append($0) } }
            clock.now += submode.txDuration + 0.2
            for s in transmitters { s.transmissionFinished() }
            for s in stations where !transmitters.contains(where: { $0 === s }) {
                for d in decodes { s.handleDecode(d) }
            }
            clock.now += p - submode.txDuration - 0.2
            for s in stations { s.tick() }
        }
    }

    func conversationText(_ s: JS8Station) -> String { s.conversation.map(\.text).joined(separator: "\n") }

    func testSNRQueryAutoReply() {
        let a = makeStation("KN4CRD", "EM73")
        let b = makeStation("J1Y", "PM95")
        a.selectedCallsign = "J1Y"
        XCTAssertTrue(a.send("SNR?"))
        run([a, b], periods: 3)
        XCTAssertTrue(conversationText(b).contains("KN4CRD: J1Y SNR?"), conversationText(b))
        XCTAssertTrue(conversationText(a).contains("J1Y: KN4CRD SNR"), conversationText(a))
        XCTAssertNotNil(a.callActivity["J1Y"])
    }

    func testGridInfoStatusHearing() {
        let a = makeStation("KN4CRD", "EM73")
        let b = makeStation("J1Y", "PM95")
        a.selectedCallsign = "J1Y"
        a.send("GRID?")
        run([a, b], periods: 3)
        XCTAssertTrue(conversationText(a).contains("J1Y: KN4CRD GRID PM95"), conversationText(a))
        a.send("INFO?")
        run([a, b], periods: 5)
        XCTAssertTrue(conversationText(a).contains("KN4CRD INFO QRP 5W IPHONE"), conversationText(a))
        a.send("STATUS?")
        run([a, b], periods: 4)
        XCTAssertTrue(conversationText(a).contains("KN4CRD STATUS PORTABLE"), conversationText(a))
    }

    func testDirectedMessageGoesToInboxAndAcks() {
        let a = makeStation("KN4CRD", "EM73")
        let b = makeStation("J1Y", "PM95")
        a.selectedCallsign = "J1Y"
        a.send("MSG HELLO FROM MY IPHONE ON THE TRAIL")
        run([a, b], periods: 8)
        XCTAssertEqual(b.inbox.messages.count, 1)
        XCTAssertEqual(b.inbox.messages.first?.text, "HELLO FROM MY IPHONE ON THE TRAIL")
        XCTAssertEqual(b.inbox.messages.first?.from, "KN4CRD")
        XCTAssertTrue(conversationText(a).contains("J1Y: KN4CRD ACK"), conversationText(a))
    }

    func testStoreAndForward() {
        let a = makeStation("KN4CRD", "EM73")
        let b = makeStation("J1Y", "PM95")
        let c = makeStation("W1AW", "FN31")
        a.selectedCallsign = "J1Y"
        a.send("MSG TO:W1AW MEET ON 40M AT 2000Z")
        run([a, b, c], periods: 8)
        XCTAssertEqual(b.inbox.messages.first?.type, "STORE")
        XCTAssertEqual(b.inbox.messages.first?.to, "W1AW")

        c.selectedCallsign = "J1Y"
        c.send("QUERY MSGS")
        run([a, b, c], periods: 6)
        XCTAssertTrue(conversationText(c).contains("J1Y: W1AW YES MSG ID 1"), conversationText(c))

        c.send("QUERY MSG 1")
        run([a, b, c], periods: 10)
        XCTAssertTrue(conversationText(c).contains("MEET ON 40M AT 2000Z FROM KN4CRD"), conversationText(c))
        XCTAssertEqual(b.inbox.messages.first?.type, "DELIVERED")
    }

    func testHeartbeatAndAck() {
        let a = makeStation("KN4CRD", "EM73")
        let b = makeStation("J1Y", "PM95")
        b.sendHeartbeat()
        run([a, b], periods: 4)
        XCTAssertNotNil(a.callActivity["J1Y"])
        XCTAssertEqual(a.callActivity["J1Y"]?.grid, "PM95")
        // A acknowledges B's heartbeat.
        XCTAssertNotNil(b.callActivity["KN4CRD"], "heartbeat ack not heard")
        let rows = b.bandActivityRows(now: clock.now)
        XCTAssertTrue(rows.contains { $0.text.contains("J1Y HEARTBEAT SNR") }, "\(rows)")
    }

    func testCQAndCompoundCallsign() {
        let a = makeStation("VE3/KN4CRD", "EM73")
        let b = makeStation("J1Y", "PM95")
        a.sendCQ()
        run([a, b], periods: 3)
        XCTAssertNotNil(b.callActivity["VE3/KN4CRD"]?.cqTimestamp, "\(b.callActivity)")

        a.selectedCallsign = "J1Y"
        a.send("SNR?")
        run([a, b], periods: 5)
        XCTAssertTrue(conversationText(a).contains("VE3/KN4CRD SNR"), conversationText(a) + "\n--\n" + conversationText(b))
    }

    func testFreeTextChat() {
        let a = makeStation("KN4CRD", "EM73")
        let b = makeStation("J1Y", "PM95")
        b.offset = 1500
        a.offset = 1500
        a.selectedCallsign = "J1Y"
        a.send("GOOD MORNING, NAME IS JORDAN. WX IS SUNNY 72F")
        run([a, b], periods: 8)
        XCTAssertTrue(conversationText(b).contains("GOOD MORNING, NAME IS JORDAN. WX IS SUNNY 72F"), conversationText(b))
    }

    func testFastModes() {
        for mode in [JS8Submode.fast, .turbo, .slow, .ultra] {
            let a = makeStation("KN4CRD", "EM73")
            let b = makeStation("J1Y", "PM95")
            a.submode = mode
            b.submode = mode
            a.selectedCallsign = "J1Y"
            a.send("SNR?")
            run([a, b], periods: 4, submode: mode)
            XCTAssertTrue(conversationText(a).contains("J1Y: KN4CRD SNR"), "\(mode): " + conversationText(a))
        }
    }
}
