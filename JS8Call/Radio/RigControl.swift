import Foundation
import Observation

/// How the app talks to the radio for frequency and PTT.
enum RigConnection: String, Codable, CaseIterable, Identifiable {
    case none
    case serial      // macOS USB serial (CAT)
    case bluetooth   // BLE serial adapter on the CAT port (CAT)
    case tcpSerial   // raw serial-over-TCP bridge (ser2net, WiFi CAT dongles) (CAT)
    case rigctld     // Hamlib rigctld
    case flrig       // flrig XML-RPC

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None (set dial manually)"
        case .serial: return "USB serial CAT"
        case .bluetooth: return "Bluetooth LE serial adapter"
        case .tcpSerial: return "Serial-over-network bridge"
        case .rigctld: return "Hamlib rigctld (network)"
        case .flrig: return "flrig (network)"
        }
    }

    var usesCATProtocol: Bool { self == .serial || self == .bluetooth || self == .tcpSerial }

    static var available: [RigConnection] {
        #if os(macOS)
        return allCases
        #else
        return allCases.filter { $0 != .serial }
        #endif
    }
}

enum CATProtocol: String, Codable, CaseIterable, Identifiable {
    case yaesu, kenwood, icom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .yaesu: return "Yaesu (new CAT)"
        case .kenwood: return "Kenwood / Elecraft / QRP Labs"
        case .icom: return "Icom CI-V (and Xiegu)"
        }
    }
}

/// Radio presets with sensible CAT defaults.
enum RigPreset: String, Codable, CaseIterable, Identifiable {
    case custom
    case qmx, qdx, truSDX
    case ftdx3000, ftdx5000, ft950, ft991, ftdx101, ftdx10, ft710, ft891, ft450
    case ts480, ts590, ts2000, k3, kx2kx3, k4
    case ic7300, ic705, ic9700, ic7610, ic7100, xiegu
    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: return "Custom"
        case .qmx: return "QRP Labs QMX"
        case .qdx: return "QRP Labs QDX"
        case .truSDX: return "(tr)uSDX"
        case .ftdx3000: return "Yaesu FTDX3000"
        case .ftdx5000: return "Yaesu FTDX5000"
        case .ft950: return "Yaesu FT-950 / FT-2000"
        case .ft991: return "Yaesu FT-991 / 991A"
        case .ftdx101: return "Yaesu FTDX101"
        case .ftdx10: return "Yaesu FTDX10"
        case .ft710: return "Yaesu FT-710"
        case .ft891: return "Yaesu FT-891"
        case .ft450: return "Yaesu FT-450"
        case .ts480: return "Kenwood TS-480"
        case .ts590: return "Kenwood TS-590 / 890"
        case .ts2000: return "Kenwood TS-2000"
        case .k3: return "Elecraft K3 / K3S"
        case .kx2kx3: return "Elecraft KX2 / KX3"
        case .k4: return "Elecraft K4"
        case .ic7300: return "Icom IC-7300"
        case .ic705: return "Icom IC-705"
        case .ic9700: return "Icom IC-9700"
        case .ic7610: return "Icom IC-7610"
        case .ic7100: return "Icom IC-7100"
        case .xiegu: return "Xiegu G90 / X6100 / X5105"
        }
    }

    var catProtocol: CATProtocol {
        switch self {
        case .ftdx3000, .ftdx5000, .ft950, .ft991, .ftdx101, .ftdx10, .ft710, .ft891, .ft450: return .yaesu
        case .ic7300, .ic705, .ic9700, .ic7610, .ic7100, .xiegu: return .icom
        default: return .kenwood
        }
    }

    var baud: Int {
        switch self {
        case .qmx, .qdx, .truSDX: return 115200
        case .ftdx3000, .ftdx5000, .ft950, .ft991, .ftdx101, .ftdx10, .ft710, .ft891: return 38400
        case .ft450, .ts480, .ts2000: return 9600
        case .ts590, .k3, .kx2kx3, .k4: return 38400
        case .ic7300, .ic705, .ic9700, .ic7610, .ic7100, .xiegu: return 19200
        case .custom: return 38400
        }
    }

    /// Digits in the Yaesu FA command (older rigs use 8, newer use 9).
    var yaesuDigits: Int {
        switch self {
        case .ftdx3000, .ftdx5000, .ft950, .ft450: return 8
        default: return 9
        }
    }

    var icomAddress: UInt8 {
        switch self {
        case .ic7300: return 0x94
        case .ic705: return 0xA4
        case .ic9700: return 0xA2
        case .ic7610: return 0x98
        case .ic7100: return 0x88
        case .xiegu: return 0x70
        default: return 0x94
        }
    }
}

struct RigSettings: Codable, Equatable {
    var connection: RigConnection = .none
    var preset: RigPreset = .custom
    var catProtocol: CATProtocol = .kenwood
    var serialPath = ""
    var baud = 38400
    var stopBits = 1
    var yaesuDigits = 9
    var icomAddress: UInt8 = 0x94
    var bluetoothID: String = ""
    var host = "192.168.1.10"
    var port: UInt16 = 4532
    var setDataModeOnConnect = true
    var pollSeconds: Double = 1.5

    mutating func apply(_ p: RigPreset) {
        preset = p
        guard p != .custom else { return }
        catProtocol = p.catProtocol
        baud = p.baud
        yaesuDigits = p.yaesuDigits
        icomAddress = p.icomAddress
    }
}

/// Frequency and PTT control for the connected radio.
@MainActor
@Observable
final class RigController {
    enum Status: Equatable {
        case disconnected, connecting, connected, error(String)
        var label: String {
            switch self {
            case .disconnected: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .error(let e): return e
            }
        }
    }

    private(set) var status: Status = .disconnected
    private(set) var frequency: UInt64?
    private(set) var pttActive = false
    var onFrequency: ((UInt64) -> Void)?

    private var settings = RigSettings()
    private var transport: ByteTransport?
    private var rxBuffer = Data()
    private var pollTimer: Timer?
    private var lastSetTime = Date.distantPast
    private var pendingRigctldReplies: [(String) -> Void] = []

    var isConnected: Bool { status == .connected }
    var supportsPTT: Bool { settings.connection != .none }
    var connection: RigConnection { settings.connection }

    func configure(_ s: RigSettings) {
        if s == settings, status == .connected { return }
        disconnect()
        settings = s
        connect()
    }

    func connect() {
        rxBuffer.removeAll()
        pendingRigctldReplies.removeAll()
        let t: ByteTransport?
        switch settings.connection {
        case .none:
            status = .disconnected
            return
        case .serial:
            #if os(macOS)
            guard !settings.serialPath.isEmpty else {
                status = .error("Choose a serial port")
                return
            }
            t = SerialTransport(path: settings.serialPath, baud: settings.baud, stopBits: settings.stopBits)
            #else
            status = .error("USB serial is not available on iOS")
            return
            #endif
        case .bluetooth:
            t = BLESerialTransport(peripheralID: UUID(uuidString: settings.bluetoothID))
        case .tcpSerial, .rigctld:
            t = TCPTransport(host: settings.host, port: settings.port)
        case .flrig:
            t = nil
        }
        status = .connecting
        if let t {
            transport = t
            t.onData = { [weak self] d in self?.received(d) }
            t.onState = { [weak self] st in self?.transportState(st) }
            t.open()
        } else {
            // flrig is HTTP; probe it.
            flrigCall("rig.get_vfo", params: []) { [weak self] r in
                guard let self else { return }
                if r != nil {
                    self.status = .connected
                    self.didConnect()
                } else {
                    self.status = .error("flrig not reachable at \(self.settings.host):\(self.settings.port)")
                }
            }
        }
    }

    func disconnect() {
        pollTimer?.invalidate()
        pollTimer = nil
        if pttActive { setPTT(false) }
        transport?.close()
        transport = nil
        status = .disconnected
    }

    private func transportState(_ st: TransportState) {
        switch st {
        case .connected:
            status = .connected
            didConnect()
        case .connecting: status = .connecting
        case .failed(let e): status = .error(e)
        case .idle: break
        }
    }

    private func didConnect() {
        if settings.setDataModeOnConnect { setDataMode() }
        poll()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: max(0.5, settings.pollSeconds), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    // MARK: Commands

    func setFrequency(_ hz: UInt64) {
        guard status == .connected else { return }
        lastSetTime = Date()
        frequency = hz
        switch settings.connection {
        case .rigctld:
            rigctld("F \(hz)") { _ in }
        case .flrig:
            flrigCall("rig.set_vfo", params: ["<double>\(hz)</double>"]) { _ in }
        default:
            switch settings.catProtocol {
            case .yaesu:
                send(String(format: "FA%0\(settings.yaesuDigits)llu;", hz))
            case .kenwood:
                send(String(format: "FA%011llu;", hz))
            case .icom:
                sendCIV([0x05] + Self.bcd(hz, bytes: settings.icomAddress == 0x70 ? 5 : 5))
            }
        }
    }

    func setPTT(_ on: Bool) {
        pttActive = on
        guard status == .connected else { return }
        switch settings.connection {
        case .rigctld:
            rigctld("T \(on ? 1 : 0)") { _ in }
        case .flrig:
            flrigCall("rig.set_ptt", params: ["<int>\(on ? 1 : 0)</int>"]) { _ in }
        default:
            switch settings.catProtocol {
            case .yaesu: send(on ? "TX1;" : "TX0;")
            case .kenwood: send(on ? "TX;" : "RX;")
            case .icom: sendCIV([0x1C, 0x00, on ? 0x01 : 0x00])
            }
        }
    }

    /// Serial modem-line PTT (e.g. Digirig Mobile RTS) — macOS only.
    func setRTS(_ on: Bool) { transport?.setRTS(on) }
    func setDTR(_ on: Bool) { transport?.setDTR(on) }

    private func setDataMode() {
        switch settings.connection {
        case .rigctld: rigctld("M PKTUSB 0") { _ in }
        case .flrig: break
        default:
            switch settings.catProtocol {
            case .yaesu: send("MD0C;")
            case .kenwood:
                // USB; QMX/QDX/Elecraft treat USB with audio as digital.
                send("MD2;")
            case .icom:
                sendCIV([0x06, 0x01, 0x01])          // USB, filter 1
                sendCIV([0x1A, 0x06, 0x01, 0x01])    // data mode on (newer rigs)
            }
        }
    }

    private func poll() {
        guard status == .connected, !pttActive else { return }
        switch settings.connection {
        case .rigctld:
            rigctld("f") { [weak self] reply in
                if let hz = UInt64(reply.trimmingCharacters(in: .whitespaces)) { self?.gotFrequency(hz) }
            }
        case .flrig:
            flrigCall("rig.get_vfo", params: []) { [weak self] r in
                if let r, let hz = UInt64(r.trimmingCharacters(in: .whitespaces)) ?? Double(r).map({ UInt64($0) }) {
                    self?.gotFrequency(hz)
                }
            }
        default:
            switch settings.catProtocol {
            case .yaesu, .kenwood: send("FA;")
            case .icom: sendCIV([0x03])
            }
        }
    }

    private func gotFrequency(_ hz: UInt64) {
        guard hz > 100_000 else { return }
        // Ignore stale reads right after we commanded a change.
        if Date().timeIntervalSince(lastSetTime) < 1.0 { return }
        if frequency != hz {
            frequency = hz
            onFrequency?(hz)
        }
    }

    // MARK: Transport I/O

    private func send(_ s: String) { transport?.write(Data(s.utf8)) }

    private func sendCIV(_ body: [UInt8]) {
        let frame: [UInt8] = [0xFE, 0xFE, settings.icomAddress, 0xE0] + body + [0xFD]
        transport?.write(Data(frame))
    }

    static func bcd(_ hz: UInt64, bytes: Int) -> [UInt8] {
        var v = hz
        var out: [UInt8] = []
        for _ in 0..<bytes {
            let lo = UInt8(v % 10); v /= 10
            let hi = UInt8(v % 10); v /= 10
            out.append(hi << 4 | lo)
        }
        return out
    }

    static func fromBCD(_ b: ArraySlice<UInt8>) -> UInt64 {
        var v: UInt64 = 0
        for byte in b.reversed() { v = v * 100 + UInt64(byte >> 4) * 10 + UInt64(byte & 0x0F) }
        return v
    }

    private func received(_ d: Data) {
        rxBuffer.append(d)
        switch settings.connection {
        case .rigctld:
            while let nl = rxBuffer.firstIndex(of: 0x0A) {
                let line = String(decoding: rxBuffer[rxBuffer.startIndex..<nl], as: UTF8.self)
                rxBuffer.removeSubrange(rxBuffer.startIndex...nl)
                if !pendingRigctldReplies.isEmpty { pendingRigctldReplies.removeFirst()(line) }
            }
        default:
            switch settings.catProtocol {
            case .yaesu, .kenwood:
                while let semi = rxBuffer.firstIndex(of: UInt8(ascii: ";")) {
                    let reply = String(decoding: rxBuffer[rxBuffer.startIndex..<semi], as: UTF8.self)
                    rxBuffer.removeSubrange(rxBuffer.startIndex...semi)
                    if reply.hasPrefix("FA"), let hz = UInt64(reply.dropFirst(2)) { gotFrequency(hz) }
                }
            case .icom:
                while let end = rxBuffer.firstIndex(of: 0xFD) {
                    let frame = [UInt8](rxBuffer[rxBuffer.startIndex...end])
                    rxBuffer.removeSubrange(rxBuffer.startIndex...end)
                    guard let start = frame.firstIndex(of: 0xFE), frame.count >= start + 6 else { continue }
                    let f = Array(frame[start...])
                    // FE FE E0 <rig> cmd data FD
                    guard f.count >= 6, f[2] == 0xE0 else { continue }
                    let cmd = f[4]
                    if (cmd == 0x03 || cmd == 0x00) && f.count >= 11 {
                        gotFrequency(Self.fromBCD(f[5..<10]))
                    }
                }
            }
        }
        if rxBuffer.count > 4096 { rxBuffer.removeAll() }
    }

    private func rigctld(_ cmd: String, reply: @escaping (String) -> Void) {
        pendingRigctldReplies.append(reply)
        send(cmd + "\n")
    }

    private func flrigCall(_ method: String, params: [String], done: @escaping (String?) -> Void) {
        guard let url = URL(string: "http://\(settings.host):\(settings.port)/RPC2") else { return done(nil) }
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "POST"
        req.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        let p = params.map { "<param><value>\($0)</value></param>" }.joined()
        req.httpBody = Data("<?xml version=\"1.0\"?><methodCall><methodName>\(method)</methodName><params>\(p)</params></methodCall>".utf8)
        URLSession.shared.dataTask(with: req) { data, _, err in
            let text = data.map { String(decoding: $0, as: UTF8.self) }
            var value: String?
            if err == nil, let text {
                if let r = text.range(of: "<value>"), let e = text.range(of: "</value>", range: r.upperBound..<text.endIndex) {
                    value = String(text[r.upperBound..<e.lowerBound])
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                } else {
                    value = ""
                }
            }
            DispatchQueue.main.async { done(value) }
        }.resume()
    }
}
