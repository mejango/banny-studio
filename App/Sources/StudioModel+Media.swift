import Foundation
import AVFoundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
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
        // Media stays in the package: undo only restores the timeline, so
        // deleting the bytes here would make a delete+undo silently lose audio.
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
        for i in scene.audioTracks.indices {
            for ci in scene.audioTracks[i].cues.indices where scene.audioTracks[i].cues[ci].id == id {
                scene.audioTracks[i].cues[ci].label = name
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

    /// Gallery click: copy a bundled backdrop into the document's asset bank
    /// (reusing an earlier copy if present) and cue it as the background.
    func addBundledBackdrop(url: URL) {
        let name = BuiltInBackdrops.displayName(url.lastPathComponent)
        if let existing = document.assets.first(where: { $0.name == name }) {
            addBackgroundCueApplyingAutoFrame(assetID: existing.id, assetName: existing.name)
            return
        }
        guard let data = try? Data(contentsOf: url),
              let asset = addAsset(data: data, ext: url.pathExtension.lowercased(), name: name)
        else { return }
        addBackgroundCueApplyingAutoFrame(assetID: asset.id, assetName: asset.name)
    }

    /// addBackgroundCue plus the first-backdrop frame snap (see
    /// Settings.autoFrame): a square backdrop on an untouched project makes
    /// the whole project square.
    func addBackgroundCueApplyingAutoFrame(assetID: String, assetName: String) {
        let hadCues = !scene.backgroundTracks.flatMap(\.cues).isEmpty
        addBackgroundCue(assetID: assetID, assetName: assetName)
        guard let media = file?.assetsMedia[assetID],
              let src = CGImageSourceCreateWithData(media.data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              let frame = document.settings.autoFrame(assetPixelW: w, assetPixelH: h,
                                                      hasBackgroundCues: hadCues)
        else { return }
        document.settings.frameW = frame.w
        document.settings.frameH = frame.h
    }

    /// Raw-bytes asset add (pasteboard, generated content).
    @discardableResult
    func addAsset(data: Data, ext: String, name: String) -> Asset? {
        registerUndoSnapshot(label: "Add Asset")
        let id = ShowDocumentFile.newID()
        let normalizedExtension = ext.lowercased()
        file?.assetsMedia[id] = (data, normalizedExtension)
        let kind = visualAssetKind(fileExtension: normalizedExtension)
        let asset = Asset(id: id, name: name, kind: kind, file: "\(id).\(normalizedExtension)")
        document.assets.append(asset)
        return asset
    }

    #if os(macOS)
    /// ⌘V with an image on the system pasteboard: import it to the bank and
    /// cue it on the given media track (or the selected/first one).
    @discardableResult
    func pasteImageFromPasteboard(mediaTrackIndex: Int? = nil, at t: Double? = nil) -> Bool {
        let pb = NSPasteboard.general
        var newAsset: Asset?
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first,
           isSupportedVisualFile(url) {
            newAsset = addAsset(from: url)
        } else if let data = pb.data(forType: .png) {
            newAsset = addAsset(data: data, ext: "png", name: "Pasted image")
        } else if let tiff = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            newAsset = addAsset(data: png, ext: "png", name: "Pasted image")
        }
        guard let asset = newAsset else { return false }
        let ti = mediaTrackIndex
            ?? scene.audioTracks.firstIndex { $0.id == selectedTrackKey }
            ?? scene.audioTracks.indices.first
        if let ti {
            addMediaImageCue(trackIndex: ti, assetID: asset.id, at: t ?? time)
        } else {
            addImageTrack(assetID: asset.id, assetName: asset.name)
        }
        return true
    }
    #endif

    /// Imports an image/video file into the bank and returns the new asset.
    @discardableResult
    func addAsset(from url: URL) -> Asset? {
        guard isSupportedVisualFile(url) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let kind = visualAssetKind(fileExtension: ext)
        registerUndoSnapshot(label: "Add Asset")
        let id = ShowDocumentFile.newID()
        file?.assetsMedia[id] = (data, ext)
        let asset = Asset(id: id, name: url.deletingPathExtension().lastPathComponent,
                          kind: kind, file: "\(id).\(ext)")
        document.assets.append(asset)
        return asset
    }

    /// File-kind detection shared by picker, paste, and drag/drop imports.
    /// AVFoundation-supported movies classify through UTType; common movie
    /// extensions remain covered on systems that do not register WebM/M4V.
    private func visualAssetKind(fileExtension ext: String) -> Asset.Kind {
        let ext = ext.lowercased()
        if ["mp4", "mov", "m4v", "webm"].contains(ext)
            || UTType(filenameExtension: ext)?.conforms(to: .movie) == true {
            return .video
        }
        return .image
    }

    private func isSupportedVisualFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if ["mp4", "mov", "m4v", "webm"].contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    func removeAsset(id: String) {
        registerUndoSnapshot(label: "Remove Asset")
        document.assets.removeAll { $0.id == id }
        // assetsMedia bytes stay for undo-safety (see removeClip).
        for i in scene.imageTracks.indices {
            scene.imageTracks[i].cues.removeAll { $0.assetID == id }
        }
        for i in scene.audioTracks.indices {
            scene.audioTracks[i].cues.removeAll { $0.assetID == id }
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
