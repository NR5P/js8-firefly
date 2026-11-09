import CoreBluetooth
import Foundation
import Network

/// A byte pipe to a radio's CAT port.
protocol ByteTransport: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onState: ((TransportState) -> Void)? { get set }
    func open()
    func close()
    func write(_ data: Data)
    /// Optional modem control lines (serial only).
    func setRTS(_ on: Bool)
    func setDTR(_ on: Bool)
}

extension ByteTransport {
    func setRTS(_ on: Bool) {}
    func setDTR(_ on: Bool) {}
}

enum TransportState: Equatable {
    case idle, connecting, connected, failed(String)
}

// MARK: - TCP (raw serial bridge, rigctld, ...)

final class TCPTransport: ByteTransport {
    var onData: ((Data) -> Void)?
    var onState: ((TransportState) -> Void)?
    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "js8.rig.tcp")

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func open() {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            onState?(.failed("Invalid port"))
            return
        }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        connection = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            DispatchQueue.main.async {
                switch st {
                case .ready: self.onState?(.connected)
                case .failed(let e): self.onState?(.failed(e.localizedDescription))
                case .waiting(let e): self.onState?(.failed(e.localizedDescription))
                case .preparing: self.onState?(.connecting)
                case .cancelled: self.onState?(.idle)
                default: break
                }
            }
        }
        c.start(queue: queue)
        receive()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty { DispatchQueue.main.async { self.onData?(data) } }
            if done || err != nil {
                DispatchQueue.main.async { self.onState?(.failed(err?.localizedDescription ?? "Connection closed")) }
                return
            }
            self.receive()
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    func write(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }
}

// MARK: - Bluetooth LE serial (Nordic UART / HM-10 style modules)

final class BLESerialTransport: NSObject, ByteTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nusRX = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // write
    static let nusTX = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // notify
    static let hmService = CBUUID(string: "FFE0")
    static let hmChar = CBUUID(string: "FFE1")

    var onData: ((Data) -> Void)?
    var onState: ((TransportState) -> Void)?
    var onDiscover: ((CBPeripheral, Int) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private let targetID: UUID?
    private var scanOnly = false

    init(peripheralID: UUID?) {
        targetID = peripheralID
        super.init()
    }

    /// Scan for adapters (for the settings picker).
    func scan() {
        scanOnly = true
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func stopScan() {
        central?.stopScan()
    }

    func open() {
        scanOnly = false
        onState?(.connecting)
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func close() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        peripheral = nil
        writeChar = nil
        onState?(.idle)
    }

    func write(_ data: Data) {
        guard let p = peripheral, let c = writeChar else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu = max(20, p.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(data.count, offset + mtu))
            p.writeValue(chunk, for: c, type: type)
            offset += mtu
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .unauthorized { onState?(.failed("Bluetooth permission denied")) }
            if central.state == .poweredOff { onState?(.failed("Bluetooth is off")) }
            return
        }
        if !scanOnly, let id = targetID, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
            return
        }
        central.scanForPeripherals(withServices: [Self.nusService, Self.hmService], options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        onDiscover?(peripheral, RSSI.intValue)
        if !scanOnly && (targetID == nil || peripheral.identifier == targetID) {
            central.stopScan()
            connect(peripheral)
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central?.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.nusService, Self.hmService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onState?(.failed(error?.localizedDescription ?? "Bluetooth connection failed"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        onState?(.failed("Bluetooth adapter disconnected"))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == Self.nusRX || c.uuid == Self.hmChar { writeChar = c }
            if c.uuid == Self.nusTX || c.uuid == Self.hmChar { peripheral.setNotifyValue(true, for: c) }
        }
        if writeChar != nil { onState?(.connected) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let v = characteristic.value { onData?(v) }
    }
}

// MARK: - Serial port (macOS)

#if os(macOS)
import IOKit
import IOKit.serial

final class SerialTransport: ByteTransport {
    var onData: ((Data) -> Void)?
    var onState: ((TransportState) -> Void)?
    private let path: String
    private let baud: Int
    private let stopBits: Int
    /// Keep RTS high while idle. Yaesu rigs with CAT RTS on (FTDX3000 etc.) ignore CAT while RTS is low.
    private let holdRTS: Bool
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, baud: Int, stopBits: Int, holdRTS: Bool = false) {
        self.holdRTS = holdRTS
        self.path = path
        self.baud = baud
        self.stopBits = stopBits
    }

    static func availablePorts() -> [String] { availablePortInfo().map(\.path) }

    /// A serial port with a readable description of the device behind it.
    struct PortInfo: Hashable {
        let path: String
        let label: String
        let isUSB: Bool
    }

    /// Serial ports with their USB product name and port number, USB devices first.
    static func availablePortInfo() -> [PortInfo] {
        var ports: [PortInfo] = []
        let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var service = IOIteratorNext(iter)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
                  !path.contains("Bluetooth-Incoming"), !path.contains("debug-console") else { continue }
            func parent(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            let product = (parent("USB Product Name") as? String) ?? (parent("kUSBProductString") as? String)
            let iface = (parent("bInterfaceNumber") as? NSNumber)?.intValue
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: "cu.", with: "")
            var label = name
            if let product {
                var desc = product
                    .replacingOccurrences(of: " USB to UART Bridge Controller", with: "")
                    .replacingOccurrences(of: " Dual", with: "")
                    .replacingOccurrences(of: " (Enhanced Port)", with: "")
                    .replacingOccurrences(of: " (Standard Port)", with: "")
                if let iface { desc += " · port \(iface + 1)" }
                // Yaesu radios with a built-in CP2105: the Enhanced port (first) carries CAT.
                let dualCP210x = product.contains("CP2105") || product.contains("Enhanced Port") || product.contains("Standard Port")
                if dualCP210x, let iface { desc += iface == 0 ? " (CAT)" : " (PTT/RTTY)" }
                label = "\(desc) — \(name)"
            }
            ports.append(PortInfo(path: path, label: label, isUSB: product != nil))
        }
        return ports.sorted { ($0.isUSB ? 0 : 1, $0.label) < ($1.isUSB ? 0 : 1, $1.label) }
    }

    /// Ask each USB serial port for the radio's frequency (read-only) and return the first that answers.
    /// Blocking; call off the main thread. `skip` is left alone (e.g. a port this app has open).
    static func findRadio(protocol proto: CATProtocol, baud: Int, stopBits: Int, icomAddress: UInt8,
                          skip: String? = nil) -> String? {
        let query: [UInt8]
        switch proto {
        case .yaesu, .kenwood: query = Array("FA;".utf8)
        case .icom: query = [0xFE, 0xFE, icomAddress, 0xE0, 0x03, 0xFD]
        }
        for port in availablePortInfo() where port.isUSB && port.path != skip {
            guard let reply = probe(port.path, query: query, baud: baud, stopBits: stopBits) else { continue }
            switch proto {
            case .yaesu, .kenwood:
                if String(decoding: reply, as: UTF8.self).contains("FA") { return port.path }
            case .icom:
                // A reply from the rig (not just our echo on a shared CI-V bus): FE FE E0 <rig> 03 ...
                let b = [UInt8](reply)
                if b.indices.contains(where: { i in i + 4 < b.count && b[i] == 0xFE && b[i + 1] == 0xFE && b[i + 2] == 0xE0 && b[i + 4] == 0x03 }) {
                    return port.path
                }
            }
        }
        return nil
    }

    private static func probe(_ path: String, query: [UInt8], baud: Int, stopBits: Int) -> Data? {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var saved = termios()
        tcgetattr(fd, &saved)
        defer {
            tcsetattr(fd, TCSANOW, &saved)
            Darwin.close(fd)
        }
        var t = saved
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CRTSCTS)
        if stopBits == 2 { t.c_cflag |= tcflag_t(CSTOPB) } else { t.c_cflag &= ~tcflag_t(CSTOPB) }
        cfsetspeed(&t, speed_t(baud))
        tcsetattr(fd, TCSANOW, &t)
        // RTS high (radios that gate CAT on RTS), DTR low (never key an interface that uses DTR for PTT).
        var rts = TIOCM_RTS, dtr = TIOCM_DTR
        _ = ioctl(fd, UInt(TIOCMBIS), &rts)
        _ = ioctl(fd, UInt(TIOCMBIC), &dtr)
        tcflush(fd, TCIOFLUSH)
        usleep(100_000)
        _ = query.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, query.count) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 256)
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            let n = read(fd, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]) }
            usleep(30_000)
        }
        // Leave RTS low as we found most interfaces, so nothing stays keyed.
        _ = ioctl(fd, UInt(TIOCMBIC), &rts)
        return out.isEmpty ? nil : out
    }

    func open() {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            onState?(.failed("Cannot open \(path): \(String(cString: strerror(errno)))"))
            return
        }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CRTSCTS)
        if stopBits == 2 { t.c_cflag |= tcflag_t(CSTOPB) } else { t.c_cflag &= ~tcflag_t(CSTOPB) }
        cfsetspeed(&t, speed_t(baud))
        tcsetattr(fd, TCSANOW, &t)
        // DTR low so interfaces that key on it stay in receive. RTS low too, unless it isn't
        // used for PTT, in which case hold it high so radios that gate CAT on RTS will answer.
        setRTS(holdRTS)
        setDTR(false)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = read(self.fd, &buf, buf.count)
            if n > 0 { self.onData?(Data(buf[0..<n])) }
        }
        src.resume()
        source = src
        onState?(.connected)
    }

    func close() {
        source?.cancel()
        source = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        onState?(.idle)
    }

    func write(_ data: Data) {
        guard fd >= 0 else { return }
        data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, data.count) }
    }

    private func modem(_ bit: Int32, _ on: Bool) {
        guard fd >= 0 else { return }
        var flag = bit
        _ = ioctl(fd, on ? UInt(TIOCMBIS) : UInt(TIOCMBIC), &flag)
    }

    func setRTS(_ on: Bool) { modem(TIOCM_RTS, on) }
    func setDTR(_ on: Bool) { modem(TIOCM_DTR, on) }
}
#endif
