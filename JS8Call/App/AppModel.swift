import AVFoundation
import CoreGraphics
import Foundation
import JS8Core
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Marker drawn on the waterfall for each decode.
struct DecodeMarker: Identifiable, Hashable {
    let id = UUID()
    let frequency: Float
    let bandwidth: Int
    let label: String
    let date: Date
    let submode: JS8Submode
}

/// Central coordinator: audio, decoding, transmit timing, PTT, rig control
/// and the JS8 station engine.
@MainActor
@Observable
final class AppModel {
    var settings: AppSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    let station: JS8Station
    let audio = AudioIO()
    let rig = RigController()
    @ObservationIgnored private let waterfall = WaterfallRenderer()

    // UI snapshots
    private(set) var bandRows: [BandActivityRow] = []
    private(set) var calls: [CallDetail] = []
    private(set) var conversation: [ConversationLine] = []
    private(set) var inbox: [InboxMessage] = []
    private(set) var pendingReplies: [PendingReply] = []
    private(set) var waterfallImage: CGImage?
    private(set) var spectrum: [Float] = []
    private(set) var markers: [DecodeMarker] = []
    private(set) var inputLevel: Float = -120
    private(set) var isTransmitting = false
    private(set) var isTuning = false
    private(set) var txText = ""
    private(set) var queuedFrames = 0
    private(set) var heartbeatLoop = false
    private(set) var cqLoop = false
    private(set) var averageDT: Float = 0
    private(set) var decodeCount = 0
    private(set) var lastDecodeInfo = ""
    private(set) var lastError: String?
    private(set) var routeDescription = ""
    private(set) var usbConnected = false
    private(set) var audioRunning = false
    var banner: String?

    var selectedCallsign: String {
        get { station.selectedCallsign }
        set {
            station.selectedCallsign = newValue.uppercased()
            refresh()
        }
    }

    /// Outgoing message box. Non-empty text pauses auto-replies, as in JS8Call.
    var draft: String = "" {
        didSet { if station.draftText != draft { station.draftText = draft } }
    }

    @ObservationIgnored private var decoders: [JS8Submode: JS8ModeDecoder] = [:]
    @ObservationIgnored private let decodeQueue = DispatchQueue(label: "js8.decode", qos: .userInitiated)
    @ObservationIgnored private var lastDecodedPeriod: [JS8Submode: Double] = [:]
    @ObservationIgnored private var decodesInFlight = 0
    @ObservationIgnored private var recentDT: [Float] = []
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var catPTTOn = false
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var started = false

    init() {
        let s = AppSettings.load()
        settings = s
        AppClock.offset = s.clockOffset
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JS8Call", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        station = JS8Station(config: s.station, inbox: Inbox(url: support.appendingPathComponent("inbox.json")),
                             clock: { AppClock.now() })
        applyStationSettings()
        station.onNotify = { [weak self] kind, text in self?.notify(kind, text) }
        station.inbox.onChange = { [weak self] in
            DispatchQueue.main.async { self?.inbox = self?.station.inbox.messages.reversed() ?? [] }
        }
        inbox = station.inbox.messages.reversed()
        rig.onFrequency = { [weak self] hz in
            guard let self else { return }
            if self.settings.dialFrequency != hz { self.settings.dialFrequency = hz }
        }
        waterfall.contrastDB = s.waterfallContrast
        waterfall.brightness = s.waterfallBrightness
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        audio.onError = { [weak self] msg in DispatchQueue.main.async { self?.lastError = msg } }
        audio.onInputLevel = { [weak self] l in DispatchQueue.main.async { self?.inputLevel = l } }
        audio.spectrum.onRow = { [weak self] row in self?.waterfall.add(row: row) }
        audio.inputChannel = settings.inputChannel
        #if os(macOS)
        applyMacDevices()
        #endif

        AudioIO.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if !granted { self.lastError = "Microphone access is needed to receive. Enable it in Settings." }
                self.audio.configureSession()
                self.audio.start()
                self.audioRunning = self.audio.inputRunning
                self.routeDescription = self.audio.routeDescription
                self.usbConnected = self.audio.isUSBInterfaceConnected
            }
        }

        #if os(iOS)
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
                    self.audio.restart()
                    self.banner = self.audio.isUSBInterfaceConnected ? "USB audio interface connected" : "Audio route changed"
                }
                self.routeDescription = self.audio.routeDescription
                self.usbConnected = self.audio.isUSBInterfaceConnected
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated {
                if type == .ended { self?.audio.restart() }
            }
        }
        UIApplication.shared.isIdleTimerDisabled = true
        #endif

        if settings.hasOnboarded { requestNotificationPermission() }

        rig.configure(settings.rig)

        timers.append(Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.txLoop() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.decodeLoop() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.secondLoop() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.waterfallLoop() }
        })
        for t in timers { RunLoop.main.add(t, forMode: .common) }
    }

    // MARK: Settings

    private func applyStationSettings() {
        station.config = settings.station
        station.submode = settings.submode
        station.offset = settings.offset
        station.dialFrequency = settings.dialFrequency
        station.txEnabled = settings.txEnabled
        station.heartbeatNetworking = settings.heartbeatNetworking
        station.txDelay = settings.txDelay
    }

    private func settingsChanged(from old: AppSettings) {
        applyStationSettings()
        AppClock.offset = settings.clockOffset
        audio.inputChannel = settings.inputChannel
        waterfall.contrastDB = settings.waterfallContrast
        waterfall.brightness = settings.waterfallBrightness
        if settings.rig != old.rig { rig.configure(settings.rig) }
        if settings.dialFrequency != old.dialFrequency, rig.isConnected, rig.frequency != settings.dialFrequency {
            rig.setFrequency(settings.dialFrequency)
        }
        #if os(macOS)
        if settings.macInputDevice != old.macInputDevice || settings.macOutputDevice != old.macOutputDevice {
            applyMacDevices()
            audio.restart()
            routeDescription = audio.routeDescription
        }
        #endif
        settings.save()
        refresh(force: true)
    }

    #if os(macOS)
    private func applyMacDevices() {
        let devices = MacAudioDevices.all()
        audio.inputDeviceID = devices.first { $0.name == settings.macInputDevice && $0.inputs > 0 }?.id
        audio.outputDeviceID = devices.first { $0.name == settings.macOutputDevice && $0.outputs > 0 }?.id
    }
    #endif

    /// Set the audio offset (Hz) where we transmit and listen.
    func setOffset(_ hz: Int) {
        let bw = settings.submode.bandwidth
        settings.offset = max(100, min(3000 - bw, hz))
    }

    func setDial(_ hz: UInt64) {
        settings.dialFrequency = hz
    }

    // MARK: Transmit

    @discardableResult
    func send(_ text: String) -> Bool {
        let ok = station.send(text.uppercased())
        if !ok && settings.station.callsign.isEmpty { lastError = "Set your callsign in Settings first." }
        refresh(force: true)
        return ok
    }

    func sendCQ() {
        station.sendCQ()
        refresh(force: true)
    }

    func toggleHeartbeat() {
        station.setHeartbeatLoop(!station.heartbeatLoopActive)
        refresh(force: true)
    }

    func toggleCQLoop() {
        station.setCQLoop(!station.cqLoopActive)
        refresh(force: true)
    }

    func halt() {
        station.haltTransmit()
        audio.stopTransmit()
        stopTune()
        if catPTTOn { keyPTT(false) }
        if station.isTransmitting { station.transmissionFinished() }
        refresh(force: true)
    }

    func startTune() {
        guard settings.txEnabled else { return }
        isTuning = true
        audio.tune(frequency: Double(settings.offset), settings: settings.tx)
        keyPTT(true)
    }

    func stopTune() {
        guard isTuning else { return }
        isTuning = false
        audio.stopTransmit()
        keyPTT(false)
    }

    func approve(_ r: PendingReply) {
        station.approvePendingReply(r.id)
        refresh(force: true)
    }

    func reject(_ r: PendingReply) {
        station.rejectPendingReply(r.id)
        refresh(force: true)
    }

    func markRead(_ m: InboxMessage) {
        if m.type == "UNREAD" { station.inbox.setType(m.id, "READ") }
    }

    func deleteMessage(_ m: InboxMessage) {
        station.inbox.delete(m.id)
    }

    func preview(_ text: String) -> [DecodedText] { station.preview(text.uppercased()) }

    private func keyPTT(_ on: Bool) {
        catPTTOn = on
        switch settings.tx.pttMethod {
        case .cat: rig.setPTT(on)
        case .serialRTS: rig.setRTS(on)
        case .serialDTR: rig.setDTR(on)
        default: break
        }
    }

    private func txLoop() {
        let now = AppClock.now()
        if !isTuning, let req = station.pollTransmit(now: now) {
            audio.transmit(req, settings: settings.tx)
            txText = req.displayText
            refresh(force: true)
        }
        if let tx = station.currentTx {
            let payloadStart = tx.periodStart.timeIntervalSince1970 + Double(tx.submode.startDelayMS) / 1000
            let t = now.timeIntervalSince1970
            if !catPTTOn && t >= payloadStart - settings.tx.leadTime {
                keyPTT(true)
            }
            let end = payloadStart + tx.submode.dataDuration + settings.tx.tailTime
            if !audio.isPlaying && t >= payloadStart || t > end + 1.0 {
                if catPTTOn { keyPTT(false) }
                audio.stopTransmit()
                station.transmissionFinished()
                txText = ""
                refresh(force: true)
            }
        }
        let tx = station.isTransmitting || isTuning
        if tx != isTransmitting { isTransmitting = tx }
    }

    // MARK: Receive

    private func decodeLoop() {
        let now = AppClock.nowSeconds()
        let modes: [JS8Submode] = settings.decodeAllSpeeds ? JS8Submode.allCases : [settings.submode]
        for mode in modes {
            let p = Double(mode.period)
            let periodStart = (now / p).rounded(.down) * p
            let readyAt = periodStart + Double(mode.samplesNeeded) / 12000 + 0.05
            guard now >= readyAt, lastDecodedPeriod[mode] != periodStart else { continue }
            lastDecodedPeriod[mode] = periodStart
            if !station.shouldDecode(now: AppClock.now()) { continue }
            if let s = station.lastTxStart?.timeIntervalSince1970, s >= periodStart - 1, s <= readyAt { continue }
            if decodesInFlight > 4 { continue }
            let samples = audio.ring.read(start: Int64(periodStart * 12000), count: mode.samplesNeeded)
            let nfqso = settings.offset
            let dial = settings.dialFrequency
            let decoder = decoders[mode] ?? JS8ModeDecoder(submode: mode)
            decoders[mode] = decoder
            decodesInFlight += 1
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
            decodeQueue.async { [weak self] in
                let t0 = Date()
                var results: [JS8RawDecode] = []
                samples.withUnsafeBufferPointer { buf in
                    _ = decoder.decode(samples: buf, nfqso: nfqso) { results.append($0) }
                }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                NSLog("JS8 decode %@: %d frame(s) in %d ms (rms %.0f)", mode.name, results.count, ms, rms)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.decodesInFlight -= 1
                    self.lastDecodeInfo = "\(mode.name): \(results.count) in \(ms) ms"
                    self.handleDecodes(results, dial: dial)
                }
            }
        }
    }

    private func handleDecodes(_ results: [JS8RawDecode], dial: UInt64) {
        guard !results.isEmpty else { return }
        for r in results {
            station.handleDecode(r, dial: dial)
            let text = DecodedText(r)
            let label = text.isCompound ? text.compoundCall : (text.directed.first ?? String(text.message.prefix(10)))
            markers.append(DecodeMarker(frequency: r.frequency, bandwidth: r.submode.bandwidth, label: label,
                                        date: Date(), submode: r.submode))
            recentDT.append(r.dt)
        }
        decodeCount += results.count
        if recentDT.count > 40 { recentDT.removeFirst(recentDT.count - 40) }
        averageDT = recentDT.isEmpty ? 0 : recentDT.sorted()[recentDT.count / 2]
        markers.removeAll { Date().timeIntervalSince($0.date) > 45 }
        station.processActivity()
        refresh(force: true)
    }

    /// Shift the clock by the median decode time offset.
    func syncClockToDecodes() {
        guard !recentDT.isEmpty else { return }
        settings.clockOffset -= Double(averageDT)
        recentDT.removeAll()
        averageDT = 0
        banner = String(format: "Clock adjusted to %+.2f s", settings.clockOffset)
    }

    private func secondLoop() {
        station.tick()
        markers.removeAll { Date().timeIntervalSince($0.date) > 45 }
        refresh()
    }

    private func waterfallLoop() {
        waterfallImage = waterfall.makeImage()
        spectrum = waterfall.latestSpectrum
    }

    func refresh(force: Bool = false) {
        if !force && Date().timeIntervalSince(lastRefresh) < 0.5 { return }
        lastRefresh = Date()
        bandRows = station.bandActivityRows(now: AppClock.now())
        calls = station.callActivity.values.sorted { $0.utc > $1.utc }
        conversation = station.conversation
        pendingReplies = station.pendingReplies
        queuedFrames = station.txFramesRemaining
        heartbeatLoop = station.heartbeatLoopActive
        if station.draftText != draft { draft = station.draftText }
        cqLoop = station.cqLoopActive
        // Keep settings mirrors in sync with automatic offset changes.
        if station.offset != settings.offset && !station.isMessageQueuedForTransmit {
            settings.offset = station.offset
        }
    }

    func dismissError() { lastError = nil }

    func clearConversation() {
        station.clearConversation()
        refresh(force: true)
    }

    func clearBand() {
        station.clearBandActivity()
        refresh(force: true)
    }

    // MARK: Notifications

    func requestNotificationPermission() {
        guard settings.notificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notify(_ kind: StationNotification, _ text: String) {
        switch kind {
        case .directed, .inbox:
            #if os(iOS)
            let background = UIApplication.shared.applicationState != .active
            #else
            let background = true
            #endif
            guard settings.notificationsEnabled, background else { return }
            let content = UNMutableNotificationContent()
            content.title = kind == .inbox ? "New JS8 message" : "JS8 directed message"
            content.body = text
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        default:
            break
        }
    }
}
