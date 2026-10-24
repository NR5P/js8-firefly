import SwiftUI
import JS8Core
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            StationSection(settings: $model.settings)
            AudioSection(settings: $model.settings)
            RigSection(settings: $model.settings)
            JS8Section(settings: $model.settings)
            ClockSection()
            AboutSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.backgroundGradient)
        .navigationTitle("Settings")
    }
}

private struct StationSection: View {
    @Binding var settings: AppSettings
    @State private var groupText = ""

    var body: some View {
        Section {
            LabeledContent("Callsign") {
                TextField("N0CALL", text: Binding(get: { settings.station.callsign },
                                                  set: { settings.station.callsign = $0.uppercased().trimmingCharacters(in: .whitespaces) }))
                    .multilineTextAlignment(.trailing)
                    .font(Theme.mono(15, .bold))
                    .uppercaseInput()
            }
            LabeledContent("Grid") {
                TextField("EM73tu", text: $settings.station.grid)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.mono(15))
            }
            if !settings.station.grid.isEmpty && !GridMath.isValid(settings.station.grid) {
                Text("Enter a 4 or 6 character Maidenhead locator").font(.caption).foregroundStyle(Theme.warn)
            }
            LabeledContent("Info") {
                TextField("Station info (sent on INFO?)", text: $settings.station.info)
                    .multilineTextAlignment(.trailing)
                    .uppercaseInput()
            }
            LabeledContent("Status") {
                TextField("Status (sent on STATUS?)", text: $settings.station.status)
                    .multilineTextAlignment(.trailing)
                    .uppercaseInput()
            }
            LabeledContent("CQ message") {
                TextField("CQ CQ CQ <MYGRID4>", text: $settings.station.cqMessage)
                    .multilineTextAlignment(.trailing)
                    .uppercaseInput()
            }
            LabeledContent("Reply message") {
                TextField("HW CPY?", text: $settings.station.replyMessage)
                    .multilineTextAlignment(.trailing)
                    .uppercaseInput()
            }
            LabeledContent("Groups") {
                HStack {
                    TextField("@GROUP", text: $groupText)
                        .multilineTextAlignment(.trailing)
                        .uppercaseInput()
                    Button("Add") {
                        var g = groupText.uppercased().trimmingCharacters(in: .whitespaces)
                        if !g.hasPrefix("@") { g = "@" + g }
                        if g.count > 1, !settings.station.groups.contains(g) { settings.station.groups.append(g) }
                        groupText = ""
                    }
                }
            }
            if !settings.station.groups.isEmpty {
                ForEach(settings.station.groups, id: \.self) { g in
                    HStack {
                        Text(g).font(Theme.mono(14))
                        Spacer()
                        Button(role: .destructive) {
                            settings.station.groups.removeAll { $0 == g }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Label("Station", systemImage: "person.crop.circle")
        }
    }
}

private struct AudioSection: View {
    @Environment(AppModel.self) private var model
    @Binding var settings: AppSettings

    var body: some View {
        Section {
            LabeledContent("Route") {
                Text(model.routeDescription).font(.caption).multilineTextAlignment(.trailing).foregroundStyle(Theme.dim)
            }
            HStack {
                Image(systemName: model.usbConnected ? "cable.connector" : "cable.connector.slash")
                    .foregroundStyle(model.usbConnected ? Theme.rx : Theme.warn)
                Text(model.usbConnected ? "USB audio interface detected" : "No USB audio interface — using built-in audio")
                    .font(.callout)
            }
            #if os(macOS)
            MacDevicePickers(settings: $settings)
            #endif
            Picker("Input channel", selection: $settings.inputChannel) {
                Text("Left").tag(0)
                Text("Right").tag(1)
                Text("Mix").tag(-1)
            }
            Picker("PTT method", selection: $settings.tx.pttMethod) {
                ForEach(PTTMethod.available) { Text($0.title).tag($0) }
            }
            if settings.tx.pttMethod == .digirigTone {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Digirig Lite: JS8 audio goes to the left channel and a keying tone to the right channel, which drives the Digirig's PTT circuit.")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
                Stepper(value: $settings.tx.toneFrequency, in: 300...3000, step: 100) {
                    LabeledContent("PTT tone", value: "\(Int(settings.tx.toneFrequency)) Hz")
                }
                LabeledContent("Tone level") {
                    Slider(value: $settings.tx.toneLevel, in: 0.1...1)
                }
                Toggle("Swap channels (tone on left)", isOn: $settings.tx.swapChannels)
            }
            if settings.tx.pttMethod == .cat && settings.rig.connection == .none {
                Text("CAT PTT needs a rig connection below.").font(.caption).foregroundStyle(Theme.warn)
            }
            if settings.tx.pttMethod == .serialRTS || settings.tx.pttMethod == .serialDTR {
                Text("Uses the serial port configured under Rig Control (USB serial CAT).").font(.caption).foregroundStyle(Theme.dim)
            }
            Stepper(value: $settings.tx.leadTime, in: 0...1, step: 0.05) {
                LabeledContent("PTT lead", value: "\(Int(settings.tx.leadTime * 1000)) ms")
            }
            Stepper(value: $settings.tx.tailTime, in: 0...1, step: 0.05) {
                LabeledContent("PTT tail", value: "\(Int(settings.tx.tailTime * 1000)) ms")
            }
            LabeledContent("TX audio level") {
                Slider(value: $settings.tx.outputLevel, in: 0.01...1)
            }
            Text("Set TX level so the radio's ALC barely moves. On iPhone, also use the volume buttons.")
                .font(.caption).foregroundStyle(Theme.dim)
            LabeledContent("Waterfall contrast") {
                // Right = more contrast = a narrower dB range from floor to white.
                Slider(value: Binding(get: { -settings.waterfallRangeDB }, set: { settings.waterfallRange = -$0 }),
                       in: -72 ... -16)
            }
            LabeledContent("Waterfall brightness") {
                Slider(value: $settings.waterfallBrightness, in: -20...20)
            }
            Button("Restart audio") { model.audio.restart() }
        } header: {
            Label("Audio & PTT", systemImage: "waveform.circle")
        }
    }
}

#if os(macOS)
private struct MacDevicePickers: View {
    @Binding var settings: AppSettings
    @State private var devices: [MacAudioDevices.Device] = []

    var body: some View {
        Group {
            Picker("Input device", selection: $settings.macInputDevice) {
                Text("System default").tag("")
                ForEach(devices.filter { $0.inputs > 0 }) { d in Text(d.name + (d.isUSB ? "  (USB)" : "")).tag(d.name) }
            }
            Picker("Output device", selection: $settings.macOutputDevice) {
                Text("System default").tag("")
                ForEach(devices.filter { $0.outputs > 0 }) { d in Text(d.name + (d.isUSB ? "  (USB)" : "")).tag(d.name) }
            }
        }
        .onAppear { devices = MacAudioDevices.all() }
    }
}
#endif

private struct RigSection: View {
    @Environment(AppModel.self) private var model
    @Binding var settings: AppSettings
    @State private var serialPorts: [String] = []
    @State private var bleDevices: [(UUID, String)] = []
    @State private var scanner: BLESerialTransport?

    var body: some View {
        Section {
            Picker("Connection", selection: $settings.rig.connection) {
                ForEach(RigConnection.available) { Text($0.title).tag($0) }
            }
            if settings.rig.connection != .none {
                HStack {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(model.rig.status.label).font(.callout)
                    Spacer()
                    if let f = model.rig.frequency {
                        Text(Format.mhzLong(f)).font(Theme.mono(13)).foregroundStyle(Theme.accent)
                    }
                    Button("Reconnect") { model.rig.disconnect(); model.rig.connect() }.buttonStyle(.borderless)
                }
            }
            if settings.rig.connection.usesCATProtocol {
                Picker("Radio", selection: Binding(get: { settings.rig.preset }, set: { settings.rig.apply($0) })) {
                    ForEach(RigPreset.allCases) { Text($0.title).tag($0) }
                }
                Picker("CAT protocol", selection: $settings.rig.catProtocol) {
                    ForEach(CATProtocol.allCases) { Text($0.title).tag($0) }
                }
                if settings.rig.catProtocol == .yaesu {
                    Picker("Frequency digits", selection: $settings.rig.yaesuDigits) {
                        Text("8 (FTDX3000/5000, FT-950, FT-450)").tag(8)
                        Text("9 (FT-991, FTDX101/10, FT-710, FT-891)").tag(9)
                    }
                }
                if settings.rig.catProtocol == .icom {
                    LabeledContent("CI-V address") {
                        TextField("94", text: Binding(
                            get: { String(format: "%02X", settings.rig.icomAddress) },
                            set: { if let v = UInt8($0, radix: 16) { settings.rig.icomAddress = v } }))
                            .multilineTextAlignment(.trailing).font(Theme.mono(14))
                    }
                }
                Toggle("Set USB/DATA mode on connect", isOn: $settings.rig.setDataModeOnConnect)
            }
            switch settings.rig.connection {
            case .serial:
                #if os(macOS)
                Picker("Serial port", selection: $settings.rig.serialPath) {
                    Text("Choose…").tag("")
                    ForEach(serialPorts, id: \.self) { Text($0).tag($0) }
                }
                .onAppear { serialPorts = SerialTransport.availablePorts() }
                Picker("Baud rate", selection: $settings.rig.baud) {
                    ForEach([4800, 9600, 19200, 38400, 57600, 115200], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Stop bits", selection: $settings.rig.stopBits) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                }
                Text("Match the radio's CAT RATE menu. FTDX3000: use its USB port (CP210x driver). QMX/QDX: the QMX serial port.")
                    .font(.caption).foregroundStyle(Theme.dim)
                #endif
            case .bluetooth:
                Button(scanner == nil ? "Scan for Bluetooth adapters" : "Stop scan") { toggleScan() }
                ForEach(bleDevices, id: \.0) { d in
                    Button {
                        settings.rig.bluetoothID = d.0.uuidString
                        scanner?.stopScan()
                        scanner = nil
                    } label: {
                        HStack {
                            Text(d.1)
                            Spacer()
                            if settings.rig.bluetoothID == d.0.uuidString { Image(systemName: "checkmark") }
                        }
                    }
                }
                Text("Works with BLE serial modules (Nordic UART or HM-10 style) wired to the radio's CAT port. Set the module's baud rate to the radio's CAT rate.")
                    .font(.caption).foregroundStyle(Theme.dim)
            case .tcpSerial, .rigctld, .flrig:
                LabeledContent("Host") {
                    TextField("192.168.1.10", text: $settings.rig.host)
                        .multilineTextAlignment(.trailing).font(Theme.mono(14))
                        .autocorrectionDisabled()
                }
                LabeledContent("Port") {
                    TextField("4532", value: $settings.rig.port, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing).font(Theme.mono(14))
                }
                Text(networkHelp).font(.caption).foregroundStyle(Theme.dim)
            case .none:
                Text("Without rig control, pick the band in the header and set the radio's dial to match (USB or DATA-U).")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            #if os(iOS)
            if settings.rig.connection == .none {
                Text("iPhone apps cannot open USB serial ports, so CAT over the Digirig/radio USB cable is only available on the Mac. On iPhone use a Bluetooth LE serial adapter or a network rig server.")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            #endif
        } header: {
            Label("Rig Control", systemImage: "dial.medium")
        }
    }

    private var networkHelp: String {
        switch settings.rig.connection {
        case .rigctld: return "Run `rigctld -m <model> -r <port>` on a computer or Raspberry Pi connected to the radio (default port 4532)."
        case .flrig: return "flrig XML-RPC server (default port 12345)."
        default: return "Raw CAT bytes over TCP (ser2net, WiFi serial bridges). Choose the radio's protocol above."
        }
    }

    private var statusColor: Color {
        switch model.rig.status {
        case .connected: return Theme.rx
        case .connecting: return Theme.warn
        case .error: return Theme.tx
        case .disconnected: return Theme.faint
        }
    }

    private func toggleScan() {
        if let s = scanner {
            s.stopScan()
            scanner = nil
            return
        }
        let s = BLESerialTransport(peripheralID: nil)
        s.onDiscover = { p, _ in
            if !bleDevices.contains(where: { $0.0 == p.identifier }) {
                bleDevices.append((p.identifier, p.name ?? p.identifier.uuidString.prefix(8) + "…"))
            }
        }
        s.scan()
        scanner = s
    }
}

private struct JS8Section: View {
    @Binding var settings: AppSettings

    var body: some View {
        Section {
            Picker("Speed", selection: $settings.submode) {
                ForEach(JS8Submode.allCases) { m in Text("\(m.name) (\(m.period)s)").tag(m) }
            }
            Toggle("Decode all speeds", isOn: $settings.decodeAllSpeeds)
            Toggle("Auto-reply to queries", isOn: $settings.station.autoReply)
            Toggle("Confirm auto-replies", isOn: $settings.station.autoReplyConfirmation)
            Toggle("Heartbeat networking", isOn: $settings.heartbeatNetworking)
            Toggle("Acknowledge heartbeats", isOn: $settings.station.heartbeatAcknowledgements)
            Toggle("Pause HB while a station is selected", isOn: $settings.station.heartbeatQSOPause)
            Toggle("HB anywhere (not just 500–1000 Hz)", isOn: $settings.station.heartbeatAnywhere)
            Stepper(value: $settings.station.heartbeatIntervalMinutes, in: 0...60, step: 5) {
                LabeledContent("Heartbeat every", value: settings.station.heartbeatIntervalMinutes == 0 ? "once" : "\(settings.station.heartbeatIntervalMinutes) min")
            }
            Stepper(value: $settings.station.cqIntervalMinutes, in: 0...60, step: 1) {
                LabeledContent("Repeat CQ every", value: settings.station.cqIntervalMinutes == 0 ? "once" : "\(settings.station.cqIntervalMinutes) min")
            }
            Toggle("Never reply to @ALLCALL", isOn: $settings.station.avoidAllcall)
            Toggle("Disable relaying", isOn: $settings.station.relayOff)
            Toggle("Show heartbeats in band activity", isOn: $settings.station.showHeartbeatsInBand)
            Stepper(value: $settings.station.activityAgingMinutes, in: 0...60) {
                LabeledContent("Band activity aging", value: settings.station.activityAgingMinutes == 0 ? "off" : "\(settings.station.activityAgingMinutes) min")
            }
            Stepper(value: $settings.txDelay, in: 0...1, step: 0.05) {
                LabeledContent("TX delay", value: "\(Int(settings.txDelay * 1000)) ms")
            }
            Toggle("Notifications", isOn: $settings.notificationsEnabled)
        } header: {
            Label("JS8", systemImage: "antenna.radiowaves.left.and.right")
        }
    }
}

private struct ClockSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                LabeledContent("UTC (corrected)", value: Format.utcTime.string(from: AppClock.now()))
            }
            LabeledContent("Median decode Δt", value: String(format: "%+.2f s", model.averageDT))
            LabeledContent("Last decode", value: model.lastDecodeInfo.isEmpty ? "–" : model.lastDecodeInfo)
            LabeledContent("Frames decoded", value: "\(model.decodeCount)")
            Stepper(value: $model.settings.clockOffset, in: -30...30, step: 0.1) {
                LabeledContent("Clock offset", value: String(format: "%+.1f s", model.settings.clockOffset))
            }
            Button("Sync clock to received signals") { model.syncClockToDecodes() }
                .disabled(model.averageDT == 0)
            Text("JS8 needs your clock within about ±1 second of UTC. The phone's network time is usually fine; use sync if decodes show large Δt.")
                .font(.caption).foregroundStyle(Theme.dim)
        } header: {
            Label("Time", systemImage: "clock")
        }
    }
}

private struct AboutSection: View {
    var body: some View {
        Section {
            Text("JS8 Firefly 1.0. JS8 protocol, modem and message handling ported from JS8Call / JS8Call-improved (GPLv3). Compatible with JS8Call stations on all speeds: Slow, Normal, Fast, Turbo and Ultra.")
                .font(.caption).foregroundStyle(Theme.dim)
        } header: {
            Label("About", systemImage: "info.circle")
        }
    }
}

extension View {
    func uppercaseInput() -> some View {
        #if os(iOS)
        return self.textInputAutocapitalization(.characters).autocorrectionDisabled()
        #else
        return self.autocorrectionDisabled()
        #endif
    }
}
