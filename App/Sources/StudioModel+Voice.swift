import Foundation
import AVFoundation
import BannyCore
import BannyMedia

/// A stable, UI-friendly snapshot of one voice installed on this device.
/// The catalog includes Apple voices and voices supplied by installed speech
/// synthesis providers.
struct StudioSpeechVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let quality: String
    let gender: String
    let isPersonal: Bool
    let isNovelty: Bool

    static func installed() -> [StudioSpeechVoice] {
        let preferredLanguage = Locale.preferredLanguages.first?
            .split(separator: "-").first.map(String.init) ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .map { voice in
                StudioSpeechVoice(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    quality: qualityName(voice.quality),
                    gender: genderName(voice.gender),
                    isPersonal: voice.voiceTraits.contains(.isPersonalVoice),
                    isNovelty: voice.voiceTraits.contains(.isNoveltyVoice))
            }
            .sorted { lhs, rhs in
                let lPreferred = lhs.language.hasPrefix(preferredLanguage)
                let rPreferred = rhs.language.hasPrefix(preferredLanguage)
                if lPreferred != rPreferred { return lPreferred }
                if lhs.isPersonal != rhs.isPersonal { return lhs.isPersonal }
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func recommendedIdentifier(in voices: [StudioSpeechVoice]) -> String? {
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

private struct RenderedSpeech {
    let data: Data
    let duration: Double
    let wordAnchors: [SpeechWordAnchor]
    let energy: [Float]
    let energyHop: Double
}

private enum SpeechRenderError: LocalizedError {
    case voiceUnavailable
    case noAudio
    case captionsChanged
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .voiceUnavailable:
            return "That voice is no longer installed. Choose another voice."
        case .noAudio:
            return "The selected voice did not produce any audio."
        case .captionsChanged:
            return "The captions changed while speech was being generated. Try again."
        case .failed(let message):
            return "Could not generate speech: \(message)"
        }
    }
}

/// Streaming RMS envelope shared by synthesized and recorded/imported audio.
/// It never retains PCM, so an hour-long take is analyzed in bounded memory.
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
                case .pcmFormatFloat64:
                    continue
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
                case .otherFormat:
                    continue
                @unknown default:
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

/// Retains AVSpeechSynthesizer for the entire asynchronous write and collects
/// its PCM buffers into a package-friendly Core Audio file.
private final class SpeechRenderJob: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
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
            finish(.failure(SpeechRenderError.failed("unsupported audio buffer")))
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
                finish(.failure(SpeechRenderError.noAudio))
                return
            }
            let anchors = capturedMarkers.map {
                SpeechWordAnchor(
                    location: $0.range.location,
                    length: $0.range.length,
                    time: Double($0.frame) / sampleRate)
            }
            finish(.success(RenderedSpeech(
                data: data,
                duration: Double(capturedFrames) / sampleRate,
                wordAnchors: anchors,
                energy: energy,
                energyHop: envelope.hop)))
            return
        }

        do {
            if audioFile == nil {
                audioFile = try AVAudioFile(forWriting: outputURL,
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
            finish(.failure(SpeechRenderError.failed(error.localizedDescription)))
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

private enum AudioMouthAnalysisError: LocalizedError {
    case missingMedia
    case unreadable
    case silent

    var errorDescription: String? {
        switch self {
        case .missingMedia:
            "The audio file is missing from this show."
        case .unreadable:
            "Banny Studio could not decode this audio file."
        case .silent:
            "No clear speech pattern was found in this audio."
        }
    }
}

private enum AudioMouthAnalyzer {
    static func cues(data: Data, fileExtension: String) throws -> [SpeechMouthCue] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("banny-mouth-analysis-\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        guard let file = try? AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false) else {
            throw AudioMouthAnalysisError.unreadable
        }
        let sampleRate = file.processingFormat.sampleRate
        guard file.length > 0, sampleRate > 0 else {
            throw AudioMouthAnalysisError.unreadable
        }

        let envelope = PCMEnvelopeAccumulator()
        let capacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: capacity) else {
            throw AudioMouthAnalysisError.unreadable
        }
        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0 else { break }
            envelope.consume(buffer)
        }
        let duration = Double(file.length) / sampleRate
        let cues = SpeechMouthPlanner.waveformCues(
            duration: duration,
            energy: envelope.finish(),
            energyHop: envelope.hop)
        guard !cues.isEmpty else { throw AudioMouthAnalysisError.silent }
        return cues
    }
}

/// Retains the exact same graph used by timeline playback/export while a
/// recipe preview is sounding.
@MainActor
final class VoiceRecipePreviewPlayer {
    private var graph: AudioGraph?
    private var sourceURL: URL?
    private var cleanupTask: Task<Void, Never>?

    deinit {
        cleanupTask?.cancel()
        graph?.engine.stop()
        if let sourceURL { try? FileManager.default.removeItem(at: sourceURL) }
    }

    func stop() {
        cleanupTask?.cancel()
        cleanupTask = nil
        graph?.stopAll()
        graph?.engine.stop()
        graph = nil
        if let sourceURL { try? FileManager.default.removeItem(at: sourceURL) }
        sourceURL = nil
    }

    func preview(text: String, voiceIdentifier: String,
                 recipe: VoiceRecipe) async throws {
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else {
            throw SpeechRenderError.voiceUnavailable
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1
        utterance.volume = 1
        let speech = try await SpeechRenderJob().render(utterance)

        stop()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("banny-recipe-preview-\(UUID().uuidString).caf")
        try speech.data.write(to: url, options: .atomic)
        let clipID = "preview-speech"
        let clip = AudioClip(id: clipID, name: "Recipe preview", start: 0,
                             dur: speech.duration, srcDur: speech.duration,
                             kind: .speech)
        let character = Character(
            body: .original,
            clips: [clip],
            speechVoice: SpeechVoiceProfile(
                voiceIdentifier: voiceIdentifier,
                recipe: recipe))
        let graph = AudioGraph()
        try graph.build(scene: SceneState(characters: [character])) { id in
            id == clipID ? url : nil
        }
        try graph.engine.start()
        graph.schedule(from: 0)
        graph.updateLevels(timelineTime: 0)
        graph.playAll()
        self.sourceURL = url
        self.graph = graph

        let lifetime = UInt64(max(1, speech.duration + 2.5) * 1_000_000_000)
        cleanupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: lifetime)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
}

extension StudioModel {
    /// Renders every nonempty caption using a natural installed voice, then
    /// atomically replaces only previously generated caption speech. Imported
    /// files and microphone takes remain untouched.
    @discardableResult
    func generateSpeechCaptions(characterIndex index: Int,
                                voiceIdentifier: String) async throws -> Int {
        guard scene.characters.indices.contains(index),
              !scene.characters[index].locked,
              let file else { return 0 }
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else {
            throw SpeechRenderError.voiceUnavailable
        }

        let originalCaptions = scene.characters[index].subs
        var staged: [(subtitleIndex: Int, start: Double,
                      speech: RenderedSpeech, mouthCues: [SpeechMouthCue])] = []
        for (subtitleIndex, subtitle) in originalCaptions.enumerated() {
            try Task.checkCancellation()
            let text = subtitle.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1
            utterance.volume = 1
            let speech = try await SpeechRenderJob().render(utterance)
            let mouthCues = SpeechMouthPlanner.cues(
                text: text,
                duration: speech.duration,
                wordAnchors: speech.wordAnchors,
                energy: speech.energy,
                energyHop: speech.energyHop)
            staged.append((subtitleIndex, subtitle.start, speech, mouthCues))
        }

        guard scene.characters.indices.contains(index),
              scene.characters[index].subs == originalCaptions,
              !scene.characters[index].locked else {
            throw SpeechRenderError.captionsChanged
        }

        registerUndoSnapshot(label: "Generate Caption Speech")
        var character = scene.characters[index]
        character.clips.removeAll {
            $0.kind == .speech || $0.id.hasPrefix("tts-") || $0.id.hasPrefix("ani-")
        }
        character.speechVoice.voiceIdentifier = voiceIdentifier
        for item in staged {
            let id = "tts-\(ShowDocumentFile.newID())"
            file.audio[id] = (item.speech.data, "caf")
            character.clips.append(AudioClip(
                id: id,
                name: "Speech \(item.subtitleIndex + 1) · \(voice.name)",
                start: item.start,
                dur: item.speech.duration,
                srcDur: item.speech.duration,
                kind: .speech,
                mouthCues: item.mouthCues))
        }
        character.clips.sort { $0.start < $1.start }
        scene.characters[index] = character
        resyncAudioIfPlaying()
        return staged.count
    }

    func setSpeechVoiceIdentifier(characterIndex index: Int, identifier: String?) {
        guard scene.characters.indices.contains(index),
              !scene.characters[index].locked,
              scene.characters[index].speechVoice.voiceIdentifier != identifier else { return }
        registerUndoSnapshot(label: "Choose Speech Voice")
        scene.characters[index].speechVoice.voiceIdentifier = identifier
    }

    func setVoiceRecipe(characterIndex index: Int, recipe: VoiceRecipe,
                        undoLabel: String = "Change Voice Recipe") {
        guard scene.characters.indices.contains(index),
              !scene.characters[index].locked,
              scene.characters[index].speechVoice.recipe != recipe else { return }
        registerUndoSnapshot(label: undoLabel)
        scene.characters[index].speechVoice.recipe = recipe
        resyncAudioIfPlaying()
    }

    func beginVoiceRecipeAdjustment(characterIndex index: Int) {
        guard scene.characters.indices.contains(index),
              !scene.characters[index].locked else { return }
        registerUndoSnapshot(label: "Adjust Voice Recipe")
    }

    func updateVoiceRecipeDuringAdjustment(characterIndex index: Int,
                                           _ transform: (inout VoiceRecipe) -> Void) {
        guard scene.characters.indices.contains(index),
              !scene.characters[index].locked else { return }
        transform(&scene.characters[index].speechVoice.recipe)
    }

    func finishVoiceRecipeAdjustment() {
        resyncAudioIfPlaying()
    }

    func setAutomaticSpeechMouth(characterIndex index: Int, enabled: Bool) {
        guard scene.characters.indices.contains(index),
              !scene.characters[index].locked,
              scene.characters[index].speechVoice.automaticMouth != enabled else { return }
        registerUndoSnapshot(label: enabled ? "Enable Automatic Mouth" : "Disable Automatic Mouth")
        scene.characters[index].speechVoice.automaticMouth = enabled
    }

    /// Sample-aligned waveform lip sync for microphone takes and imported
    /// dialogue. Generated TTS uses the richer text-aware path above.
    @discardableResult
    func analyzeClipMouth(characterIndex index: Int, clipID: String) async throws -> Int {
        guard scene.characters.indices.contains(index),
              !scene.characters[index].locked,
              scene.characters[index].clips.contains(where: { $0.id == clipID }),
              let media = file?.audio[clipID] else {
            throw AudioMouthAnalysisError.missingMedia
        }
        let cues = try await Task.detached(priority: .userInitiated) {
            try AudioMouthAnalyzer.cues(
                data: media.data,
                fileExtension: media.ext.isEmpty ? "caf" : media.ext)
        }.value
        guard scene.characters.indices.contains(index),
              !scene.characters[index].locked,
              scene.characters[index].clips.contains(where: { $0.id == clipID }) else {
            throw AudioMouthAnalysisError.missingMedia
        }
        registerUndoSnapshot(label: "Analyze Mouth Timing")
        for clipIndex in scene.characters[index].clips.indices
        where scene.characters[index].clips[clipIndex].id == clipID {
            scene.characters[index].clips[clipIndex].mouthCues = cues
        }
        return cues.count
    }

    func clearClipMouth(characterIndex index: Int, clipID: String) {
        guard scene.characters.indices.contains(index),
              !scene.characters[index].locked,
              scene.characters[index].clips.contains(where: {
                  $0.id == clipID && !$0.mouthCues.isEmpty
              }) else { return }
        registerUndoSnapshot(label: "Clear Mouth Timing")
        for clipIndex in scene.characters[index].clips.indices
        where scene.characters[index].clips[clipIndex].id == clipID {
            scene.characters[index].clips[clipIndex].mouthCues = []
        }
    }
}
