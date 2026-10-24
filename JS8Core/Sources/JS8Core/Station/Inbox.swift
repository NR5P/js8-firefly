import Foundation

/// Store-and-forward message storage, equivalent to JS8Call's inbox.db3.
/// Message types: "UNREAD", "READ", "STORE" (held for another station) and
/// "DELIVERED".
public struct InboxMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: Int
    public var type: String
    public var utc: Date
    public var from: String
    public var to: String
    public var path: String
    public var text: String
    public var cmd: String
    public var grid: String
    public var extra: String
    public var snr: Int
    public var dial: UInt64
    public var offset: Int
    public var submode: Int
    public var tdrift: Float
    /// Callsigns that have received this group message.
    public var groupDelivered: [String] = []
}

public final class Inbox: @unchecked Sendable {
    public private(set) var messages: [InboxMessage] = []
    private var nextId = 1
    private let url: URL?
    private let lock = NSLock()
    public var onChange: (() -> Void)?

    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([InboxMessage].self, from: data) {
            messages = saved
            nextId = (saved.map(\.id).max() ?? 0) + 1
        }
    }

    private func save() {
        guard let url else { return }
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: url, options: .atomic)
        }
        onChange?()
    }

    @discardableResult
    public func append(type: String, _ d: CommandDetail) -> Int {
        lock.lock()
        let id = nextId
        nextId += 1
        messages.append(InboxMessage(id: id, type: type, utc: d.utc ?? Date(), from: d.from, to: d.to, path: d.relayPath,
                                     text: d.text, cmd: d.cmd, grid: d.grid, extra: d.extra, snr: d.snr, dial: d.dial,
                                     offset: d.offset, submode: d.submode.rawValue, tdrift: d.tdrift))
        lock.unlock()
        save()
        return id
    }

    public func message(_ id: Int) -> InboxMessage? { messages.first { $0.id == id } }

    public func setType(_ id: Int, _ type: String) {
        lock.lock()
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].type = type }
        lock.unlock()
        save()
    }

    public func delete(_ id: Int) {
        lock.lock()
        messages.removeAll { $0.id == id }
        lock.unlock()
        save()
    }

    public func markGroupDelivered(_ id: Int, to callsign: String) {
        lock.lock()
        if let i = messages.firstIndex(where: { $0.id == id }), !messages[i].groupDelivered.contains(callsign) {
            messages[i].groupDelivered.append(callsign)
        }
        lock.unlock()
        save()
    }

    private func likeMatch(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    private func stored(to callsign: String) -> [InboxMessage] {
        messages.filter { $0.type == "STORE" && likeMatch($0.to, callsign) && !$0.text.qTrimmed().isEmpty }
            .sorted { $0.id < $1.id }
    }

    func nextMessageId(for callsign: String) -> Int {
        if let m = stored(to: callsign).first { return m.id }
        if let m = stored(to: Varicode.baseCallsign(callsign)).first { return m.id }
        return -1
    }

    func lookaheadMessageId(for callsign: String, after id: Int) -> Int {
        if let m = stored(to: callsign).first(where: { $0.id != id }) { return m.id }
        if let m = stored(to: Varicode.baseCallsign(callsign)).first(where: { $0.id != id }) { return m.id }
        return -1
    }

    func countUnread(for callsign: String) -> Int { stored(to: callsign).count }

    private func groupStored(_ group: String, _ callsign: String, now: Date) -> [InboxMessage] {
        let cutoff = now.addingTimeInterval(-2 * 86400)
        return stored(to: group).filter { $0.utc > cutoff && !$0.groupDelivered.contains(callsign) }
    }

    func nextGroupMessageId(_ group: String, for callsign: String, now: Date) -> Int {
        groupStored(group, callsign, now: now).first?.id ?? -1
    }

    func lookaheadGroupMessageId(_ group: String, for callsign: String, after id: Int, now: Date) -> Int {
        if let m = groupStored(group, callsign, now: now).first(where: { $0.id != id }) { return m.id }
        if let m = groupStored(group, Varicode.baseCallsign(callsign), now: now).first(where: { $0.id != id }) { return m.id }
        return -1
    }

    func countGroupUnread(_ group: String, for callsign: String, now: Date) -> Int {
        groupStored(group, callsign, now: now).count
    }

    public var unreadCount: Int { messages.filter { $0.type == "UNREAD" }.count }
}
