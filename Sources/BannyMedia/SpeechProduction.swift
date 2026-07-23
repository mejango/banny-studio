import Foundation
import AVFoundation
import BannyCore

/// Stable, serializable metadata for one speech voice installed on this Mac.
/// This includes Apple voices, Personal Voice, and installed synthesis providers.
public struct SpeechVoiceDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let quality: String
    public let gender: String
    public let isPersonal: Bool
    public let isNovelty: Bool

    public init(id: String, name: String, language: String, quality: String,
                gender: String, isPersonal: Bool, isNovelty: Bool) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
        self.gender = gender
        self.isPersonal = isPersonal
        self.isNovelty = isNovelty
    }

    public static func installed() -> [SpeechVoiceDescriptor] {
        let preferredLanguage = Locale.preferredLanguages.first?
            .split(separator: "-").first.map(String.init) ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .map { voice in
                SpeechVoiceDescriptor(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    quality: qualityName(voice.quality),
                    gender: genderName(voice.gender),
                    isPersonal: voice.voiceTraits.contains(.isPersonalVoice),
                    isNovelty: voice.voiceTraits.contains(.isNoveltyVoice))
            }
            .sorted { lhs, rhs in
                let lhsPreferred = lhs.language.hasPrefix(preferredLanguage)
                let rhsPreferred = rhs.language.hasPrefix(preferredLanguage)
                if lhsPreferred != rhsPreferred { return lhsPreferred }
                if lhs.isPersonal != rhs.isPersonal { return lhs.isPersonal }
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    public static func recommendedIdentifier(
        in voices: [SpeechVoiceDescriptor]
    ) -> String? {
        voices.first(where: { !$0.isNovelty && $0.quality != "Default" })?.id
            ?? voices.first(where: { !$0.isNovelty })?.id
            ?? voices.first?.id
    }

    private static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .default: return "Default"
        @unknown default: return "Installed"
        }
    }

    private static func genderName(_ gender: AVSpeechSynthesisVoiceGender) -> String {
        switch gender {
        case .female: return "Feminine"
        case .male: return "Masculine"
        case .unspecified: return ""
        @unknown default: return ""
        }
    }
}

/// Portable speech source plus the real sample-clock evidence used to plan
/// deterministic mouth poses.
public struct RenderedSpeech: Sendable {
    public let data: Data
    public let duration: Double
    public let wordAnchors: [SpeechWordAnchor]
    public let energy: [Float]
    public let energyHop: Double

    public init(data: Data, duration: Double, wordAnchors: [SpeechWordAnchor],
                energy: [Float], energyHop: Double) {
        self.data = data
        self.duration = duration
        self.wordAnchors = wordAnchors
        self.energy = energy
        self.energyHop = energyHop
    }
}

public enum SpeechProductionError: LocalizedError, Sendable {
    case voiceUnavailable
    case noAudio
    case captionsChanged
    case missingMedia
    case unreadable
    case silent
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .voiceUnavailable:
            "That voice is no longer installed. Choose another voice."
        case .noAudio:
            "The selected voice did not produce any audio."
        case .captionsChanged:
            "The captions changed while speech was being generated. Try again."
        case .missingMedia:
            "The audio file is missing from this show."
        case .unreadable:
            "Banny Studio could not decode this audio file."
        case .silent:
            "No clear speech pattern was found in this audio."
        case .failed(let message):
            "Could not generate speech: \(message)"
        }
    }
}

/// Streaming RMS envelope shared by synthesized and imported audio. PCM is
/// never retained, keeping lip-sync analysis bounded for long recordings.
private final class PCMEnvelopeAccumulator {
    let hop = 0.01
    private(set) var energy: [Float] = []
    private var windowFrames = 0
    private var frameCount = 0
    private var squaredSum = 0.0

    func consume(_ pcm: AVAudioPCMBuffer) {
        let channelCount = Int(pcm.format.channelCount)
        guard channelCount > 0,
              pcm.format.commonFormat == .pcmFormatFloat32
                || pcm.format.commonFormat == .pcmFormatInt16
                || pcm.format.commonFormat == .pcmFormatInt32 else { return }
        if windowFrames == 0 {
            windowFrames = max(1, Int((pcm.format.sampleRate * hop).rounded()))
        }
        let interleaved = pcm.format.isInterleaved

        for frame in 0..<Int(pcm.frameLength) {
            var square = 0.0
            for channel in 0..<channelCount {
                let sample: Double
                switch pcm.format.commonFormat {
                case .pcmFormatFloat32:
                    guard let data = pcm.floatChannelData else { continue }
                    sample = interleaved
                        ? Double(data[0][frame * channelCount + channel])
                        : Double(data[channel][frame])
                case .pcmFormatInt16:
                    guard let data = pcm.int16ChannelData else { continue }
                    let value = interleaved
                        ? data[0][frame * channelCount + channel]
                        : data[channel][frame]
                    sample = Double(value) / Double(Int16.max)
                case .pcmFormatInt32:
                    guard let data = pcm.int32ChannelData else { continue }
                    let value = interleaved
                        ? data[0][frame * channelCount + channel]
                        : data[channel][frame]
                    sample = Double(value) / Double(Int32.max)
                default:
                    continue
                }
                square += sample * sample
            }
            squaredSum += square / Double(channelCount)
            frameCount += 1
            if frameCount >= windowFrames { flush() }
        }
    }

    func finish() -> [Float] {
        flush()
        return energy
    }

    private func flush() {
        guard frameCount > 0 else { return }
        energy.append(Float(sqrt(squaredSum / Double(frameCount))))
        squaredSum = 0
        frameCount = 0
    }
}

/// Retains AVSpeechSynthesizer through its asynchronous write and captures
/// word callbacks against the same frame clock as the rendered CAF.
private final class SpeechRenderJob: NSObject, AVSpeechSynthesizerDelegate,
                                     @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("banny-speech-\(UUID().uuidString).caf")
    private let timingLock = NSLock()
    private var audioFile: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var sampleRate = 0.0
    private let envelope = PCMEnvelopeAccumulator()
    private var markerFrames: [(range: NSRange, frame: AVAudioFramePosition)] = []
    private var continuation: CheckedContinuation<RenderedSpeech, Swift.Error>?
    private var finished = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    deinit {
        try? FileManager.default.removeItem(at: outputURL)
    }

    func render(_ utterance: AVSpeechUtterance) async throws -> RenderedSpeech {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            synthesizer.write(utterance) { [weak self] buffer in
                self?.consume(buffer)
            }
        }
    }

    private func consume(_ buffer: AVAudioBuffer) {
        guard !finished else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            finish(.failure(SpeechProductionError.failed("unsupported audio buffer")))
            return
        }
        if pcm.frameLength == 0 {
            audioFile = nil
            let energy = envelope.finish()
            timingLock.lock()
            let capturedFrames = frames
            let capturedMarkers = markerFrames
            timingLock.unlock()
            guard capturedFrames > 0, sampleRate > 0,
                  let data = try? Data(contentsOf: outputURL) else {
                finish(.failure(SpeechProductionError.noAudio))
                return
            }
            finish(.success(RenderedSpeech(
                data: data,
                duration: Double(capturedFrames) / sampleRate,
                wordAnchors: capturedMarkers.map {
                    SpeechWordAnchor(
                        location: $0.range.location,
                        length: $0.range.length,
                        time: Double($0.frame) / sampleRate)
                },
                energy: energy,
                energyHop: envelope.hop)))
            return
        }

        do {
            if audioFile == nil {
                audioFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: pcm.format.settings,
                    commonFormat: pcm.format.commonFormat,
                    interleaved: pcm.format.isInterleaved)
                sampleRate = pcm.format.sampleRate
            }
            envelope.consume(pcm)
            try audioFile?.write(from: pcm)
            timingLock.lock()
            frames += AVAudioFramePosition(pcm.frameLength)
            timingLock.unlock()
        } catch {
            finish(.failure(SpeechProductionError.failed(error.localizedDescription)))
        }
    }

    private func finish(_ result: Result<RenderedSpeech, Swift.Error>) {
        guard !finished else { return }
        finished = true
        audioFile = nil
        let continuation = continuation
        self.continuation = nil
        try? FileManager.default.removeItem(at: outputURL)
        continuation?.resume(with: result)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        timingLock.lock()
        markerFrames.append((characterRange, frames))
        timingLock.unlock()
    }
}

public enum SpeechProduction {
    public static func render(
        text: String,
        voiceIdentifier: String,
        rate: Float = AVSpeechUtteranceDefaultSpeechRate,
        pitchMultiplier: Float = 1,
        volume: Float = 1
    ) async throws -> RenderedSpeech {
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else {
            throw SpeechProductionError.voiceUnavailable
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate, rate))
        utterance.pitchMultiplier = min(2, max(0.5, pitchMultiplier))
        utterance.volume = min(1, max(0, volume))
        return try await SpeechRenderJob().render(utterance)
    }

    public static func mouthCues(
        text: String,
        speech: RenderedSpeech
    ) -> [SpeechMouthCue] {
        SpeechMouthPlanner.cues(
            text: text,
            duration: speech.duration,
            wordAnchors: speech.wordAnchors,
            energy: speech.energy,
            energyHop: speech.energyHop)
    }

    public static func analyzeMouth(url: URL) throws -> [SpeechMouthCue] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SpeechProductionError.missingMedia
        }
        guard let file = try? AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false) else {
            throw SpeechProductionError.unreadable
        }
        let sampleRate = file.processingFormat.sampleRate
        guard file.length > 0, sampleRate > 0 else {
            throw SpeechProductionError.unreadable
        }

        let envelope = PCMEnvelopeAccumulator()
        let capacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: capacity) else {
            throw SpeechProductionError.unreadable
        }
        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0 else { break }
            envelope.consume(buffer)
        }
        let cues = SpeechMouthPlanner.waveformCues(
            duration: Double(file.length) / sampleRate,
            energy: envelope.finish(),
            energyHop: envelope.hop)
        guard !cues.isEmpty else { throw SpeechProductionError.silent }
        return cues
    }

    public static func analyzeMouth(data: Data,
                                    fileExtension: String) throws -> [SpeechMouthCue] {
        let ext = fileExtension.isEmpty ? "caf" : fileExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("banny-mouth-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        return try analyzeMouth(url: url)
    }
}
