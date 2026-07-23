import Foundation
import BannyCore
import BannyMedia

/// Studio and the CLI intentionally share one installed-voice catalog and one
/// sample-clock speech/lip-sync implementation.
typealias StudioSpeechVoice = SpeechVoiceDescriptor

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
        let speech = try await SpeechProduction.render(
            text: text,
            voiceIdentifier: voiceIdentifier)

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
        guard let voice = SpeechVoiceDescriptor.installed()
            .first(where: { $0.id == voiceIdentifier }) else {
            throw SpeechProductionError.voiceUnavailable
        }

        let originalCaptions = scene.characters[index].subs
        var staged: [(subtitleIndex: Int, start: Double,
                      speech: RenderedSpeech, mouthCues: [SpeechMouthCue])] = []
        for (subtitleIndex, subtitle) in originalCaptions.enumerated() {
            try Task.checkCancellation()
            let text = subtitle.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speech = try await SpeechProduction.render(
                text: text,
                voiceIdentifier: voiceIdentifier)
            staged.append((
                subtitleIndex,
                subtitle.start,
                speech,
                SpeechProduction.mouthCues(text: text, speech: speech)))
        }

        guard scene.characters.indices.contains(index),
              scene.characters[index].subs == originalCaptions,
              !scene.characters[index].locked else {
            throw SpeechProductionError.captionsChanged
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
            throw SpeechProductionError.missingMedia
        }
        let cues = try await Task.detached(priority: .userInitiated) {
            try SpeechProduction.analyzeMouth(
                data: media.data,
                fileExtension: media.ext)
        }.value
        guard scene.characters.indices.contains(index),
              !scene.characters[index].locked,
              scene.characters[index].clips.contains(where: { $0.id == clipID }) else {
            throw SpeechProductionError.missingMedia
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
