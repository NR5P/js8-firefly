import XCTest
@testable import JS8Core

/// Messages stored locally with "Store Message" (no transmission), then picked
/// up over the air by the recipient. Reuses StationTests' simulated air.
extension StationTests {
    func bandText(_ s: JS8Station) -> String { s.bandConversation.map(\.text).joined(separator: "\n") }
    func heard(_ s: JS8Station) -> String { conversationText(s) + "\n--band--\n" + bandText(s) }

    // MARK: Storing

    func testStoreMessageSavesWithoutTransmitting() {
        let b = makeStation("J1Y", "PM95")
        b.dialFrequency = 7_078_000
        b.offset = 1234
        let id = b.storeMessage(to: "w1aw", text: "  meet on 40m\nat 2000z  ")
        XCTAssertEqual(id, 1)
        let m = b.inbox.messages.first
        XCTAssertEqual(m?.type, "STORE")
        XCTAssertEqual(m?.from, "J1Y")
        XCTAssertEqual(m?.to, "W1AW")
        XCTAssertEqual(m?.path, "J1Y")
        XCTAssertEqual(m?.cmd, " MSG ")
        XCTAssertEqual(m?.text, "MEET ON 40M AT 2000Z")
        XCTAssertEqual(m?.dial, 7_078_000)
        XCTAssertEqual(m?.offset, 1234)
        XCTAssertEqual(m?.utc, clock.now)
        // Nothing queued for the air.
        XCTAssertNil(b.pollTransmit(now: clock.now))
        b.tick()
        XCTAssertNil(b.pollTransmit(now: clock.now))
        XCTAssertEqual(b.inbox.unreadCount, 0, "a held message must not count as unread for me")
    }

    func testStoreMessageUsesBaseCallsign() {
        let b = makeStation("J1Y", "PM95")
        b.storeMessage(to: "W1AW/P", text: "ONE")
        b.storeMessage(to: "VE3/W1AW", text: "TWO")
        XCTAssertEqual(b.inbox.messages.map(\.to), ["W1AW", "W1AW"])
        b.storeMessage(to: "@ragchew", text: "THREE")
        XCTAssertEqual(b.inbox.messages.last?.to, "@RAGCHEW")
    }

    func testStoreMessageRejectsBadInput() {
        let b = makeStation("J1Y", "PM95")
        XCTAssertNil(b.storeMessage(to: "", text: "HI"))
        XCTAssertNil(b.storeMessage(to: "W1AW", text: "   \n "))
        XCTAssertNil(b.storeMessage(to: "HELLO", text: "HI"))
        XCTAssertNil(b.storeMessage(to: "J1Y", text: "HI"), "storing for yourself")
        XCTAssertNil(b.storeMessage(to: "J1Y/P", text: "HI"), "storing for your own portable call")
        XCTAssertNil(b.storeMessage(to: "@ALLCALL", text: "HI"))
        XCTAssertNil(b.storeMessage(to: "@HB", text: "HI"))
        XCTAssertNil(b.storeMessage(to: "@APRSIS", text: "HI"))
        XCTAssertNil(b.storeMessage(to: "@", text: "HI"))
        XCTAssertTrue(b.inbox.messages.isEmpty)

        let noCall = makeStation("", "PM95")
        XCTAssertNil(noCall.storeMessage(to: "W1AW", text: "HI"), "no callsign set")
    }

    func testStoreRecipientProblemMessages() {
        XCTAssertNil(JS8Station.storeRecipientProblem("W1AW"))
        XCTAssertNil(JS8Station.storeRecipientProblem(" w1aw "))
        XCTAssertNil(JS8Station.storeRecipientProblem("VE3/KN4CRD"))
        XCTAssertNil(JS8Station.storeRecipientProblem("@GROUP"))
        XCTAssertNotNil(JS8Station.storeRecipientProblem(""))
        XCTAssertNotNil(JS8Station.storeRecipientProblem("Q"))
        XCTAssertNotNil(JS8Station.storeRecipientProblem("W1AW W2XYZ"))
        XCTAssertEqual(JS8Station.storeRecipientProblem("N0CALL1234"), "N0CALL1234 isn't a valid callsign.")
        XCTAssertEqual(JS8Station.storeRecipientProblem("NR5P", mycall: "nr5p"), "That's your own callsign.")
        XCTAssertNil(JS8Station.storeRecipientProblem("W1AW", mycall: "NR5P"))
    }

    func testStoredMessageSurvivesRelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var cfg = StationConfig()
        cfg.callsign = "J1Y"
        let b = JS8Station(config: cfg, inbox: Inbox(url: url), clock: { [unowned self] in self.clock.now })
        b.storeMessage(to: "W1AW", text: "STILL HERE")
        let reopened = Inbox(url: url)
        XCTAssertEqual(reopened.messages.count, 1)
        XCTAssertEqual(reopened.messages.first?.type, "STORE")
        XCTAssertEqual(reopened.messages.first?.text, "STILL HERE")
        XCTAssertEqual(reopened.nextMessageId(for: "W1AW"), 1)
    }

    // MARK: Pick-up over the air

    func testStoredMessageFetchedWithQueryMsgs() {
        let b = makeStation("J1Y", "PM95")
        let c = makeStation("W1AW", "FN31")
        XCTAssertEqual(b.storeMessage(to: "W1AW", text: "NET MOVED TO 7110 SUNDAY 2000Z"), 1)

        c.selectedCallsign = "J1Y"
        c.send("QUERY MSGS")
        run([b, c], periods: 6)
        XCTAssertTrue(conversationText(c).contains("J1Y: W1AW YES MSG ID 1"), heard(c))

        c.send("QUERY MSG 1")
        run([b, c], periods: 10)
        XCTAssertTrue(conversationText(c).contains("NET MOVED TO 7110 SUNDAY 2000Z FROM J1Y"), heard(c))
        XCTAssertEqual(b.inbox.messages.first?.type, "DELIVERED")

        // Nothing left once it's delivered.
        c.send("QUERY MSGS")
        run([b, c], periods: 6)
        XCTAssertTrue(conversationText(c).contains("J1Y: W1AW NO"), heard(c))
    }

    func testHeartbeatAckAnnouncesStoredMessage() {
        let b = makeStation("J1Y", "PM95")
        let c = makeStation("W1AW", "FN31")
        b.storeMessage(to: "W1AW", text: "CALL ME")
        c.sendHeartbeat()
        run([b, c], periods: 4)
        XCTAssertTrue(heard(c).contains("MSG ID 1"), heard(c))
        XCTAssertEqual(b.inbox.messages.first?.type, "STORE", "announcing must not mark it delivered")
    }

    func testOnlyRecipientCanFetchStoredMessage() {
        let b = makeStation("J1Y", "PM95")
        let d = makeStation("KN4CRD", "EM73")
        b.storeMessage(to: "W1AW", text: "PRIVATE FOR W1AW")
        d.selectedCallsign = "J1Y"
        d.send("QUERY MSGS")
        run([b, d], periods: 6)
        XCTAssertTrue(conversationText(d).contains("J1Y: KN4CRD NO"), heard(d))
        d.send("QUERY MSG 1")
        run([b, d], periods: 8)
        XCTAssertFalse(heard(d).contains("PRIVATE FOR W1AW"), heard(d))
        XCTAssertEqual(b.inbox.messages.first?.type, "STORE")
    }

    func testPortableRecipientFetchesMessageStoredForBaseCall() {
        let b = makeStation("J1Y", "PM95")
        let c = makeStation("W1AW/P", "FN31")
        b.storeMessage(to: "W1AW", text: "WORKS PORTABLE TOO")
        c.selectedCallsign = "J1Y"
        c.send("QUERY MSGS")
        run([b, c], periods: 6)
        XCTAssertTrue(heard(c).contains("YES MSG ID 1"), heard(c))
        c.send("QUERY MSG 1")
        run([b, c], periods: 10)
        XCTAssertTrue(heard(c).contains("WORKS PORTABLE TOO FROM J1Y"), heard(c))
        XCTAssertEqual(b.inbox.messages.first?.type, "DELIVERED")
    }

    func testBaseCallFetchesMessageStoredForPortableCall() {
        let b = makeStation("J1Y", "PM95")
        let c = makeStation("W1AW", "FN31")
        b.storeMessage(to: "W1AW/P", text: "TYPED THE PORTABLE CALL")
        c.selectedCallsign = "J1Y"
        c.send("QUERY MSG 1")
        run([b, c], periods: 10)
        XCTAssertTrue(heard(c).contains("TYPED THE PORTABLE CALL FROM J1Y"), heard(c))
        XCTAssertEqual(b.inbox.messages.first?.type, "DELIVERED")
    }

    func testSeveralStoredMessagesChainWithNextId() {
        let b = makeStation("J1Y", "PM95")
        let c = makeStation("W1AW", "FN31")
        b.storeMessage(to: "W1AW", text: "FIRST ONE")
        b.storeMessage(to: "W1AW", text: "SECOND ONE")
        c.selectedCallsign = "J1Y"
        c.send("QUERY MSGS")
        run([b, c], periods: 6)
        XCTAssertTrue(conversationText(c).contains("YES MSG ID 1 +1"), heard(c))
        c.send("QUERY MSG 1")
        run([b, c], periods: 10)
        XCTAssertTrue(conversationText(c).contains("FIRST ONE FROM J1Y NEXT MSG ID 2"), heard(c))
        c.send("QUERY MSG 2")
        run([b, c], periods: 10)
        XCTAssertTrue(conversationText(c).contains("SECOND ONE FROM J1Y"), heard(c))
        XCTAssertEqual(b.inbox.messages.map(\.type), ["DELIVERED", "DELIVERED"])
    }

    func testStoredAndRelayedMessagesShareTheQueue() {
        let a = makeStation("KN4CRD", "EM73")
        let b = makeStation("J1Y", "PM95")
        let c = makeStation("W1AW", "FN31")
        b.storeMessage(to: "W1AW", text: "FROM THE HOLDER")
        a.selectedCallsign = "J1Y"
        a.send("MSG TO:W1AW FROM THE RELAYER")
        run([a, b, c], periods: 8)
        XCTAssertEqual(b.inbox.messages.map(\.type), ["STORE", "STORE"], b.inbox.messages.map(\.text).description)
        c.selectedCallsign = "J1Y"
        c.send("QUERY MSGS")
        run([a, b, c], periods: 6)
        XCTAssertTrue(conversationText(c).contains("YES MSG ID 1 +1"), heard(c))
    }

    func testGroupStoredMessage() {
        let b = makeStation("J1Y", "PM95")
        let c = makeStation("W1AW", "FN31")
        b.config.groups = ["@RAGCHEW"]
        c.config.groups = ["@RAGCHEW"]
        b.storeMessage(to: "@RAGCHEW", text: "GROUP NOTICE")
        c.selectedCallsign = "@RAGCHEW"
        c.send("QUERY MSGS")
        run([b, c], periods: 6)
        XCTAssertTrue(heard(c).contains("YES MSG ID 1"), heard(c))
        c.selectedCallsign = "J1Y"
        c.send("QUERY MSG 1")
        run([b, c], periods: 10)
        XCTAssertTrue(heard(c).contains("GROUP NOTICE FROM J1Y"), heard(c))
        XCTAssertEqual(b.inbox.messages.first?.groupDelivered, ["W1AW"])
        XCTAssertEqual(b.inbox.messages.first?.type, "STORE", "group messages stay for other members")
    }

    func testStoredMessageWithPunctuationArrivesIntact() {
        let b = makeStation("J1Y", "PM95")
        let c = makeStation("W1AW", "FN31")
        let text = "QTH CHANGED, NEW GRID FN42? CALL 555-1212. 73!"
        b.storeMessage(to: "W1AW", text: text)
        c.selectedCallsign = "J1Y"
        c.send("QUERY MSG 1")
        run([b, c], periods: 14)
        XCTAssertTrue(conversationText(c).contains(text + " FROM J1Y"), heard(c))
    }
}
