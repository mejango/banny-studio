import Foundation
import AVFoundation
import BannyCore

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

/// Retains AVSpeechSynthesizer for the entire asynchronous write and collects
/// its PCM buffers into a package-friendly Core Audio file.
private final class SpeechRenderJob: @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("banny-speech-\(UUID().uuidString).caf")
    private var audioFile: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var sampleRate = 0.0
    private var continuation: CheckedContinuation<RenderedSpeech, Swift.Error>?
    private var finished = false

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
            guard frames > 0, sampleRate > 0,
                  let data = try? Data(contentsOf: outputURL) else {
                finish(.failure(SpeechRenderError.noAudio))
                return
            }
            finish(.success(RenderedSpeech(
                data: data,
                duration: Double(frames) / sampleRate)))
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
            try audioFile?.write(from: pcm)
            frames += AVAudioFramePosition(pcm.frameLength)
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
        var staged: [(subtitleIndex: Int, start: Double, speech: RenderedSpeech)] = []
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
            staged.append((subtitleIndex, subtitle.start, speech))
        }

        guard scene.characters.indices.contains(index),
              scene.characters[index].subs == originalCaptions,
              !scene.characters[index].locked else {
            throw SpeechRenderError.captionsChanged
        }

        registerUndoSnapshot(label: "Generate Caption Speech")
        var character = scene.characters[index]
        character.clips.removeAll {
            $0.id.hasPrefix("tts-") || $0.id.hasPrefix("ani-")
        }
        for item in staged {
            let id = "tts-\(ShowDocumentFile.newID())"
            file.audio[id] = (item.speech.data, "caf")
            character.clips.append(AudioClip(
                id: id,
                name: "Speech \(item.subtitleIndex + 1) · \(voice.name)",
                start: item.start,
                dur: item.speech.duration,
                srcDur: item.speech.duration))
        }
        character.clips.sort { $0.start < $1.start }
        scene.characters[index] = character
        resyncAudioIfPlaying()
        return staged.count
    }
}
