import Accelerate
import AVFoundation
import Core
import CoreAudio
import FluidAudio
import os
import Synchronization

/// Microphone + on-device transcription (Parakeet Unified, streaming). Reports back only through `send`,
/// tagged with the take number, so a late result for an old take is inert.
final class Speech {
    /// The 320 ms streaming tier: a chunk of 2 encoder frames plus 2 of look-ahead.
    private nonisolated static let tier = UnifiedConfig(leftFrames: 70, chunkFrames: 2, rightFrames: 2)

    /// A term replaces a heard word only when the audio alone favors it (cbw 0) and the spelling is close (0.7):
    /// FluidAudio's dictation setting. The defaults also turned "speech analysis" into SpeechAnalyzer in a sentence that never named it.
    private nonisolated static let thresholds = VocabularyBoostingSession.Thresholds(cbw: 0, minSimilarity: 0.7)

    let meter = Meter()
    private var engine = AVAudioEngine()
    /// The input device `engine` records from: always the system default, checked at each take.
    private var device = AudioDeviceID(kAudioObjectUnknown)
    /// Loaded and warmed once at launch; nil until then. Takes run one at a time on it.
    private var manager: StreamingUnifiedAsrManager?
    /// The CTC model that checks the selection's names against the audio; nil if it didn't load (notes are then not boosted).
    private var ctc: CtcModels?
    /// Whether `manager` still holds a take's vocabulary, which the next take must replace.
    private var boosted = false
    /// Names that arrived after the take started (the quote came in late), for its task to apply between buffers.
    private var late: (take: Int, words: [String])?
    private var preparing = false
    private var current: (take: Int, input: AsyncStream<[Float]>.Continuation, task: Task<Void, Never>)?
    /// The previous take's task: the next take waits for its `finish` and `reset` before it feeds the manager.
    private var previous: Task<Void, Never>?

    func prepare() {
        guard !preparing, manager == nil else { return }
        preparing = true
        Task {
            defer { preparing = false }
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return send(.voice(.unavailable("Microphone access denied"))) }
            useDefaultInput()   // the first engine's setup happens here, not on the first keypress
            // Only whole-percent changes reach step: at most ~100 events per download. The CTC model's pass starts over from 0.
            let report: @Sendable (DownloadProgress) -> Void = { progress in
                let percent = Int(progress.fractionCompleted * 100)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch world.voice {
                        case .preparing: send(.voice(.downloading(percent)))
                        case .downloading(let shown) where shown != percent: send(.voice(.downloading(percent)))
                        default: break
                        }
                    }
                }
            }
            do {
                let loaded = StreamingUnifiedAsrManager(config: Self.tier)
                try await loaded.loadModels(progressHandler: report)
                try await Self.warmUp(loaded)
                ctc = try? await CtcModels.downloadAndLoad(progressHandler: report)
                manager = loaded
                send(.voice(.ready))
            } catch {
                send(.voice(.unavailable("Voice model unavailable: \(error.localizedDescription)")))
            }
        }
    }

    /// One chunk of silence through the whole pipeline, so the first real take pays no compile or allocation cost.
    private nonisolated static func warmUp(_ manager: StreamingUnifiedAsrManager) async throws {
        let count = tier.chunkSamples + tier.rightSamples
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        silence.frameLength = AVAudioFrameCount(count)
        silence.floatChannelData?[0].update(repeating: 0, count: count)
        try await manager.appendAudio(silence)
        try await manager.processBufferedAudio()
        try await manager.reset()
    }

    func start(take: Int, words: [String]) {
        guard let manager else { return send(.final(take: take, "")) }
        useDefaultInput()
        let mic = engine.inputNode.inputFormat(forBus: 0)   // the hardware's rate; outputFormat can still hold the previous device's
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mic, to: target) else { return send(.final(take: take, "")) }
        let (stream, input) = AsyncStream.makeStream(of: [Float].self)
        let tap = Tap(converter: converter, output: target, input: input, meter: meter)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: mic) { @Sendable buffer, _ in tap.feed(buffer) }
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            return send(.final(take: take, ""))
        }
        let before = previous
        let task = Task {
            await before?.value
            await bias(words)
            await manager.setPartialTranscriptCallback { text in
                DispatchQueue.main.async { MainActor.assumeIsolated { send(.partial(take: take, text)) } }
            }
            for await samples in stream {
                if Task.isCancelled { break }
                if let names = late, names.take == take {
                    late = nil
                    await bias(names.words)
                }
                guard let buffer = Self.buffer(samples) else { continue }
                try? await manager.appendAudio(buffer)
                try? await manager.processBufferedAudio()
            }
            let text = Task.isCancelled ? nil : try? await manager.finish()
            await manager.setPartialTranscriptCallback { _ in }
            try? await manager.reset()
            if !Task.isCancelled { send(.final(take: take, text ?? "")) }
        }
        current = (take, input, task)
        previous = task
    }

    /// The quote arrived after the take started: bias the rest of it toward these names.
    func words(take: Int, _ words: [String]) {
        guard current?.take == take else { return }
        late = (take, words)
    }

    /// Points the manager's vocabulary boosting at `words`, or, with none, clears what the last take left.
    /// Mid-stream is fine: FluidAudio then rescores only the audio from here on.
    private func bias(_ words: [String]) async {
        guard let manager, let ctc, boosted || !words.isEmpty, !Task.isCancelled else { return }
        log.notice("boosting: \(words.joined(separator: ", "), privacy: .public)")
        let vocabulary = CustomVocabularyContext(terms: words.map { CustomVocabularyTerm(text: $0) })
        do {
            try await manager.configureVocabularyBoosting(vocabulary: vocabulary, ctcModels: ctc, thresholds: Self.thresholds)
            boosted = !words.isEmpty
        } catch {}
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
        current.task.cancel()
        current.input.finish()
        self.current = nil
    }

    private func stopMic() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        meter.set(0)
    }

    private nonisolated static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData?[0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
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
}

/// Local system log; `log show --predicate 'subsystem == "app.sendpoint"'` reads it.
private let log = Logger(subsystem: "app.sendpoint", category: "voice")

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

/// Runs on the audio thread: converts mic buffers to 16 kHz mono samples for the model.
nonisolated final class Tap: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let input: AsyncStream<[Float]>.Continuation
    private let meter: Meter

    init(converter: AVAudioConverter, output: AVAudioFormat, input: AsyncStream<[Float]>.Continuation, meter: Meter) {
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
        if error == nil, converted.frameLength > 0, let channel = converted.floatChannelData?[0] {
            input.yield(Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
        }
    }
}
