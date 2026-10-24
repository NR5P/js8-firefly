import AVFoundation
import Foundation
import JS8Core
import os

/// How the transmitter is keyed.
enum PTTMethod: String, Codable, CaseIterable, Identifiable {
    /// Digirig Lite "PTT by tone": JS8 audio on the left channel, a keying
    /// tone on the right channel which drives the Digirig's PTT circuit.
    case digirigTone
    /// Audio on both channels; the interface or radio keys on audio (VOX),
    /// e.g. Digirig VOX, QMX/QDX digi mode, or radio VOX.
    case vox
    /// PTT command through the configured rig control (CAT / rigctld / flrig).
    case cat
    /// RTS line of a serial port (e.g. Digirig Mobile on a Mac).
    case serialRTS
    /// DTR line of a serial port.
    case serialDTR
    /// No keying (receive-only or external PTT).
    case none

    var id: String { rawValue }

    static var available: [PTTMethod] {
        #if os(macOS)
        return allCases
        #else
        return allCases.filter { $0 != .serialRTS && $0 != .serialDTR }
        #endif
    }

    var title: String {
        switch self {
        case .digirigTone: return "Digirig Lite – PTT tone (right ch.)"
        case .vox: return "VOX – audio on both channels"
        case .cat: return "CAT / rig control command"
        case .serialRTS: return "Serial RTS (Digirig Mobile on Mac)"
        case .serialDTR: return "Serial DTR"
        case .none: return "None (receive only)"
        }
    }
}

/// Audio settings that the render thread reads.
struct TxAudioSettings: Sendable, Equatable, Codable {
    var pttMethod: PTTMethod = .digirigTone
    var toneFrequency: Double = 1000
    var toneLevel: Float = 0.7
    var leadTime: Double = 0.15
    var tailTime: Double = 0.10
    var outputLevel: Float = 0.5
    var swapChannels = false
}

/// One transmission prepared for the render thread.
final class TxPlayback: @unchecked Sendable {
    let payload: [Float]
    let payloadStart: Double      // UTC seconds of payload sample 0
    let settings: TxAudioSettings
    let rate: Double
    let isTune: Bool
    var cursor: Int?              // render-thread state
    var tonePhase: Double = 0
    var finished = false

    init(payload: [Float], payloadStart: Double, settings: TxAudioSettings, rate: Double, isTune: Bool = false) {
        self.payload = payload
        self.payloadStart = payloadStart
        self.settings = settings
        self.rate = rate
        self.isTune = isTune
    }
}

/// Audio input (receive) and output (transmit) using two AVAudioEngines so
/// that input and output can live on different devices (useful on macOS).
final class AudioIO: @unchecked Sendable {
    let ring = RxRingBuffer()
    let spectrum = SpectrumAnalyzer()

    private let inputEngine = AVAudioEngine()
    private let outputEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var converter: AVAudioConverter?
    private let processingQueue = DispatchQueue(label: "js8.audio.rx", qos: .userInitiated)
    private let txLock = OSAllocatedUnfairLock<TxPlayback?>(initialState: nil)
    private var outputRate: Double = 48000
    private(set) var inputRunning = false
    private(set) var outputRunning = false

    /// Input channel: 0 = left, 1 = right, -1 = mix.
    var inputChannel = 0
    /// dBFS of the most recent input block.
    private(set) var inputLevel: Float = -120
    var onInputLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?

    #if os(macOS)
    var inputDeviceID: AudioDeviceID?
    var outputDeviceID: AudioDeviceID?
    #endif

    // MARK: Session (iOS)

    func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            if let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) {
                try session.setPreferredInput(usb)
            }
            if session.maximumOutputNumberOfChannels >= 2 {
                try? session.setPreferredOutputNumberOfChannels(2)
            }
        } catch {
            onError?("Audio session: \(error.localizedDescription)")
        }
        #endif
    }

    static func requestRecordPermission(_ done: @escaping (Bool) -> Void) {
        #if os(iOS)
        AVAudioApplication.requestRecordPermission { done($0) }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { done($0) }
        default: done(false)
        }
        #endif
    }

    /// Human readable description of the current route.
    var routeDescription: String {
        #if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute
        let ins = route.inputs.map(\.portName).joined(separator: ", ")
        let outs = route.outputs.map { "\($0.portName) (\($0.channels?.count ?? 0) ch)" }.joined(separator: ", ")
        return "In: \(ins.isEmpty ? "–" : ins)  •  Out: \(outs.isEmpty ? "–" : outs)"
        #else
        let i = inputDeviceID.flatMap { MacAudioDevices.name(of: $0) } ?? "System default"
        let o = outputDeviceID.flatMap { MacAudioDevices.name(of: $0) } ?? "System default"
        return "In: \(i)  •  Out: \(o)"
        #endif
    }

    var isUSBInterfaceConnected: Bool {
        #if os(iOS)
        return AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .usbAudio }
        #else
        return [inputDeviceID, outputDeviceID].compactMap { $0 }.contains { MacAudioDevices.isUSB($0) }
        #endif
    }

    // MARK: Start / stop

    func start() {
        startInput()
        startOutput()
    }

    func stop() {
        inputEngine.inputNode.removeTap(onBus: 0)
        inputEngine.stop()
        outputEngine.stop()
        inputRunning = false
        outputRunning = false
    }

    func restart() {
        stop()
        configureSession()
        start()
    }

    private func startInput() {
        let input = inputEngine.inputNode
        #if os(macOS)
        if let id = inputDeviceID {
            do { try input.auAudioUnit.setDeviceID(id) } catch { onError?("Input device: \(error.localizedDescription)") }
        }
        #endif
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            onError?("No audio input available")
            return
        }
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hwFormat.sampleRate, channels: 1, interleaved: false)!
        let rxFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(RxRingBuffer.rate), channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: monoFormat, to: rxFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, when in
            self?.handleInput(buffer, when: when, monoFormat: monoFormat, rxFormat: rxFormat)
        }
        do {
            inputEngine.prepare()
            try inputEngine.start()
            inputRunning = true
        } catch {
            onError?("Input start: \(error.localizedDescription)")
        }
    }

    private func handleInput(_ buffer: AVAudioPCMBuffer, when: AVAudioTime, monoFormat: AVAudioFormat, rxFormat: AVAudioFormat) {
        guard let converter, let src = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        mono.frameLength = AVAudioFrameCount(frames)
        let dst = mono.floatChannelData![0]
        let ch = inputChannel
        var sumsq: Float = 0
        for i in 0..<frames {
            var v: Float
            if ch < 0 || channels == 1 {
                v = 0
                for c in 0..<channels { v += src[c][i] }
                v /= Float(channels)
            } else {
                v = src[min(ch, channels - 1)][i]
            }
            dst[i] = v
            sumsq += v * v
        }
        let level = 10 * log10f(max(sumsq / Float(max(frames, 1)), 1e-12))
        inputLevel = level

        // Capture time of the first sample in UTC.
        var time = AppClock.nowSeconds() - Double(frames) / buffer.format.sampleRate
        if when.isHostTimeValid {
            let hostNow = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            time = AppClock.nowSeconds() - (hostNow - AVAudioTime.seconds(forHostTime: when.hostTime))
        }
        #if os(iOS)
        time -= AVAudioSession.sharedInstance().inputLatency
        #endif

        let outCapacity = AVAudioFrameCount(Double(frames) * rxFormat.sampleRate / monoFormat.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: rxFormat, frameCapacity: outCapacity) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return mono
        }
        let n = Int(out.frameLength)
        guard n > 0, let p = out.floatChannelData?[0] else { return }
        // Scale to 16-bit sample units like JS8Call's int16 buffer.
        var scaled = [Float](repeating: 0, count: n)
        for i in 0..<n { scaled[i] = p[i] * 32767 }
        processingQueue.async { [weak self] in
            guard let self else { return }
            scaled.withUnsafeBufferPointer { bp in
                self.ring.write(bp, time: time)
                self.spectrum.process(bp)
            }
            self.onInputLevel?(level)
        }
    }

    private func startOutput() {
        let output = outputEngine.outputNode
        #if os(macOS)
        if let id = outputDeviceID {
            do { try output.auAudioUnit.setDeviceID(id) } catch { onError?("Output device: \(error.localizedDescription)") }
        }
        #endif
        let hw = output.outputFormat(forBus: 0)
        outputRate = hw.sampleRate > 0 ? hw.sampleRate : 48000
        let channels = AVAudioChannelCount(max(1, min(2, Int(hw.channelCount))))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: channels, interleaved: false)!

        if let old = sourceNode { outputEngine.detach(old) }
        let node = AVAudioSourceNode(format: format) { [weak self] _, timestamp, frameCount, abl -> OSStatus in
            self?.render(timestamp: timestamp, frames: Int(frameCount), abl: abl) ?? noErr
        }
        sourceNode = node
        outputEngine.attach(node)
        outputEngine.connect(node, to: outputEngine.mainMixerNode, format: format)
        outputEngine.mainMixerNode.outputVolume = 1
        do {
            outputEngine.prepare()
            try outputEngine.start()
            outputRunning = true
        } catch {
            onError?("Output start: \(error.localizedDescription)")
        }
    }

    // MARK: Transmit

    var outputSampleRate: Double { outputRate }

    /// Schedule a frame. The payload starts at `periodStart + startDelay`.
    func transmit(_ req: TxRequest, settings: TxAudioSettings) {
        let payload = JS8Modulator.synthesize(tones: req.tones, frequency: Double(req.offset), submode: req.submode,
                                              sampleRate: outputRate, amplitude: 1)
        let start = req.periodStart.timeIntervalSince1970 + Double(req.submode.startDelayMS) / 1000
        txLock.withLock { $0 = TxPlayback(payload: payload, payloadStart: start, settings: settings, rate: outputRate) }
    }

    /// Continuous carrier at `frequency` for tuning, until `stopTransmit()`.
    func tune(frequency: Double, settings: TxAudioSettings) {
        let seconds = 1.0
        let n = Int(outputRate * seconds)
        var tone = [Float](repeating: 0, count: n)
        // Integer number of cycles so the loop is seamless.
        let cycles = (frequency * seconds).rounded()
        for i in 0..<n { tone[i] = Float(sin(2 * Double.pi * cycles * Double(i) / Double(n))) }
        let samples = tone
        txLock.withLock { $0 = TxPlayback(payload: samples, payloadStart: AppClock.nowSeconds() + settings.leadTime, settings: settings, rate: outputRate, isTune: true) }
    }

    func stopTransmit() {
        txLock.withLock { $0 = nil }
    }

    /// True while audio (including PTT tail) is still being produced.
    var isPlaying: Bool {
        txLock.withLock { p in p.map { !$0.finished } ?? false }
    }

    /// UTC seconds when the current transmission's audio ends (incl. tail).
    var playbackEnd: Double? {
        txLock.withLock { p in
            guard let p, !p.isTune else { return nil }
            return p.payloadStart + Double(p.payload.count) / p.rate + p.settings.tailTime
        }
    }

    private func render(timestamp: UnsafePointer<AudioTimeStamp>, frames: Int, abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        for b in buffers {
            if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
        }
        guard let playback = txLock.withLockIfAvailable({ $0 }) ?? nil, !playback.finished else { return noErr }

        let rate = playback.rate
        let s = playback.settings
        if playback.cursor == nil {
            var wall = AppClock.nowSeconds()
            if timestamp.pointee.mFlags.contains(.hostTimeValid) {
                let hostNow = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                wall = AppClock.nowSeconds() + (AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime) - hostNow)
            }
            #if os(iOS)
            wall += AVAudioSession.sharedInstance().outputLatency
            #endif
            playback.cursor = Int(((wall - playback.payloadStart) * rate).rounded())
        }
        var cursor = playback.cursor!
        let leadFrames = Int(s.leadTime * rate)
        let tailFrames = Int(s.tailTime * rate)
        let count = playback.payload.count
        let endFrame = playback.isTune ? Int.max : count + tailFrames
        let ramp = max(1, Int(0.004 * rate))
        let dphi = 2 * Double.pi * s.toneFrequency / rate

        let left = buffers.count > 0 ? buffers[0].mData?.assumingMemoryBound(to: Float.self) : nil
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil

        for i in 0..<frames {
            var payload: Float = 0
            if cursor >= 0 && cursor < count {
                payload = playback.payload[cursor] * s.outputLevel
            } else if playback.isTune && cursor >= 0 {
                payload = playback.payload[cursor % count] * s.outputLevel
            }
            var tone: Float = 0
            if s.pttMethod == .digirigTone && cursor >= -leadFrames && cursor < endFrame {
                let fromStart = cursor + leadFrames
                let toEnd = endFrame - cursor
                let env = Float(min(1, Double(min(fromStart, toEnd)) / Double(ramp)))
                tone = Float(sin(playback.tonePhase)) * s.toneLevel * env
                playback.tonePhase += dphi
                if playback.tonePhase > 2 * Double.pi { playback.tonePhase -= 2 * Double.pi }
            }
            if let right {
                switch s.pttMethod {
                case .digirigTone:
                    let (l, r) = s.swapChannels ? (tone, payload) : (payload, tone)
                    left?[i] = l
                    right[i] = r
                default:
                    left?[i] = payload
                    right[i] = payload
                }
            } else {
                left?[i] = payload
            }
            cursor += 1
        }
        playback.cursor = cursor
        if cursor >= endFrame { playback.finished = true }
        return noErr
    }
}

#if os(macOS)
import CoreAudio

/// CoreAudio device enumeration for picking a USB interface on the Mac.
enum MacAudioDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let inputs: Int
        let outputs: Int
        let isUSB: Bool
    }

    static func all() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let name = name(of: id) else { return nil }
            return Device(id: id, name: name, inputs: channels(id, input: true), outputs: channels(id, input: false), isUSB: isUSB(id))
        }
    }

    static func name(of id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }

    static func channels(_ id: AudioDeviceID, input: Bool) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func isUSB(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeUSB
    }
}
#endif
