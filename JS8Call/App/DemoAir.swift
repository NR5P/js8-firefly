import Foundation
#if DEBUG
import JS8Core

/// Screenshot demo: scripted stations "on the air" whose frames are modulated,
/// mixed with noise and written into the receive ring and waterfall in real
/// time, so the real decoder and station engine fill the UI.
///
/// Launch with `-demo YES` (Debug builds only). While it runs, the Darwin
/// notifications `com.js8firefly.demo.<command>` drive the UI for capture:
/// `tab0`…`tab4` pick the iPhone tab, `bands`/`levels` open a header sheet and
/// `close` dismisses it (see tools/screenshots.sh).
@MainActor
final class DemoAir {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demo") }

    private struct Station {
        let engine: JS8Station
        let amplitude: Float
    }

    private struct Signal {
        let start: Int64
        let wave: [Float]
        let amplitude: Float
    }

    private struct Cue {
        let period: Int
        let call: String
        let to: String
        let text: String
    }

    private let ring: RxRingBuffer
    private let spectrum: SpectrumAnalyzer
    private let onLevel: (Float) -> Void
    private var stations: [String: Station] = [:]
    private var cues: [Cue] = []
    private var signals: [Signal] = []
    private var transmitting: [JS8Station] = []
    private var nextSample: Int64 = -1
    private var firstPeriod = 0
    private var lastPeriod = -1
    private var timer: Timer?

    nonisolated static let commandPrefix = "com.js8firefly.demo."
    static let mycall = "NR5P"
    /// Overall level, putting the receive meter near 33 dB, inside its target zone.
    private static let gain: Float = 0.16
    static let mygrid = "EM12"

    init(ring: RxRingBuffer, spectrum: SpectrumAnalyzer, onLevel: @escaping (Float) -> Void) {
        self.ring = ring
        self.spectrum = spectrum
        self.onLevel = onLevel
        add("W7GTK", "DM43", offset: 1650, amplitude: 260)
        add("KD5QRV", "EM20", offset: 1210, amplitude: 400)
        add("VE3NXR", "FN03", offset: 760, amplitude: 110)
        add("K4LMB", "EM73", offset: 1500, amplitude: 180)
        add("N0VBQ", "EN34", offset: 1950, amplitude: 90)
        add("G4ZTW", "IO91", offset: 890, amplitude: 70)
        add("KJ7ABP", "DN17", offset: 2350, amplitude: 150)

        cues = [
            Cue(period: 0, call: "W7GTK", to: "", text: "CQ"),
            Cue(period: 0, call: "VE3NXR", to: "", text: "HB"),
            Cue(period: 0, call: "G4ZTW", to: "", text: "HB"),
            Cue(period: 1, call: "KD5QRV", to: Self.mycall, text: "SNR?"),
            Cue(period: 1, call: "N0VBQ", to: "W7GTK", text: "TNX CQ. UR -08 IN MINNESOTA. NAME DAVE"),
            Cue(period: 2, call: "K4LMB", to: Self.mycall, text: "GM NATHAN. GOOD SIGS INTO GEORGIA ON 40M. QMX AT 5W HERE"),
            Cue(period: 3, call: "KJ7ABP", to: Self.mycall, text: "MSG SEE YOU ON THE SUNDAY NET. 73"),
            Cue(period: 4, call: "W7GTK", to: "N0VBQ", text: "TNX DAVE, UR -12 HERE. 73"),
            Cue(period: 5, call: "KD5QRV", to: Self.mycall, text: "TNX FER THE REPORT. 73"),
            Cue(period: 6, call: "VE3NXR", to: "", text: "HB"),
            Cue(period: 7, call: "G4ZTW", to: "", text: "HB"),
        ]
    }

    private func add(_ call: String, _ grid: String, offset: Int, amplitude: Float) {
        var cfg = StationConfig()
        cfg.callsign = call
        cfg.grid = grid
        cfg.autoReply = false
        let s = JS8Station(config: cfg, inbox: Inbox(url: nil), clock: { AppClock.now() })
        s.offset = offset
        s.txDelay = 0
        stations[call] = Station(engine: s, amplitude: amplitude)
    }

    func start() {
        for cmd in ["tab0", "tab1", "tab2", "tab3", "tab4", "bands", "levels", "close"] {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
                guard let name = name?.rawValue as String? else { return }
                let cmd = String(name.dropFirst(DemoAir.commandPrefix.count))
                DispatchQueue.main.async { NotificationCenter.default.post(name: .demoCommand, object: cmd) }
            }, (Self.commandPrefix + cmd) as CFString, nil, .deliverImmediately)
        }
        let p = Double(JS8Submode.normal.period)
        firstPeriod = Int((AppClock.nowSeconds() / p).rounded(.down)) + 1
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func pump() {
        let rate = Double(RxRingBuffer.rate)
        let now = AppClock.nowSeconds()
        let p = Double(JS8Submode.normal.period)
        let period = Int((now / p).rounded(.down))
        if period != lastPeriod {
            lastPeriod = period
            beginPeriod(period, start: Double(period) * p)
        }

        let end = Int64(now * rate)
        if nextSample < 0 { nextSample = end - Int64(rate / 10) }
        guard end > nextSample else { return }
        let count = Int(end - nextSample)
        var chunk = [Float](repeating: 0, count: count)
        for i in 0..<count { chunk[i] = 300 * Self.gaussian() }
        for s in signals {
            let lo = max(s.start, nextSample), hi = min(s.start + Int64(s.wave.count), end)
            guard lo < hi else { continue }
            for idx in lo..<hi { chunk[Int(idx - nextSample)] += s.amplitude * s.wave[Int(idx - s.start)] }
        }
        signals.removeAll { $0.start + Int64($0.wave.count) < end }
        for i in 0..<count { chunk[i] *= Self.gain }
        let time = Double(nextSample) / rate
        chunk.withUnsafeBufferPointer { bp in
            ring.write(bp, time: time)
            spectrum.process(bp)
        }
        let power = chunk.reduce(0) { $0 + ($1 / 32767) * ($1 / 32767) } / Float(count)
        onLevel(10 * log10f(max(power, 1e-12)))
        nextSample = end
    }

    private func beginPeriod(_ period: Int, start: Double) {
        for s in transmitting { s.transmissionFinished() }
        transmitting.removeAll()
        // Loop the script so the band stays busy while screenshots are taken.
        let index = (period - firstPeriod) % 12
        for cue in cues where cue.period == index && period >= firstPeriod {
            guard let s = stations[cue.call]?.engine else { continue }
            switch cue.text {
            case "CQ": s.sendCQ()
            case "HB": s.sendHeartbeat()
            default:
                s.selectedCallsign = cue.to
                s.send(cue.text)
            }
        }
        let rate = Double(RxRingBuffer.rate)
        let at = Date(timeIntervalSince1970: start + 0.05)
        for (_, st) in stations {
            st.engine.tick()
            guard let req = st.engine.pollTransmit(now: at) else { continue }
            let wave = JS8Modulator.synthesize(tones: req.tones, frequency: Double(req.offset), submode: req.submode,
                                               sampleRate: rate)
            let begin = req.periodStart.timeIntervalSince1970 + Double(req.submode.startDelayMS) / 1000
            signals.append(Signal(start: Int64(begin * rate), wave: wave, amplitude: st.amplitude))
            transmitting.append(st.engine)
        }
    }

    private static func gaussian() -> Float {
        let u1 = Float.random(in: Float.ulpOfOne..<1), u2 = Float.random(in: 0..<1)
        return (-2 * logf(u1)).squareRoot() * cosf(2 * .pi * u2)
    }

    /// Settings for the demo station, applied in memory only.
    static func configure(_ s: inout AppSettings) {
        s.station.callsign = mycall
        s.station.grid = mygrid
        s.hasOnboarded = true
        s.offset = 1500
        s.dialFrequency = 7_078_000
        s.customFrequencies = [
            SavedFrequency(frequency: 7_078_000, label: "Sunday net"),
            SavedFrequency(frequency: 3_578_000, label: "Texas ARES"),
            SavedFrequency(frequency: 14_080_000, label: "Sked with K4LMB"),
        ]
    }
}
#endif

extension Notification.Name {
    /// A screenshot-capture command from DemoAir; the object is the command string.
    static let demoCommand = Notification.Name("JS8DemoCommand")
}
