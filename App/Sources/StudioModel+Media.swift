import Foundation
import AVFoundation
import BannyCore

/// Media + editing operations: audio clips, backgrounds, captions, clipboard.
extension StudioModel {

    // MARK: - Audio clips

    /// Imports an audio file as a clip at the playhead on a character's track,
    /// a specific audio track, or the first audio track.
    func addAudioClip(from url: URL, characterIndex: Int?, audioTrackIndex: Int? = nil,
                      at startTime: Double? = nil) {
        let time = startTime ?? self.time
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let avFile = try? AVAudioFile(forReading: url) else { return }
        let dur = Double(avFile.length) / avFile.processingFormat.sampleRate
        guard dur > 0 else { return }

        registerUndoSnapshot(label: "Add Audio")
        let id = ShowDocumentFile.newID()
        file?.audio[id] = (data, url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased())
        let clip = AudioClip(id: id, name: url.deletingPathExtension().lastPathComponent,
                             start: time, dur: dur, srcDur: dur)
        if let i = characterIndex, scene.characters.indices.contains(i) {
            scene.characters[i].clips.append(clip)
        } else if let ti = audioTrackIndex, scene.audioTracks.indices.contains(ti) {
            scene.audioTracks[ti].clips.append(clip)
        } else {
            if scene.audioTracks.isEmpty {
                scene.audioTracks.append(AudioTrack(id: ShowDocumentFile.newID(), name: "Audio"))
            }
            scene.audioTracks[0].clips.append(clip)
        }
    }

    /// Registers a finished mic recording as a clip at `startTime`.
    func addRecordedClip(data: Data, ext: String, dur: Double, startTime: Double, characterIndex: Int?) {
        registerUndoSnapshot(label: "Record Audio")
        let id = ShowDocumentFile.newID()
        file?.audio[id] = (data, ext)
        let clip = AudioClip(id: id, name: "Take \(Date().formatted(date: .omitted, time: .shortened))",
                             start: startTime, dur: dur, srcDur: dur)
        if let i = characterIndex, scene.characters.indices.contains(i) {
            scene.characters[i].clips.append(clip)
        } else {
            if scene.audioTracks.isEmpty {
                scene.audioTracks.append(AudioTrack(id: ShowDocumentFile.newID(), name: "Audio"))
            }
            scene.audioTracks[0].clips.append(clip)
        }
    }

    /// Web splitClip: cut a clip in two at time t preserving source offset.
    func splitClip(id: String, at t: Double) {
        registerUndoSnapshot(label: "Split Clip")
        func split(_ clips: inout [AudioClip]) {
            guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
            let c = clips[i]
            guard t > c.start + 0.05, t < c.start + c.dur - 0.05 else { return }
            let cut = t - c.start
            var left = c
            left.dur = cut
            var right = c
            // The right half references the same source bytes at a deeper offset.
            right.start = t
            right.dur = c.dur - cut
            right.offset = c.offset + cut
            clips[i] = left
            clips.insert(right, at: i + 1)
        }
        for i in scene.characters.indices { split(&scene.characters[i].clips) }
        for i in scene.audioTracks.indices { split(&scene.audioTracks[i].clips) }
    }

    func removeClip(id: String) {
        registerUndoSnapshot(label: "Delete Clip")
        for i in scene.characters.indices {
            scene.characters[i].clips.removeAll { $0.id == id }
        }
        for i in scene.audioTracks.indices {
            scene.audioTracks[i].clips.removeAll { $0.id == id }
        }
        // Source bytes stay in the package if another slice still references them.
        let stillUsed = scene.characters.flatMap(\.clips).contains { $0.id == id }
            || scene.audioTracks.flatMap(\.clips).contains { $0.id == id }
        if !stillUsed { file?.audio.removeValue(forKey: id) }
    }

    func moveClip(id: String, toStart newStart: Double) {
        func move(_ clips: inout [AudioClip]) {
            guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
            clips[i].start = max(0, newStart)
        }
        for i in scene.characters.indices { move(&scene.characters[i].clips) }
        for i in scene.audioTracks.indices { move(&scene.audioTracks[i].clips) }
    }

    // MARK: - Renames

    func renameClip(id: String, to name: String) {
        registerUndoSnapshot(label: "Rename Clip")
        for i in scene.characters.indices {
            for ci in scene.characters[i].clips.indices where scene.characters[i].clips[ci].id == id {
                scene.characters[i].clips[ci].name = name
            }
        }
        for i in scene.audioTracks.indices {
            for ci in scene.audioTracks[i].clips.indices where scene.audioTracks[i].clips[ci].id == id {
                scene.audioTracks[i].clips[ci].name = name
            }
        }
    }

    func renameCue(id: String, to name: String) {
        registerUndoSnapshot(label: "Rename Cue")
        for i in scene.imageTracks.indices {
            for ci in scene.imageTracks[i].cues.indices where scene.imageTracks[i].cues[ci].id == id {
                scene.imageTracks[i].cues[ci].label = name
            }
        }
        for i in scene.backgroundTracks.indices {
            for ci in scene.backgroundTracks[i].cues.indices where scene.backgroundTracks[i].cues[ci].id == id {
                scene.backgroundTracks[i].cues[ci].label = name
            }
        }
        for i in scene.lightTracks.indices {
            for ci in scene.lightTracks[i].cues.indices where scene.lightTracks[i].cues[ci].id == id {
                scene.lightTracks[i].cues[ci].label = name
            }
        }
    }

    // MARK: - Asset bank

    /// Imports an image/video file into the bank and returns the new asset.
    @discardableResult
    func addAsset(from url: URL) -> Asset? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let kind: Asset.Kind = ["mp4", "mov", "webm", "m4v"].contains(ext) ? .video : .image
        registerUndoSnapshot(label: "Add Asset")
        let id = ShowDocumentFile.newID()
        file?.assetsMedia[id] = (data, ext)
        let asset = Asset(id: id, name: url.deletingPathExtension().lastPathComponent,
                          kind: kind, file: "\(id).\(ext)")
        document.assets.append(asset)
        return asset
    }

    func removeAsset(id: String) {
        registerUndoSnapshot(label: "Remove Asset")
        document.assets.removeAll { $0.id == id }
        file?.assetsMedia.removeValue(forKey: id)
        for i in scene.imageTracks.indices {
            scene.imageTracks[i].cues.removeAll { $0.assetID == id }
        }
        for i in scene.backgroundTracks.indices {
            scene.backgroundTracks[i].cues.removeAll { $0.assetID == id }
        }
        backgroundRevision += 1
    }

    // MARK: - Captions (web syncSubsFromText)

    /// One caption per non-empty line. Existing timings are preserved by index;
    /// new lines start where the previous caption ends, 2 s each.
    func syncCaptions(characterIndex: Int, fromText text: String) {
        guard scene.characters.indices.contains(characterIndex) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let old = scene.characters[characterIndex].subs
        var subs: [Subtitle] = []
        for (i, line) in lines.enumerated() {
            if i < old.count {
                subs.append(Subtitle(text: line, start: old[i].start, dur: old[i].dur))
            } else {
                let start = subs.last.map { $0.start + $0.dur } ?? 0
                subs.append(Subtitle(text: line, start: start, dur: 2))
            }
        }
        scene.characters[characterIndex].subs = subs
    }

    func captionsText(characterIndex: Int) -> String {
        guard scene.characters.indices.contains(characterIndex) else { return "" }
        return scene.characters[characterIndex].subs.map(\.text).joined(separator: "\n")
    }
}
