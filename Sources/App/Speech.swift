import Accelerate
import AVFoundation
import Core
import CoreAudio
import Speech
import Synchronization

/// Microphone + on-device transcription. Reports back only through `send`,
/// tagged with the take number, so a late result for an old take is inert.
final class Speech {
    let meter = Meter()
    private var engine = AVAudioEngine()
    /// The input device `engine` records from: always the system default, checked at each take.
    private var device = AudioDeviceID(kAudioObjectUnknown)
    /// The locale the loaded transcriber uses; set once `prepare` finishes.
    private var locale = Locale.current
    private var format: AVAudioFormat?
    /// A prepared transcriber + analyzer, so a take starts without loading anything.
    private var spare: (SpeechTranscriber, SpeechAnalyzer)?
    private var current: (take: Int, input: AsyncStream<AnalyzerInput>.Continuation, analyzer: SpeechAnalyzer)?
    /// The last locale setting asked for, so repeating it does nothing.
    private var requested: String?
    /// Counts `prepare` calls; a prepare that finds a newer one has begun is stale and stops.
    private var generation = 0
    /// The one microphone prompt, asked on the first `prepare`.
    private var microphone: Task<Bool, Never>?
    /// The locale whose assets are reserved; released when a different one replaces it.
    private var reserved: Locale?

    func prepare(locale setting: String) {
        guard requested != setting else { return }
        requested = setting
        generation += 1
        let mine = generation
        spare = nil
        format = nil
        Task {
            if microphone == nil { microphone = Task { await AVCaptureDevice.requestAccess(for: .audio) } }
            guard await microphone!.value else { return send(.voice(.unavailable("Microphone access denied"))) }
            guard mine == generation else { return }
            useDefaultInput()   // the first engine's setup happens here, not on the first keypress
            let wanted = setting.isEmpty ? Locale.current : Locale(identifier: setting)
            // An unsupported system language falls back to US English; a language set in the config doesn't.
            let fallback = setting.isEmpty ? Locale(identifier: "en-US") : nil
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) ?? fallback
            guard mine == generation else { return }
            guard let resolved else { return send(.voice(.unavailable("No voice for \(setting)"))) }
            let probe = makeTranscriber(resolved)
            do {
                if let install = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    send(.voice(.downloading(0)))
                    let watch = install.progress.observe(\.fractionCompleted) { progress, _ in
                        let percent = Int(progress.fractionCompleted * 100)
                        Task { @MainActor in
                            // Only whole-percent changes reach step: at most ~100 events for the download.
                            if mine == self.generation, case .downloading(let shown) = world.voice, shown < percent { send(.voice(.downloading(percent))) }
                        }
                    }
                    defer { watch.invalidate() }
                    try await install.downloadAndInstall()
                }
            } catch {
                guard mine == generation else { return }
                return send(.voice(.unavailable("Voice model unavailable: \(error.localizedDescription)")))
            }
            if reserved != resolved {
                let old = reserved
                reserved = resolved
                _ = try? await AssetInventory.reserve(locale: resolved)
                if let old { _ = await AssetInventory.release(reservedLocale: old) }
            }
            let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
            guard mine == generation else { return }
            (locale, format) = (resolved, best)
            await prepareSpare()
            guard mine == generation else { return }
            send(.voice(format == nil ? .unavailable("Voice unavailable") : .ready))
        }
    }

    func start(take: Int) {
        guard let format else { return send(.final(take: take, "")) }
        let (transcriber, analyzer) = spare ?? fresh()
        spare = nil
        useDefaultInput()
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let mic = engine.inputNode.inputFormat(forBus: 0)   // the hardware's rate; outputFormat can still hold the previous device's
        guard let converter = AVAudioConverter(from: mic, to: format) else { return send(.final(take: take, "")) }
        let tap = Tap(converter: converter, output: format, input: input, meter: meter)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: mic) { @Sendable buffer, _ in tap.feed(buffer) }
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            return send(.final(take: take, ""))
        }
        current = (take, input, analyzer)

        let results = Task {
            var text = ""
            for try await result in transcriber.results {
                let piece = String(result.text.characters)
                if result.isFinal { text = Self.append(text, piece) }
                send(.partial(take: take, result.isFinal ? text : Self.append(text, piece)))
            }
            return text
        }
        Task {
            do {
                if let end = try await analyzer.analyzeSequence(stream) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                send(.final(take: take, try await results.value))
            } catch {
                results.cancel()
                send(.final(take: take, ""))
            }
            await prepareSpare()
        }
    }

    /// Ends the audio; the take's task finalizes and sends `.final`.
    func stop(take: Int) {
        guard let current, current.take == take else { return }
        stopMic()
        current.input.finish()
        self.current = nil
    }

    func cancel() {
        guard let current else { return }
        stopMic()
        current.input.finish()
        self.current = nil
        Task { await current.analyzer.cancelAndFinishNow() }
    }

    private func stopMic() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        meter.set(0)
    }

    /// AVAudioEngine keeps the device it was built with, so a new default input (AirPods connecting,
    /// a pick in Sound settings) gets a fresh engine pinned to it. Cheap when nothing changed: one property read.
    private func useDefaultInput() {
        let now = defaultInputDevice()
        guard now != device else { return }
        engine = AVAudioEngine()
        if let unit = engine.inputNode.audioUnit {
            var id = now
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        device = now
        engine.prepare()
    }

    private func prepareSpare() async {
        guard spare == nil, let format else { return }
        let mine = generation
        let pair = fresh()
        try? await pair.1.prepareToAnalyze(in: format)
        if spare == nil, mine == generation { spare = pair }
    }

    private func fresh() -> (SpeechTranscriber, SpeechAnalyzer) {
        let transcriber = makeTranscriber(locale)
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        return (transcriber, SpeechAnalyzer(modules: [transcriber], options: options))
    }

    private func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    private static func append(_ text: String, _ piece: String) -> String {
        if text.isEmpty || piece.isEmpty || text.last!.isWhitespace || piece.first!.isWhitespace { return text + piece }
        return text + " " + piece
    }
}

/// The input device chosen in System Settings › Sound right now.
private func defaultInputDevice() -> AudioDeviceID {
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    return id
}

/// Mic loudness, 0...1. Written by the audio thread, read by the card each frame.
nonisolated final class Meter: Sendable {
    private let bits = Atomic<UInt32>(0)
    var level: Float { Float(bitPattern: bits.load(ordering: .relaxed)) }
    func set(_ level: Float) { bits.store(level.bitPattern, ordering: .relaxed) }
}

/// Runs on the audio thread: converts mic buffers to the analyzer's format.
nonisolated final class Tap: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let meter: Meter

    init(converter: AVAudioConverter, output: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation, meter: Meter) {
        self.converter = converter
        self.output = output
        self.input = input
        self.meter = meter
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var power: Float = 0
            vDSP_measqv(samples, 1, &power, vDSP_Length(buffer.frameLength))
            let db = 10 * log10(max(power, 1e-10))   // power → dB
            meter.set(min(max((db + 55) / 45, 0), 1))
        }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
    }
}
