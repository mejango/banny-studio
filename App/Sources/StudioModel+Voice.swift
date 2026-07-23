import Foundation
import BannyCore
import BannyMedia

/// Studio and the CLI intentionally share one installed-voice catalog and one
/// sample-clock speech/lip-sync implementation.
typealias StudioSpeechVoice = SpeechVoiceDescriptor

struct VoiceRecipePreviewPlayback: Sendable {
    let startedAt: TimeInterval
    let duration: Double
    let mouthCues: [SpeechMouthCue]
}

/// Retains the exact same graph used by timeline playback/export while a
/// recipe preview is sounding.
@MainActor
final class VoiceRecipePreviewPlayer {
    private var graph: AudioGraph?
    private var sourceURL: URL?
    private var cleanupTask: Task<Void, Never>?
    private var requestID: UUID?

    deinit {
        cleanupTask?.cancel()
        graph?.engine.stop()
        if let sourceURL { try? FileManager.default.removeItem(at: sourceURL) }
    }

    func stop() {
        requestID = nil
        cleanupTask?.cancel()
        cleanupTask = nil
        graph?.stopAll()
        graph?.engine.stop()
        graph = nil
        if let sourceURL { try? FileManager.default.removeItem(at: sourceURL) }
        sourceURL = nil
    }

    func preview(text: String, voiceIdentifier: String,
                 recipe: VoiceRecipe) async throws -> VoiceRecipePreviewPlayback {
        stop()
        let requestID = UUID()
        self.requestID = requestID
        let speech: RenderedSpeech
        do {
            speech = try await SpeechProduction.render(
                text: text,
                voiceIdentifier: voiceIdentifier)
        } catch {
            if self.requestID == requestID { self.requestID = nil }
            throw error
        }
        if Task.isCancelled {
            if self.requestID == requestID { self.requestID = nil }
            throw CancellationError()
        }
        guard self.requestID == requestID else { throw CancellationError() }
        let mouthCues = SpeechProduction.mouthCues(text: text, speech: speech)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("banny-recipe-preview-\(UUID().uuidString).caf")
        do {
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
            let startedAt = ProcessInfo.processInfo.systemUptime
            graph.playAll()
            self.sourceURL = url
            self.graph = graph

            let lifetime = UInt64(max(1, speech.duration + 2.5) * 1_000_000_000)
            cleanupTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: lifetime)
                guard !Task.isCancelled, self?.requestID == requestID else { return }
                self?.stop()
            }
            return VoiceRecipePreviewPlayback(
                startedAt: startedAt,
                duration: speech.duration,
                mouthCues: mouthCues)
        } catch {
            try? FileManager.default.removeItem(at: url)
            if self.requestID == requestID { self.requestID = nil }
            throw error
        }
    }
}

extension StudioModel {
    func startSpeechMouthPreview(characterIndex: Int,
                                 playback: VoiceRecipePreviewPlayback) {
        stopSpeechMouthPreview()
        guard scene.characters.indices.contains(characterIndex),
              scene.characters[characterIndex].speechVoice.automaticMouth,
              playback.duration > 0 else { return }
        let token = UUID()
        speechMouthPreview = SpeechMouthPreview(
            token: token,
            characterIndex: characterIndex,
            startedAt: playback.startedAt,
            duration: playback.duration,
            cues: playback.mouthCues)
        let lifetime = UInt64(playback.duration * 1_000_000_000)
        speechMouthPreviewCleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: lifetime)
            } catch {
                return
            }
            guard let self, self.speechMouthPreview?.token == token else { return }
            self.speechMouthPreview = nil
            self.speechMouthPreviewCleanupTask = nil
        }
    }

    func stopSpeechMouthPreview(characterIndex: Int? = nil) {
        if let characterIndex,
           speechMouthPreview?.characterIndex != characterIndex { return }
        speechMouthPreviewCleanupTask?.cancel()
        speechMouthPreviewCleanupTask = nil
        speechMouthPreview = nil
    }

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
        if !enabled { stopSpeechMouthPreview(characterIndex: index) }
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
        if selectedMouthCue?.character == index,
           selectedMouthCue?.clipID == clipID {
            selectedMouthCue = nil
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
        if selectedMouthCue?.character == index,
           selectedMouthCue?.clipID == clipID {
            selectedMouthCue = nil
        }
    }

    func mouthCueValue(_ selection: MouthCueSelection) -> SpeechMouthCue? {
        guard scene.characters.indices.contains(selection.character),
              let clip = scene.characters[selection.character].clips
                .first(where: { $0.id == selection.clipID }),
              clip.mouthCues.indices.contains(selection.cueIndex) else { return nil }
        return clip.mouthCues[selection.cueIndex]
    }

    var selectedMouthCueValue: SpeechMouthCue? {
        selectedMouthCue.flatMap(mouthCueValue)
    }

    var selectedMouthCueTimelineStart: Double? {
        guard let selection = selectedMouthCue,
              scene.characters.indices.contains(selection.character),
              let clip = scene.characters[selection.character].clips
                .first(where: { $0.id == selection.clipID }),
              clip.mouthCues.indices.contains(selection.cueIndex) else { return nil }
        return clip.start + clip.mouthCues[selection.cueIndex].start - clip.offset
    }

    func selectMouthCue(_ selection: MouthCueSelection) {
        guard mouthCueValue(selection) != nil else {
            selectedMouthCue = nil
            return
        }
        selectedMouthCue = selection
        selectedMarks = []
        selectedClips = []
        selectedImageCue = nil
        selectedBackgroundCue = nil
        selectedBackgroundCues = []
        selectedLightCue = nil
        selectedOutfitEvent = nil
        selectedMotionEvent = nil
        selectedReaction = nil
        self.selection = [selection.character]
        selectedTrackKey = "c-\(selection.character)"
    }

    /// Moves one virtual M-key interval without crossing its neighbours.
    /// Source-relative edits continue to follow clip moves, trims, and splits.
    func moveMouthCue(_ selection: MouthCueSelection, toStart requestedStart: Double,
                      registerUndo: Bool = true) {
        guard let path = mouthCuePath(selection) else { return }
        let cues = scene.characters[path.character].clips[path.clip].mouthCues
        let cue = cues[path.cue]
        let sourceDuration = scene.characters[path.character].clips[path.clip].srcDur
        let absoluteLower = 0.0
        let absoluteUpper = max(0, sourceDuration - cue.dur)
        let neighbourLower = path.cue > 0
            ? cues[path.cue - 1].start + cues[path.cue - 1].dur : absoluteLower
        let neighbourUpper = path.cue + 1 < cues.count
            ? cues[path.cue + 1].start - cue.dur : absoluteUpper
        let lower = max(absoluteLower, neighbourLower)
        let upper = min(absoluteUpper, neighbourUpper)
        let allowed = lower <= upper
            ? min(upper, max(lower, requestedStart))
            : min(absoluteUpper, max(absoluteLower, requestedStart))
        let start = Self.millisecond(allowed)
        guard abs(start - cue.start) > 0.000_5 else { return }
        if registerUndo { registerUndoSnapshot(label: "Nudge Mouth Timing") }
        scene.characters[path.character].clips[path.clip].mouthCues[path.cue].start = start
    }

    /// Trims an interval edge. A 10 ms minimum prevents accidental zero-width
    /// presses while still allowing sample-level dialogue cleanup.
    func resizeMouthCue(_ selection: MouthCueSelection, start requestedStart: Double,
                        duration requestedDuration: Double,
                        registerUndo: Bool = true) {
        guard let path = mouthCuePath(selection) else { return }
        let cues = scene.characters[path.character].clips[path.clip].mouthCues
        let old = cues[path.cue]
        let sourceDuration = scene.characters[path.character].clips[path.clip].srcDur
        let minimumDuration = 0.01
        let previousEnd = path.cue > 0
            ? cues[path.cue - 1].start + cues[path.cue - 1].dur : 0
        let nextStart = path.cue + 1 < cues.count
            ? cues[path.cue + 1].start : sourceDuration
        let maximumEnd = max(previousEnd + minimumDuration, min(sourceDuration, nextStart))
        let start = min(maximumEnd - minimumDuration,
                        max(previousEnd, requestedStart))
        let duration = min(maximumEnd - start,
                           max(minimumDuration, requestedDuration))
        let edited = SpeechMouthCue(
            start: Self.millisecond(start),
            dur: Self.millisecond(duration),
            shape: .open)
        guard edited != old else { return }
        if registerUndo { registerUndoSnapshot(label: "Fine-tune Mouth Timing") }
        scene.characters[path.character].clips[path.clip].mouthCues[path.cue] = edited
    }

    func adjustSelectedMouthCueDuration(by delta: Double) {
        guard let selection = selectedMouthCue,
              let cue = mouthCueValue(selection) else { return }
        resizeMouthCue(selection, start: cue.start, duration: cue.dur + delta)
    }

    func deleteMouthCue(_ selection: MouthCueSelection, registerUndo: Bool = true) {
        guard let path = mouthCuePath(selection) else {
            if selectedMouthCue == selection { selectedMouthCue = nil }
            return
        }
        if registerUndo { registerUndoSnapshot(label: "Delete Mouth Interval") }
        scene.characters[path.character].clips[path.clip].mouthCues.remove(at: path.cue)
        if selectedMouthCue == selection { selectedMouthCue = nil }
    }

    private func mouthCuePath(_ selection: MouthCueSelection)
        -> (character: Int, clip: Int, cue: Int)? {
        guard scene.characters.indices.contains(selection.character),
              !scene.characters[selection.character].locked,
              let clip = scene.characters[selection.character].clips
                .firstIndex(where: { $0.id == selection.clipID }),
              scene.characters[selection.character].clips[clip].mouthCues.indices
                .contains(selection.cueIndex) else { return nil }
        return (selection.character, clip, selection.cueIndex)
    }

    private static func millisecond(_ value: Double) -> Double {
        (max(0, value) * 1000).rounded() / 1000
    }
}
