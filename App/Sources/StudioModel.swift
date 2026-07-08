import SwiftUI
import Observation
import BannyCore

/// Per-document editor state: transport, recording, selection, scene switching.
/// Stage state is always derived via SceneSimulator — this model only owns the
/// document and the clock.
@MainActor
@Observable
final class StudioModel {
    var document: ShowDocument
    weak var file: ShowDocumentFile?
    var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = 0 } // 0 = unlimited history
    }

    // Transport (web TL).
    var time: Double = 0
    var playing = false
    var recording = false
    var recTargets: Set<Int> = []
    private var recPunched: [Int: Set<EventGroup>] = [:]
    private var recStartTime: Double = 0
    private var startWall: TimeInterval = 0

    // Editor state.
    var selection: Set<Int> = [0]
    /// The track whose inspector the right panel shows (TrackRow key).
    var selectedTrackKey: String? = "c-0"
    var activeSceneIndex: Int
    /// Held live keys → the codes currently down, per character (drives live sim while recording).
    private(set) var heldCodes: Set<EventCode> = []
    /// Bumped whenever background media changes so caches invalidate.
    var backgroundRevision = 0

    // Timeline selection (shared with keyboard shortcuts).
    var selectedMarks: Set<PerfMark> = []
    var selectedClips: Set<String> = []
    /// Image cue selected on the timeline (drag on stage repositions it).
    var selectedImageCue: String?
    var selectedBackgroundCue: String?
    /// A clicked outfit-change dot: (character, index into its events).
    var selectedOutfitEvent: (char: Int, index: Int)?
    /// Track key whose gutter-card popover should open (double-click on the cell).
    var inspectorRequest: String?
    var selectedLightCue: String?
    private var markClipboard: [(character: Int, code: EventCode, start: Double, end: Double)] = []

    /// ⌘C: copy selected marks (times kept relative to the earliest mark).
    func copySelectedMarks() {
        guard !selectedMarks.isEmpty else { return }
        let t0 = selectedMarks.map(\.start).min() ?? 0
        markClipboard = selectedMarks.map { ($0.character, $0.code, $0.start - t0, $0.end - t0) }
    }

    /// ⌘V: paste right after the selected marks (or at the playhead when nothing
    /// is selected). The copies become the selection, so repeated ⌘V chains.
    func pasteMarks() {
        guard !markClipboard.isEmpty else { return }
        registerUndoSnapshot(label: "Paste Marks")
        let base = selectedMarks.map(\.end).max().map { $0 + 0.05 } ?? time
        var pasted: Set<PerfMark> = []
        for m in markClipboard {
            guard scene.characters.indices.contains(m.character) else { continue }
            var events = scene.characters[m.character].events
            let s = ((base + m.start) * 1000).rounded() / 1000
            let e = ((base + m.end) * 1000).rounded() / 1000
            events.append(.key(t: s, code: m.code, down: true))
            events.append(.key(t: e, code: m.code, down: false))
            events.sort { $0.t < $1.t }
            scene.characters[m.character].events = events
            pasted.insert(PerfMark(character: m.character, code: m.code, start: s, end: e))
        }
        if !pasted.isEmpty { selectedMarks = pasted }
    }

    /// ⌘-drag: duplicate the selected marks (nudged +0.05s so the copies are
    /// distinct) and select the copies — the drag then moves the copies.
    func duplicateSelectedMarksInPlace() {
        guard !selectedMarks.isEmpty else { return }
        registerUndoSnapshot(label: "Duplicate Marks")
        var dups: Set<PerfMark> = []
        for m in selectedMarks {
            guard scene.characters.indices.contains(m.character) else { continue }
            var events = scene.characters[m.character].events
            let s = m.start + 0.05
            let e = m.end + 0.05
            events.append(.key(t: s, code: m.code, down: true))
            events.append(.key(t: e, code: m.code, down: false))
            events.sort { $0.t < $1.t }
            scene.characters[m.character].events = events
            dups.insert(PerfMark(character: m.character, code: m.code, start: s, end: e))
        }
        selectedMarks = dups
    }

    /// Mutates a clip wherever it lives (character or audio track).
    private func setClip(id: String, _ transform: (inout AudioClip) -> Void) {
        for i in scene.characters.indices {
            if let ci = scene.characters[i].clips.firstIndex(where: { $0.id == id }) {
                transform(&scene.characters[i].clips[ci])
                return
            }
        }
        for i in scene.audioTracks.indices {
            if let ci = scene.audioTracks[i].clips.firstIndex(where: { $0.id == id }) {
                transform(&scene.audioTracks[i].clips[ci])
                return
            }
        }
    }

    /// Edge-drag trim: leading edge slides start (revealing/hiding the source
    /// head), trailing edge changes duration (capped by the source length).
    func trimClip(id: String, leading: Bool, baseStart: Double, baseDur: Double,
                  baseOffset: Double, srcDur: Double, dt: Double) {
        setClip(id: id) { clip in
            if leading {
                let minStart = max(0, baseStart - baseOffset)
                let newStart = min(max(baseStart + dt, minStart), baseStart + baseDur - 0.2)
                clip.offset = baseOffset + (newStart - baseStart)
                clip.dur = baseDur - (newStart - baseStart)
                clip.start = newStart
            } else {
                clip.dur = min(max(0.2, baseDur + dt), max(0.2, srcDur - baseOffset))
            }
        }
    }

    /// ⌘-drag: clone a clip in place (media ref copied) and return the copy's id.
    func duplicateClip(id: String) -> String? {
        registerUndoSnapshot(label: "Duplicate Clip")
        func clone(_ clips: inout [AudioClip]) -> String? {
            guard let ci = clips.firstIndex(where: { $0.id == id }) else { return nil }
            var copy = clips[ci]
            copy.id = ShowDocumentFile.newID()
            if let media = file?.audio[id] { file?.audio[copy.id] = media }
            clips.insert(copy, at: ci + 1)
            return copy.id
        }
        for i in scene.characters.indices {
            if let nid = clone(&scene.characters[i].clips) { return nid }
        }
        for i in scene.audioTracks.indices {
            if let nid = clone(&scene.audioTracks[i].clips) { return nid }
        }
        return nil
    }

    /// ⌘-drag: clone a cue in place; returns the copy's id.
    func duplicateCue(kind: TrackRowKind, id: String) -> String? {
        registerUndoSnapshot(label: "Duplicate Cue")
        switch kind {
        case .image(let i):
            guard scene.imageTracks.indices.contains(i),
                  let ci = scene.imageTracks[i].cues.firstIndex(where: { $0.id == id }) else { return nil }
            var copy = scene.imageTracks[i].cues[ci]
            copy.id = ShowDocumentFile.newID()
            scene.imageTracks[i].cues.insert(copy, at: ci + 1)
            selectedImageCue = copy.id
            return copy.id
        case .light(let i):
            guard scene.lightTracks.indices.contains(i),
                  let ci = scene.lightTracks[i].cues.firstIndex(where: { $0.id == id }) else { return nil }
            var copy = scene.lightTracks[i].cues[ci]
            copy.id = ShowDocumentFile.newID()
            scene.lightTracks[i].cues.insert(copy, at: ci + 1)
            selectedLightCue = copy.id
            return copy.id
        case .background(let i):
            guard scene.backgroundTracks.indices.contains(i),
                  let ci = scene.backgroundTracks[i].cues.firstIndex(where: { $0.id == id }) else { return nil }
            var copy = scene.backgroundTracks[i].cues[ci]
            copy.id = ShowDocumentFile.newID()
            scene.backgroundTracks[i].cues.insert(copy, at: ci + 1)
            selectedBackgroundCue = copy.id
            return copy.id
        case .audio(let i):
            guard scene.audioTracks.indices.contains(i),
                  let ci = scene.audioTracks[i].cues.firstIndex(where: { $0.id == id }) else { return nil }
            var copy = scene.audioTracks[i].cues[ci]
            copy.id = ShowDocumentFile.newID()
            scene.audioTracks[i].cues.insert(copy, at: ci + 1)
            selectedImageCue = copy.id
            return copy.id
        default:
            return nil
        }
    }

    // MARK: - Unified timeline clipboard (marks + clips + cues)

    private var clipClipboard: [(owner: String, clip: AudioClip)] = []
    private var imageCueClipboard: [(trackID: String, cue: ImageCue)] = []
    private var lightCueClipboard: [(trackID: String, cue: LightCue)] = []
    private var bgCueClipboard: [BackgroundCue] = []

    var hasTimelineSelection: Bool {
        !selectedMarks.isEmpty || !selectedClips.isEmpty || selectedImageCue != nil
            || selectedLightCue != nil || selectedBackgroundCue != nil
    }

    /// ⌘C / right-click Copy: everything selected, times relative to the earliest.
    func copyTimelineSelection() {
        var t0 = Double.greatestFiniteMagnitude
        for m in selectedMarks { t0 = min(t0, m.start) }
        var pickedClips: [(String, AudioClip)] = []
        for (i, c) in scene.characters.enumerated() {
            for clip in c.clips where selectedClips.contains(clip.id) {
                pickedClips.append(("c\(i)", clip))
                t0 = min(t0, clip.start)
            }
        }
        for t in scene.audioTracks {
            for clip in t.clips where selectedClips.contains(clip.id) {
                pickedClips.append((t.id, clip))
                t0 = min(t0, clip.start)
            }
        }
        var pickedImage: [(String, ImageCue)] = []
        if let owner = selectedImageCueOwner {
            pickedImage.append((owner.trackID, owner.cue))
            t0 = min(t0, owner.cue.start)
        }
        var pickedLight: [(String, LightCue)] = []
        if let p = selectedLightCuePath {
            let track = scene.lightTracks[p.track]
            let run = Self.lightRun(in: track.cues, containing: track.cues[p.cue].id)
            for cue in run {
                pickedLight.append((track.id, cue))
                t0 = min(t0, cue.start)
            }
        }
        var pickedBG: [BackgroundCue] = []
        if let id = selectedBackgroundCue,
           let cue = scene.backgroundTracks.first?.cues.first(where: { $0.id == id }) {
            pickedBG.append(cue)
            t0 = min(t0, cue.start)
        }
        guard t0 < .greatestFiniteMagnitude else { return }
        markClipboard = selectedMarks.map { ($0.character, $0.code, $0.start - t0, $0.end - t0) }
        clipClipboard = pickedClips.map { owner, clip in
            var c = clip; c.start -= t0; return (owner, c)
        }
        imageCueClipboard = pickedImage.map { tid, cue in var c = cue; c.start -= t0; return (tid, c) }
        lightCueClipboard = pickedLight.map { tid, cue in var c = cue; c.start -= t0; return (tid, c) }
        bgCueClipboard = pickedBG.map { var c = $0; c.start -= t0; return c }
    }

    /// ⌘V / right-click Paste: at `anchor` when given, right after the current
    /// selection when one exists, else at the playhead. Pasted items select,
    /// so repeated ⌘V chains.
    func pasteTimeline(at anchor: Double? = nil) {
        let hasContent = !markClipboard.isEmpty || !clipClipboard.isEmpty
            || !imageCueClipboard.isEmpty || !lightCueClipboard.isEmpty || !bgCueClipboard.isEmpty
        guard hasContent else { return }
        var base = anchor ?? time
        if anchor == nil {
            var selEnd = -Double.greatestFiniteMagnitude
            for m in selectedMarks { selEnd = max(selEnd, m.end) }
            for i in scene.characters.indices {
                for clip in scene.characters[i].clips where selectedClips.contains(clip.id) {
                    selEnd = max(selEnd, clip.start + clip.dur)
                }
            }
            for t in scene.audioTracks {
                for clip in t.clips where selectedClips.contains(clip.id) {
                    selEnd = max(selEnd, clip.start + clip.dur)
                }
            }
            if selEnd > 0 { base = selEnd + 0.05 }
        }
        registerUndoSnapshot(label: "Paste")
        var pastedMarks: Set<PerfMark> = []
        for m in markClipboard {
            guard scene.characters.indices.contains(m.character) else { continue }
            var events = scene.characters[m.character].events
            let s = ((base + m.start) * 1000).rounded() / 1000
            let e = ((base + m.end) * 1000).rounded() / 1000
            events.append(.key(t: s, code: m.code, down: true))
            events.append(.key(t: e, code: m.code, down: false))
            events.sort { $0.t < $1.t }
            scene.characters[m.character].events = events
            pastedMarks.insert(PerfMark(character: m.character, code: m.code, start: s, end: e))
        }
        var pastedClips: Set<String> = []
        for (owner, clip) in clipClipboard {
            var c = clip
            let oldID = c.id
            c.id = ShowDocumentFile.newID()
            c.start = clip.start + base
            if let media = file?.audio[oldID] { file?.audio[c.id] = media }
            if owner.hasPrefix("c"), let i = Int(owner.dropFirst()),
               scene.characters.indices.contains(i) {
                scene.characters[i].clips.append(c)
            } else if let ti = scene.audioTracks.firstIndex(where: { $0.id == owner }) {
                scene.audioTracks[ti].clips.append(c)
            } else { continue }
            pastedClips.insert(c.id)
        }
        for (tid, cue) in imageCueClipboard {
            var c = cue
            c.id = ShowDocumentFile.newID()
            c.start = cue.start + base
            if let ti = scene.imageTracks.firstIndex(where: { $0.id == tid }) {
                scene.imageTracks[ti].cues.append(c)
                scene.imageTracks[ti].cues.sort { $0.start < $1.start }
                selectedImageCue = c.id
            } else if let ti = scene.audioTracks.firstIndex(where: { $0.id == tid }) {
                scene.audioTracks[ti].cues.append(c)
                scene.audioTracks[ti].cues.sort { $0.start < $1.start }
                selectedImageCue = c.id
            }
        }
        for (tid, cue) in lightCueClipboard {
            var c = cue
            c.id = ShowDocumentFile.newID()
            c.start = cue.start + base
            if let ti = scene.lightTracks.firstIndex(where: { $0.id == tid }) {
                scene.lightTracks[ti].cues.append(c)
                scene.lightTracks[ti].cues.sort { $0.start < $1.start }
                selectedLightCue = c.id
            }
        }
        for cue in bgCueClipboard {
            var c = cue
            c.id = ShowDocumentFile.newID()
            c.start = cue.start + base
            if !scene.backgroundTracks.isEmpty {
                scene.backgroundTracks[0].cues.append(c)
                scene.backgroundTracks[0].cues.sort { $0.start < $1.start }
                selectedBackgroundCue = c.id
            }
        }
        if !pastedMarks.isEmpty { selectedMarks = pastedMarks }
        if !pastedClips.isEmpty { selectedClips = pastedClips }
    }

    /// Hidden toggles apply mid-play (the audio graph rebuilds from here).
    func resyncAudioIfPlaying() {
        if playing { file?.audioEngine?.syncPlayback(self) }
    }

    /// Delete the timeline selection (anchors handled by the view).
    func deleteTimelineSelection() {
        if !selectedMarks.isEmpty {
            registerUndoSnapshot(label: "Delete Marks")
            for charIndex in Set(selectedMarks.map(\.character)) {
                let charMarks = Set(selectedMarks.filter { $0.character == charIndex })
                scene.characters[charIndex].events =
                    TimelineMath.removeMarks(charMarks, from: scene.characters[charIndex].events)
            }
            selectedMarks = []
        }
        for id in selectedClips { removeClip(id: id) }
        selectedClips = []
        if let id = selectedImageCue {
            registerUndoSnapshot(label: "Delete Image Cue")
            for i in scene.imageTracks.indices {
                scene.imageTracks[i].cues.removeAll { $0.id == id }
            }
            for i in scene.audioTracks.indices {
                scene.audioTracks[i].cues.removeAll { $0.id == id }
            }
            selectedImageCue = nil
        }
        if let sel = selectedOutfitEvent {
            if scene.characters.indices.contains(sel.char),
               scene.characters[sel.char].events.indices.contains(sel.index),
               case .outfit = scene.characters[sel.char].events[sel.index] {
                registerUndoSnapshot(label: "Delete Outfit Change")
                scene.characters[sel.char].events.remove(at: sel.index)
            }
            selectedOutfitEvent = nil
        }
        if let id = selectedBackgroundCue {
            registerUndoSnapshot(label: "Delete Background Cue")
            for i in scene.backgroundTracks.indices {
                scene.backgroundTracks[i].cues.removeAll { $0.id == id }
            }
            selectedBackgroundCue = nil
        }
        if let id = selectedLightCue {
            registerUndoSnapshot(label: "Delete Light Cue")
            for i in scene.lightTracks.indices {
                scene.lightTracks[i].cues.removeAll { $0.id == id }
            }
            selectedLightCue = nil
        }
    }

    /// The selected image cue's track/cue indices, if any.
    var selectedImageCuePath: (track: Int, cue: Int)? {
        guard let id = selectedImageCue else { return nil }
        for (ti, track) in scene.imageTracks.enumerated() {
            if let ci = track.cues.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        return nil
    }

    /// The selected image cue wherever it lives (image track OR media track).
    var selectedImageCueValue: ImageCue? {
        guard let id = selectedImageCue else { return nil }
        for t in scene.imageTracks {
            if let c = t.cues.first(where: { $0.id == id }) { return c }
        }
        for t in scene.audioTracks {
            if let c = t.cues.first(where: { $0.id == id }) { return c }
        }
        return nil
    }

    var selectedImageCueOwner: (trackID: String, cue: ImageCue)? {
        guard let id = selectedImageCue else { return nil }
        for t in scene.imageTracks {
            if let c = t.cues.first(where: { $0.id == id }) { return (t.id, c) }
        }
        for t in scene.audioTracks {
            if let c = t.cues.first(where: { $0.id == id }) { return (t.id, c) }
        }
        return nil
    }

    func updateSelectedImageCue(_ body: (inout ImageCue) -> Void) {
        guard let id = selectedImageCue else { return }
        for ti in scene.imageTracks.indices {
            if let ci = scene.imageTracks[ti].cues.firstIndex(where: { $0.id == id }) {
                body(&scene.imageTracks[ti].cues[ci])
                return
            }
        }
        for ti in scene.audioTracks.indices {
            if let ci = scene.audioTracks[ti].cues.firstIndex(where: { $0.id == id }) {
                body(&scene.audioTracks[ti].cues[ci])
                return
            }
        }
    }

    /// Image cue on a MEDIA (audio) track.
    func addMediaImageCue(trackIndex: Int, assetID: String, at t: Double) {
        guard scene.audioTracks.indices.contains(trackIndex) else { return }
        registerUndoSnapshot(label: "Add Image Cue")
        let cue = ImageCue(id: ShowDocumentFile.newID(), assetID: assetID,
                           start: t, dur: 5, from: ImagePlacement())
        scene.audioTracks[trackIndex].cues.append(cue)
        scene.audioTracks[trackIndex].cues.sort { $0.start < $1.start }
        selectedImageCue = cue.id
    }

    init(document: ShowDocument) {
        var document = document
        // Older documents called the scene track "Background".
        for i in document.stage.backgroundTracks.indices
        where document.stage.backgroundTracks[i].name == "Background" {
            document.stage.backgroundTracks[i].name = "Scenes"
        }
        var doc = document
        // Exactly one Background track, always present: create it if missing,
        // fold any extras' cues into the first.
        if doc.stage.backgroundTracks.isEmpty {
            doc.stage.backgroundTracks = [BackgroundTrack(id: ShowDocumentFile.newID(),
                                                          name: "Scenes")]
        } else if doc.stage.backgroundTracks.count > 1 {
            var first = doc.stage.backgroundTracks[0]
            for extra in doc.stage.backgroundTracks.dropFirst() {
                first.cues.append(contentsOf: extra.cues)
            }
            first.cues.sort { $0.start < $1.start }
            doc.stage.backgroundTracks = [first]
        }
        if doc.stage.backgroundTracks[0].name == "Backgrounds" {
            // Pre-rename documents used the plural.
            doc.stage.backgroundTracks[0].name = "Scenes"
        }
        self.document = doc
        self.activeSceneIndex = 0
    }

    /// The single stage/timeline (v3).
    var scene: SceneState {
        get { document.stage }
        set { document.stage = newValue }
    }

    var simulator: SceneSimulator { SceneSimulator(state: scene) }

    /// Timeline duration: web tlDurNeeded — max content end + 3s, clamped 20..3600.
    var duration: Double {
        min(3600, max(20, (scene.contentEnd + 3).rounded(.up)))
    }

    // MARK: - Transport

    func tick(now: TimeInterval) {
        guard playing else { return }
        time = now - startWall
        if time >= duration {
            time = duration
            pause()
        }
    }

    func play() {
        guard !playing else { pause(); return }
        clearFreeform()
        playing = true
        startWall = Date.timeIntervalSinceReferenceDate - time
        file?.audioEngine?.syncPlayback(self)
    }

    func pause() {
        if recording { finishRecording() }
        playing = false
        releaseAllLiveKeys()
        file?.audioEngine?.syncPlayback(self)
    }

    func rewind() {
        pause()
        seek(to: 0)
    }

    func seek(to t: Double) {
        clearFreeform()
        time = max(0, min(duration, t))
        if playing {
            startWall = Date.timeIntervalSinceReferenceDate - time
            file?.audioEngine?.syncPlayback(self)
        }
    }

    // MARK: - Recording (web tlRec / recEvent / punch-in)

    // MARK: - Image path recording (drag an image cue around over time)

    private(set) var imageRecordCueID: String?
    private var imageRecordOwnerIsMedia = false
    private var imageRecordTrack = 0
    private var imageRecordAssetID = ""
    private var imageSamples: [(t: Double, x: Double, y: Double, scale: Double)] = []
    private var imagePen: (x: Double, y: Double, scale: Double) = (0.5, 0.5, 0.3)
    var isImageRecording: Bool { imageRecordCueID != nil }
    var imagePenNow: (x: Double, y: Double, scale: Double)? { isImageRecording ? imagePen : nil }
    var imageRecordAsset: String? { isImageRecording ? imageRecordAssetID : nil }

    func imageRecordSample(x: Double, y: Double) {
        guard isImageRecording else { return }
        imagePen.x = min(1.2, max(-0.2, x))
        imagePen.y = min(1.2, max(-0.2, y))
        if let last = imageSamples.last, time - last.t < 0.15 { return }
        imageSamples.append((time, imagePen.x, imagePen.y, imagePen.scale))
    }

    private func commitImageRecording() {
        defer {
            imageRecordCueID = nil
            imageSamples = []
        }
        guard imageSamples.count >= 2 else { return }
        registerUndoSnapshot(label: "Record Image Motion")
        let t0 = imageSamples[0].t
        let tEnd = imageSamples[imageSamples.count - 1].t
        var pts = imageSamples
        var i = 1
        while i < pts.count - 1 {
            let a = pts[i - 1], b = pts[i], c = pts[i + 1]
            let span = max(0.001, c.t - a.t)
            let f = (b.t - a.t) / span
            if abs(a.x + (c.x - a.x) * f - b.x) < 0.008,
               abs(a.y + (c.y - a.y) * f - b.y) < 0.008,
               abs(a.scale + (c.scale - a.scale) * f - b.scale) < 0.01 {
                pts.remove(at: i)
            } else {
                i += 1
            }
        }
        let assetID = imageRecordAssetID
        func rebuilt(_ cues: [ImageCue]) -> [ImageCue] {
            var out: [ImageCue] = []
            for var cue in cues {
                let end = cue.start + cue.dur
                if cue.assetID != assetID || end <= t0 + 0.01 || cue.start >= tEnd - 0.01 {
                    out.append(cue)
                } else if cue.start < t0, end > tEnd {
                    var tail = cue
                    tail.id = ShowDocumentFile.newID()
                    tail.from = cue.placement(at: tEnd)
                    tail.start = tEnd
                    tail.dur = end - tEnd
                    if cue.to != nil { cue.to = cue.placement(at: t0) }
                    cue.dur = t0 - cue.start
                    out.append(cue)
                    out.append(tail)
                } else if cue.start < t0 {
                    if cue.to != nil { cue.to = cue.placement(at: t0) }
                    cue.dur = t0 - cue.start
                    out.append(cue)
                } else if end > tEnd {
                    cue.from = cue.placement(at: tEnd)
                    cue.dur = end - tEnd
                    cue.start = tEnd
                    out.append(cue)
                }
            }
            for k in 0..<(pts.count - 1) {
                let a = pts[k], b = pts[k + 1]
                guard b.t - a.t > 0.02 else { continue }
                out.append(ImageCue(id: ShowDocumentFile.newID(), assetID: assetID,
                                    start: a.t, dur: b.t - a.t,
                                    from: ImagePlacement(x: a.x, y: a.y, scale: a.scale),
                                    to: ImagePlacement(x: b.x, y: b.y, scale: b.scale)))
            }
            return out.sorted { $0.start < $1.start }
        }
        if imageRecordOwnerIsMedia, scene.audioTracks.indices.contains(imageRecordTrack) {
            scene.audioTracks[imageRecordTrack].cues = rebuilt(scene.audioTracks[imageRecordTrack].cues)
        } else if scene.imageTracks.indices.contains(imageRecordTrack) {
            scene.imageTracks[imageRecordTrack].cues = rebuilt(scene.imageTracks[imageRecordTrack].cues)
        }
    }

    // MARK: - Light path recording ("draw" the light over time)

    private(set) var lightRecordTrack: Int?
    private var lightSamples: [(t: Double, x: Double, y: Double, intensity: Double, size: Double)] = []
    var isLightRecording: Bool { lightRecordTrack != nil }
    var lastLightSample: (t: Double, x: Double, y: Double, intensity: Double, size: Double)? { lightSamples.last }
    var lightPenNow: (x: Double, y: Double, intensity: Double, size: Double)? { isLightRecording ? lightPen : nil }

    /// Keyboard light control: arrows move, +/- change intensity.
    enum LightKey: Hashable { case up, down, left, right, plus, minus, sizeDown, sizeUp }
    private(set) var heldLightKeys: Set<LightKey> = []
    /// The "pen": position/intensity the keys steer (recording or nudging).
    private var lightPen: (x: Double, y: Double, intensity: Double, size: Double) = (0.8, 0.18, 1, 120)

    func lightKey(_ key: LightKey, down: Bool) {
        if down { heldLightKeys.insert(key) } else { heldLightKeys.remove(key) }
    }

    /// 60Hz driver (stage render loop): recording draws with the pen; paused
    /// with a light track selected nudges the current cue directly.
    func lightTick(dt: Double) {
        guard !heldLightKeys.isEmpty else { return }
        let dx = (heldLightKeys.contains(.right) ? 1.0 : 0) - (heldLightKeys.contains(.left) ? 1.0 : 0)
        let dy = (heldLightKeys.contains(.down) ? 1.0 : 0) - (heldLightKeys.contains(.up) ? 1.0 : 0)
        let di = (heldLightKeys.contains(.plus) ? 1.0 : 0) - (heldLightKeys.contains(.minus) ? 1.0 : 0)
        let ds = (heldLightKeys.contains(.sizeUp) ? 1.0 : 0) - (heldLightKeys.contains(.sizeDown) ? 1.0 : 0)
        if isImageRecording {
            imagePen.x = min(1.2, max(-0.2, imagePen.x + dx * 0.4 * dt))
            imagePen.y = min(1.2, max(-0.2, imagePen.y + dy * 0.4 * dt))
            imagePen.scale = min(1.2, max(0.05, imagePen.scale + ds * 0.35 * dt))
            imageRecordSample(x: imagePen.x, y: imagePen.y)
            return
        }
        if isLightRecording {
            lightPen.x = min(1.1, max(-0.1, lightPen.x + dx * 0.4 * dt))
            lightPen.y = min(1.1, max(-0.1, lightPen.y + dy * 0.4 * dt))
            lightPen.intensity = min(1, max(0, lightPen.intensity + di * 0.8 * dt))
            lightPen.size = min(300, max(40, lightPen.size + ds * 160 * dt))
            lightRecordSample(x: lightPen.x, y: lightPen.y)
            return
        }
        // Paused nudge of the selected/active cue on the selected light track.
        guard !playing, let key = selectedTrackKey,
              let li = scene.lightTracks.firstIndex(where: { $0.id == key }),
              !scene.lightTracks[li].cues.isEmpty else { return }
        let ci = scene.lightTracks[li].cues.firstIndex { selectedLightCue == $0.id }
            ?? scene.lightTracks[li].cues.firstIndex { time >= $0.start && time < $0.start + $0.dur }
            ?? 0
        var cue = scene.lightTracks[li].cues[ci]
        func nudge(_ s: inout LightState) {
            s.x = min(1.1, max(-0.1, s.x + dx * 0.4 * dt))
            s.y = min(1.1, max(-0.1, s.y + dy * 0.4 * dt))
            s.intensity = min(1, max(0, s.intensity + di * 0.8 * dt))
            s.size = min(300, max(40, s.size + ds * 160 * dt))
        }
        nudge(&cue.from)
        if cue.to != nil { nudge(&cue.to!) }
        scene.lightTracks[li].cues[ci] = cue
    }

    /// Stage drags while light-recording feed the path.
    func lightRecordSample(x: Double, y: Double) {
        guard isLightRecording else { return }
        lightPen.x = min(1.1, max(-0.1, x))
        lightPen.y = min(1.1, max(-0.1, y))
        if let last = lightSamples.last, time - last.t < 0.15 { return } // ~7Hz
        lightSamples.append((time, lightPen.x, lightPen.y, lightPen.intensity, lightPen.size))
    }

    /// Turns the drawn samples into a chain of linear cues, punching in over
    /// whatever the track had in that range.
    private func commitLightRecording() {
        defer {
            lightRecordTrack = nil
            lightSamples = []
        }
        guard let li = lightRecordTrack, scene.lightTracks.indices.contains(li),
              lightSamples.count >= 2 else { return }
        registerUndoSnapshot(label: "Record Light Path")
        let t0 = lightSamples[0].t
        let tEnd = lightSamples[lightSamples.count - 1].t
        // Simplify: drop samples that barely deviate from the line between
        // their neighbours (keeps the cue count sane).
        var pts = lightSamples
        var i = 1
        while i < pts.count - 1 {
            let a = pts[i - 1], b = pts[i], c = pts[i + 1]
            let span = max(0.001, c.t - a.t)
            let f = (b.t - a.t) / span
            let lx = a.x + (c.x - a.x) * f
            let ly = a.y + (c.y - a.y) * f
            let lint = a.intensity + (c.intensity - a.intensity) * f
            let lsize = a.size + (c.size - a.size) * f
            if abs(lx - b.x) < 0.008, abs(ly - b.y) < 0.008, abs(lint - b.intensity) < 0.02,
               abs(lsize - b.size) < 4 {
                pts.remove(at: i)
            } else {
                i += 1
            }
        }
        // Punch in: trim/remove existing cues overlapping the drawn range.
        var cues = scene.lightTracks[li].cues
        var repaired: [LightCue] = []
        for var cue in cues {
            let end = cue.start + cue.dur
            if end <= t0 + 0.01 || cue.start >= tEnd - 0.01 {
                repaired.append(cue)
            } else if cue.start < t0, end > tEnd {
                var tail = cue
                tail.id = ShowDocumentFile.newID()
                tail.from = cue.state(at: tEnd)
                tail.start = tEnd
                tail.dur = end - tEnd
                if cue.to != nil { cue.to = cue.state(at: t0) }
                cue.dur = t0 - cue.start
                repaired.append(cue)
                repaired.append(tail)
            } else if cue.start < t0 {
                if cue.to != nil { cue.to = cue.state(at: t0) }
                cue.dur = t0 - cue.start
                repaired.append(cue)
            } else if end > tEnd {
                cue.from = cue.state(at: tEnd)
                cue.dur = end - tEnd
                cue.start = tEnd
                repaired.append(cue)
            } // fully inside the range → dropped
        }
        cues = repaired
        for k in 0..<(pts.count - 1) {
            let a = pts[k], b = pts[k + 1]
            guard b.t - a.t > 0.02 else { continue }
            cues.append(LightCue(id: ShowDocumentFile.newID(),
                                 start: a.t, dur: b.t - a.t,
                                 from: LightState(x: a.x, y: a.y, intensity: a.intensity, size: a.size),
                                 to: LightState(x: b.x, y: b.y, intensity: b.intensity, size: b.size)))
        }
        cues.sort { $0.start < $1.start }
        scene.lightTracks[li].cues = cues
    }

    func record() {
        if recording || playing { pause(); return }
        // A selected image cue records its motion: drag it around as time rolls.
        if let id = selectedImageCue, let owner = selectedImageCueOwner,
           selectedTrackKey != nil,
           scene.audioTracks.contains(where: { $0.id == selectedTrackKey })
            || scene.imageTracks.contains(where: { $0.id == selectedTrackKey }) {
            clearFreeform()
            imageRecordCueID = id
            imageRecordAssetID = owner.cue.assetID
            if let ti = scene.audioTracks.firstIndex(where: { $0.id == owner.trackID }) {
                imageRecordOwnerIsMedia = true
                imageRecordTrack = ti
            } else if let ti = scene.imageTracks.firstIndex(where: { $0.id == owner.trackID }) {
                imageRecordOwnerIsMedia = false
                imageRecordTrack = ti
            }
            imageSamples = []
            let p = owner.cue.placement(at: time)
            imagePen = (p.x, p.y, p.scale)
            recording = true
            playing = true
            startWall = Date.timeIntervalSinceReferenceDate - time
            file?.audioEngine?.syncPlayback(self)
            return
        }
        // A selected light track records by DRAWING on the stage.
        if let key = selectedTrackKey,
           let li = scene.lightTracks.firstIndex(where: { $0.id == key }) {
            clearFreeform()
            lightRecordTrack = li
            lightSamples = []
            let state = scene.lightTracks[li].cues
                .first { time >= $0.start && time < $0.start + $0.dur }?.state(at: time)
                ?? scene.lightTracks[li].cues.first?.from
                ?? LightState()
            lightPen = (state.x, state.y, state.intensity, state.size)
            recording = true
            playing = true
            startWall = Date.timeIntervalSinceReferenceDate - time
            file?.audioEngine?.syncPlayback(self)
            return
        }
        guard !selection.isEmpty else { return }
        // Freeform placement at the start becomes the take's start pose.
        for i in selection where startPoseMismatch(characterIndex: i) {
            if let pose = displayedPose(characterIndex: i) {
                var c = scene.characters[i]
                c.x = pose.x
                c.depth = pose.depth
                c.face = pose.face
                c.recStart = StartPose(x: pose.x, depth: pose.depth, face: pose.face)
                scene.characters[i] = c
            }
        }
        clearFreeform()
        recTargets = selection
        recStartTime = time
        recPunched = [:]
        for i in recTargets {
            var c = scene.characters[i]
            if c.recStart == nil {
                c.recStart = StartPose(x: c.x, depth: c.depth, face: c.face)
                scene.characters[i] = c
            }
        }
        recording = true
        playing = true
        startWall = Date.timeIntervalSinceReferenceDate - time
        file?.audioEngine?.syncPlayback(self)
    }

    private func finishRecording() {
        if isImageRecording {
            commitImageRecording()
            recording = false
            return
        }
        if isLightRecording {
            commitLightRecording()
            recording = false
            return
        }
        // Close any still-held keys so no segment dangles open.
        for code in heldCodes { recordEvent(code: code, down: false) }
        recording = false
        recTargets = []
        recPunched = [:]
        registerUndoSnapshot(label: "Record")
    }

    /// Web recEvent: only armed groups; first press of a group replaces that group
    /// from the record point onward (earlier work kept), closing holds that cross it.
    func recordEvent(code: EventCode, down: Bool) {
        guard recording else { return }
        let group = code.group
        let stamp = (time * 1000).rounded() / 1000
        for i in recTargets {
            var c = scene.characters[i]
            guard c.armedGroups.contains(group) else { continue }
            if recPunched[i]?.contains(group) != true {
                recPunched[i, default: []].insert(group)
                // Which codes of this group are held open across the record point?
                var open = Set<EventCode>()
                for ev in c.events {
                    guard case .key(let t, let evCode, let evDown) = ev,
                          evCode.group == group, t < recStartTime else { continue }
                    if evDown { open.insert(evCode) } else { open.remove(evCode) }
                }
                c.events.removeAll {
                    guard case .key(let t, let evCode, _) = $0 else { return false }
                    return evCode.group == group && t >= recStartTime
                }
                let closeStamp = (recStartTime * 1000).rounded() / 1000
                for openCode in open {
                    c.events.append(.key(t: closeStamp, code: openCode, down: false))
                }
                c.events.sort { $0.t < $1.t }
            }
            let ev = PerfEvent.key(t: stamp, code: code, down: down)
            let insertAt = c.events.firstIndex { $0.t > stamp } ?? c.events.count
            c.events.insert(ev, at: insertAt)
            scene.characters[i] = c
        }
    }

    /// Delete/Backspace pressed anywhere outside a text field. The timeline
    /// observes this counter — .onDeleteCommand needs view focus the canvas
    /// timeline never has, so the key routes through the event monitor instead.
    private(set) var timelineDeleteRequest = 0

    func requestTimelineDelete() {
        timelineDeleteRequest += 1
    }

    // MARK: - Live keys

    /// A puppeteering key went down/up. Recording → capture; paused at start →
    /// reposition the start pose (web's "parked at the start" freeform behavior).
    func liveKey(code: EventCode, down: Bool) {
        if down { heldCodes.insert(code) } else { heldCodes.remove(code) }
        if recording {
            recordEvent(code: code, down: down)
        } else if !playing {
            freeformKey(code: code, down: down)
        }
    }

    private func releaseAllLiveKeys() {
        heldCodes = []
    }

    // MARK: - Freeform puppeteering (transport stopped)

    /// Synthetic live events, per character: freeform keys run through the SAME
    /// simulator as recorded ones, so walking/talking/jumping previews exactly
    /// like playback. Cleared whenever the transport moves.
    private(set) var freeformEvents: [Int: [PerfEvent]] = [:]
    private var freeformStarts: [Int: StartPose] = [:]
    private(set) var freeformClock: Double = 0
    private var freeformLastEvent: Double = 0

    var freeformActive: Bool { !freeformEvents.isEmpty }
    /// Motion can still be decaying (turn grace, jump arc) after the keys lift.
    var freeformSettling: Bool { freeformActive && freeformClock < freeformLastEvent + 1.5 }

    func clearFreeform() {
        freeformEvents = [:]
        freeformStarts = [:]
        freeformClock = 0
        freeformLastEvent = 0
    }

    private func freeformKey(code: EventCode, down: Bool) {
        for i in selection where scene.characters.indices.contains(i) {
            if freeformStarts[i] == nil {
                let pose = simulator.pose(characterIndex: i, at: time)
                freeformStarts[i] = StartPose(x: pose.x, depth: pose.depth, face: pose.face)
            }
            freeformEvents[i, default: []].append(.key(t: freeformClock, code: code, down: down))
        }
        freeformLastEvent = freeformClock
    }

    /// Advances the freeform clock at 60 Hz (driven by the stage render loop).
    /// Freeform is a PREVIEW: the "Set start position" button (or hitting REC)
    /// commits where the character stands as its start pose.
    func freeformNudge(dt: Double) {
        guard !playing, !recording, freeformActive,
              !heldCodes.isEmpty || freeformSettling else { return }
        freeformClock += dt
    }

    /// Freeform preview pose: synthetic live events simulated on top of the pose
    /// at the playhead. Wardrobe and captions stay from the timeline.
    func freeformPose(characterIndex i: Int, basePose: CharacterPose) -> CharacterPose? {
        guard let evs = freeformEvents[i], let start = freeformStarts[i],
              scene.characters.indices.contains(i) else { return nil }
        var s = scene
        var c = s.characters[i]
        c.events = evs
        c.recStart = start
        c.subs = []
        s.characters[i] = c
        var pose = SceneSimulator(state: s).pose(characterIndex: i, at: freeformClock)
        pose.outfit = basePose.outfit
        pose.activeSubtitle = basePose.activeSubtitle
        return pose
    }

    /// The pose currently on the stage (freeform preview wins over the timeline).
    func displayedPose(characterIndex i: Int) -> CharacterPose? {
        guard scene.characters.indices.contains(i) else { return nil }
        let base = simulator.pose(characterIndex: i, at: time)
        return freeformPose(characterIndex: i, basePose: base) ?? base
    }

    /// True when the playhead is at the start but the character on stage isn't
    /// where the saved start position says (freeform moved it, uncommitted).
    func startPoseMismatch(characterIndex i: Int) -> Bool {
        guard freeformActive, time < 0.1, scene.characters.indices.contains(i),
              let pose = displayedPose(characterIndex: i) else { return false }
        let c = scene.characters[i]
        let start = c.recStart ?? StartPose(x: c.x, depth: c.depth, face: c.face)
        return abs(pose.x - start.x) > 0.005 || abs(pose.depth - start.depth) > 0.02
            || pose.face != start.face
    }

    /// Saves what's on stage as the character's start position.
    func commitStartPose(characterIndex i: Int) {
        guard scene.characters.indices.contains(i),
              let pose = displayedPose(characterIndex: i) else { return }
        registerUndoSnapshot(label: "Set Start Position")
        var c = scene.characters[i]
        c.x = pose.x
        c.depth = pose.depth
        c.face = pose.face
        c.recStart = StartPose(x: pose.x, depth: pose.depth, face: pose.face)
        scene.characters[i] = c
        clearFreeform()
    }

    // MARK: - Characters

    // UI-facing 1–10 motion scale; documents keep the web simulation units
    // (speed 40–600, wobble 0–16) so playback math and old shows are untouched.
    static func uiSpeed(_ speed: Double) -> Double { 1 + (speed - 40) / 560 * 9 }
    static func speed(fromUI ui: Double) -> Double { 40 + (ui - 1) / 9 * 560 }
    static func uiWobble(_ wobble: Double) -> Double { 1 + wobble / 16 * 9 }
    static func wobble(fromUI ui: Double) -> Double { (ui - 1) / 9 * 16 }

    func addCharacter(body: Body) {
        guard scene.characters.count < 10 else { return }
        registerUndoSnapshot(label: "Add Character")
        scene.characters.append(Character(body: body, x: 0.35 + 0.06 * Double(scene.characters.count)))
        selection = [scene.characters.count - 1]
    }

    /// Right-click duplicate: copies the track, its clips/cues, and media refs.
    func duplicateTrack(_ kind: TrackRowKind) {
        registerUndoSnapshot(label: "Duplicate Track")
        func cloneClips(_ clips: [AudioClip]) -> [AudioClip] {
            clips.map { clip in
                var c = clip
                c.id = ShowDocumentFile.newID()
                if let media = file?.audio[clip.id] { file?.audio[c.id] = media }
                return c
            }
        }
        switch kind {
        case .character(let i):
            guard scene.characters.count < 10, var c = scene.characters[safe: i] else { return }
            c.name = (c.name.isEmpty ? "banny" : c.name) + " copy"
            c.clips = cloneClips(c.clips)
            scene.characters.append(c)
        case .audio(let i):
            guard var t = scene.audioTracks[safe: i] else { return }
            t.id = ShowDocumentFile.newID()
            t.name += " copy"
            t.clips = cloneClips(t.clips)
            scene.audioTracks.append(t)
        case .image(let i):
            guard var t = scene.imageTracks[safe: i] else { return }
            t.id = ShowDocumentFile.newID()
            t.name += " copy"
            for ci in t.cues.indices { t.cues[ci].id = ShowDocumentFile.newID() }
            scene.imageTracks.append(t)
        case .light(let i):
            guard var t = scene.lightTracks[safe: i] else { return }
            t.id = ShowDocumentFile.newID()
            t.name += " copy"
            for ci in t.cues.indices { t.cues[ci].id = ShowDocumentFile.newID() }
            scene.lightTracks.append(t)
        case .background:
            return // exactly one background track
        }
    }

    func removeCharacter(at index: Int) {
        guard scene.characters.indices.contains(index) else { return }
        registerUndoSnapshot(label: "Remove Character")
        scene.characters.remove(at: index)
        // Character row keys are index-based; keep the display order aligned.
        scene.rowOrder = scene.rowOrder.compactMap { key in
            guard key.hasPrefix("c-"), let j = Int(key.dropFirst(2)) else { return key }
            if j == index { return nil }
            return j > index ? "c-\(j - 1)" : key
        }
        selection = scene.characters.isEmpty ? [] : [min(index, scene.characters.count - 1)]
    }

    /// Edits the base (t=0) outfit regardless of where the playhead is.
    func setBaseOutfit(characterIndex: Int, slot: Int, name: String?) {
        guard scene.characters.indices.contains(characterIndex) else { return }
        registerUndoSnapshot(label: "Outfit")
        var c = scene.characters[characterIndex]
        if let name { c.baseOutfit[slot] = name } else { c.baseOutfit.removeValue(forKey: slot) }
        scene.characters[characterIndex] = c
    }

    /// Timed wardrobe change at an explicit time (the lane's wardrobe strip).
    func setOutfitEvent(characterIndex: Int, slot: Int, name: String?, at t: Double) {
        guard scene.characters.indices.contains(characterIndex) else { return }
        registerUndoSnapshot(label: "Outfit Change")
        var c = scene.characters[characterIndex]
        let ev = PerfEvent.outfit(t: t, slot: slot, name: name)
        let insertAt = c.events.firstIndex { $0.t > t } ?? c.events.count
        c.events.insert(ev, at: insertAt)
        scene.characters[characterIndex] = c
    }

    func setOutfit(characterIndex: Int, slot: Int, name: String?) {
        guard scene.characters.indices.contains(characterIndex) else { return }
        registerUndoSnapshot(label: "Outfit")
        var c = scene.characters[characterIndex]
        if time < 0.05 {
            // At the start → change the base outfit.
            if let name { c.baseOutfit[slot] = name } else { c.baseOutfit.removeValue(forKey: slot) }
        } else {
            // Mid-timeline → a timed wardrobe change (web outfit event).
            let ev = PerfEvent.outfit(t: time, slot: slot, name: name)
            let insertAt = c.events.firstIndex { $0.t > time } ?? c.events.count
            c.events.insert(ev, at: insertAt)
        }
        scene.characters[characterIndex] = c
    }

    // MARK: - Tracks

    /// A track with no content yet — fill it by dragging an image file onto it.
    func addEmptyImageTrack() {
        registerUndoSnapshot(label: "Add Image Track")
        let track = ImageTrack(id: ShowDocumentFile.newID(), name: "Image", cues: [])
        scene.imageTracks.append(track)
        selectedTrackKey = track.id
    }

    func addImageCue(trackIndex: Int, assetID: String, at t: Double) {
        guard scene.imageTracks.indices.contains(trackIndex) else { return }
        registerUndoSnapshot(label: "Add Image Cue")
        let cue = ImageCue(id: ShowDocumentFile.newID(), assetID: assetID,
                           start: t, dur: 5, from: ImagePlacement())
        scene.imageTracks[trackIndex].cues.append(cue)
        scene.imageTracks[trackIndex].cues.sort { $0.start < $1.start }
        selectedImageCue = cue.id
    }

    func addImageTrack(assetID: String, assetName: String) {
        registerUndoSnapshot(label: "Add Image Track")
        let cue = ImageCue(id: ShowDocumentFile.newID(), assetID: assetID,
                           start: time, dur: 5, from: ImagePlacement())
        scene.imageTracks.append(ImageTrack(id: ShowDocumentFile.newID(),
                                            name: assetName, cues: [cue]))
        selectedImageCue = cue.id
    }

    /// The contiguous chain (recorded take) containing a cue.
    static func lightRun(in cues: [LightCue], containing id: String) -> [LightCue] {
        let sorted = cues.sorted { $0.start < $1.start }
        guard let idx = sorted.firstIndex(where: { $0.id == id }) else { return [] }
        var lo = idx
        var hi = idx
        while lo > 0, abs(sorted[lo - 1].start + sorted[lo - 1].dur - sorted[lo].start) < 0.02 { lo -= 1 }
        while hi < sorted.count - 1,
              abs(sorted[hi].start + sorted[hi].dur - sorted[hi + 1].start) < 0.02 { hi += 1 }
        return Array(sorted[lo...hi])
    }

    func setLightCueStart(track: Int, id: String, start: Double) {
        guard scene.lightTracks.indices.contains(track),
              let ci = scene.lightTracks[track].cues.firstIndex(where: { $0.id == id }) else { return }
        scene.lightTracks[track].cues[ci].start = start
    }

    /// ⌘-drag on a chain: clone the whole run in place; returns the copies' ids.
    func duplicateLightRun(track: Int, containing id: String) -> [String]? {
        guard scene.lightTracks.indices.contains(track) else { return nil }
        let run = Self.lightRun(in: scene.lightTracks[track].cues, containing: id)
        guard !run.isEmpty else { return nil }
        registerUndoSnapshot(label: "Duplicate Light Take")
        var ids: [String] = []
        for cue in run {
            var copy = cue
            copy.id = ShowDocumentFile.newID()
            ids.append(copy.id)
            scene.lightTracks[track].cues.append(copy)
        }
        scene.lightTracks[track].cues.sort { $0.start < $1.start }
        return ids
    }

    /// ⌘-click on a light cue: split at t; animated cues keep their ramp by
    /// meeting at the interpolated state.
    func splitLightCue(id: String, at t: Double) {
        for ti in scene.lightTracks.indices {
            guard let ci = scene.lightTracks[ti].cues.firstIndex(where: { $0.id == id }) else { continue }
            var first = scene.lightTracks[ti].cues[ci]
            guard t > first.start + 0.1, t < first.start + first.dur - 0.1 else { return }
            registerUndoSnapshot(label: "Split Light")
            let mid = first.state(at: t)
            var second = first
            second.id = ShowDocumentFile.newID()
            second.start = t
            second.dur = first.start + first.dur - t
            first.dur = t - first.start
            if first.to != nil {
                first.to = mid
                second.from = mid
            }
            scene.lightTracks[ti].cues[ci] = first
            scene.lightTracks[ti].cues.insert(second, at: ci + 1)
            selectedLightCue = second.id
            return
        }
    }

    /// ⌘-click on an image cue: split at t, meeting at the interpolated placement.
    func splitImageCue(id: String, at t: Double) {
        func split(_ cues: inout [ImageCue]) -> Bool {
            guard let ci = cues.firstIndex(where: { $0.id == id }) else { return false }
            var first = cues[ci]
            guard t > first.start + 0.1, t < first.start + first.dur - 0.1 else { return true }
            registerUndoSnapshot(label: "Split Image")
            let mid = first.placement(at: t)
            var second = first
            second.id = ShowDocumentFile.newID()
            second.start = t
            second.dur = first.start + first.dur - t
            first.dur = t - first.start
            if first.to != nil {
                first.to = mid
                second.from = mid
            }
            cues[ci] = first
            cues.insert(second, at: ci + 1)
            selectedImageCue = second.id
            return true
        }
        for ti in scene.imageTracks.indices where split(&scene.imageTracks[ti].cues) { return }
        for ti in scene.audioTracks.indices where split(&scene.audioTracks[ti].cues) { return }
    }

    /// ⌘-click on a background cue: split it at t (select the second half).
    func splitBackgroundCue(id: String, at t: Double) {
        for ti in scene.backgroundTracks.indices {
            guard let ci = scene.backgroundTracks[ti].cues.firstIndex(where: { $0.id == id }) else { continue }
            var first = scene.backgroundTracks[ti].cues[ci]
            guard t > first.start + 0.1, t < first.start + first.dur - 0.1 else { return }
            registerUndoSnapshot(label: "Split Background")
            var second = first
            second.id = ShowDocumentFile.newID()
            second.start = t
            second.dur = first.start + first.dur - t
            first.dur = t - first.start
            scene.backgroundTracks[ti].cues[ci] = first
            scene.backgroundTracks[ti].cues.insert(second, at: ci + 1)
            selectedBackgroundCue = second.id
            return
        }
    }

    func addBackgroundCue(assetID: String, assetName: String, at startTime: Double? = nil) {
        let time = startTime ?? self.time
        registerUndoSnapshot(label: "Set Background")
        if scene.backgroundTracks.isEmpty {
            scene.backgroundTracks = [BackgroundTrack(id: ShowDocumentFile.newID(), name: "Scenes")]
        }
        // New cue runs from the playhead to the end of content (or +30s).
        let end = max(scene.contentEnd, time + 30)
        // Trim any cue that overlaps the new start.
        var cues = scene.backgroundTracks[0].cues
        for i in cues.indices where cues[i].start < time && cues[i].start + cues[i].dur > time {
            cues[i].dur = time - cues[i].start
        }
        cues.removeAll { $0.start >= time }
        cues.append(BackgroundCue(id: ShowDocumentFile.newID(), assetID: assetID,
                                  start: time, dur: end - time))
        scene.backgroundTracks[0].cues = cues.sorted { $0.start < $1.start }
    }

    func removeTrack(_ row: TrackRowKind) {
        registerUndoSnapshot(label: "Delete Track")
        switch row {
        case .character(let i):
            guard scene.characters.indices.contains(i) else { return }
            scene.characters.remove(at: i)
            selection = scene.characters.isEmpty ? [] : [min(i, scene.characters.count - 1)]
            selectedMarks = []
        case .audio(let i):
            guard scene.audioTracks.indices.contains(i) else { return }
            scene.audioTracks.remove(at: i)
        case .image(let i):
            guard scene.imageTracks.indices.contains(i) else { return }
            scene.imageTracks.remove(at: i)
        case .light(let i):
            guard scene.lightTracks.indices.contains(i) else { return }
            scene.lightTracks.remove(at: i)
        case .background:
            break // the background track is permanent
        }
    }

    func addAudioTrack() {
        registerUndoSnapshot(label: "Add Audio Track")
        scene.audioTracks.append(AudioTrack(id: ShowDocumentFile.newID(),
                                            name: "Media \(scene.audioTracks.count + 1)"))
    }

    /// New cue on an existing light track, seeded from where the light was
    /// last (previous cue's end state; else the next cue's start; else default).
    func addLightCue(trackIndex: Int, at t: Double) {
        guard scene.lightTracks.indices.contains(trackIndex) else { return }
        registerUndoSnapshot(label: "Add Light Cue")
        let cues = scene.lightTracks[trackIndex].cues
        let prev = cues.filter { $0.start + $0.dur <= t + 0.01 }
            .max { ($0.start + $0.dur) < ($1.start + $1.dur) }
        let next = cues.filter { $0.start > t }.min { $0.start < $1.start }
        let state = prev.map { $0.state(at: $0.start + $0.dur) }
            ?? next.map { $0.state(at: $0.start) }
            ?? LightState()
        let dur = max(0.5, (next?.start ?? t + 10) - t)
        let cue = LightCue(id: ShowDocumentFile.newID(), start: t, dur: dur, from: state)
        scene.lightTracks[trackIndex].cues.append(cue)
        scene.lightTracks[trackIndex].cues.sort { $0.start < $1.start }
        selectedLightCue = cue.id
        selectedTrackKey = scene.lightTracks[trackIndex].id
    }

    func addLightTrack() {
        registerUndoSnapshot(label: "Add Light")
        let cue = LightCue(id: ShowDocumentFile.newID(), start: time,
                           dur: max(10, scene.contentEnd - time),
                           from: LightState())
        scene.lightTracks.append(LightTrack(id: ShowDocumentFile.newID(),
                                            name: "Light \(scene.lightTracks.count + 1)",
                                            cues: [cue]))
        selectedLightCue = cue.id
    }

    /// The selected light cue's track/cue indices, if any.
    var selectedLightCuePath: (track: Int, cue: Int)? {
        guard let id = selectedLightCue else { return nil }
        for (ti, track) in scene.lightTracks.enumerated() {
            if let ci = track.cues.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        return nil
    }

    // MARK: - Export range (the Export row's start/end markers)

    var exportRange: (from: Double, to: Double)? {
        get {
            guard let seg = document.show.first, seg.to > seg.from else { return nil }
            return (seg.from, seg.to)
        }
        set {
            if let r = newValue {
                document.show = [ShowSegment(name: "export", from: r.from, to: r.to)]
            } else {
                document.show = []
            }
        }
    }

    // MARK: - Undo

    /// Stage snapshot undo (the whole timeline state).
    func registerUndoSnapshot(label: String) {
        let snapshot = document.stage
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let redo = model.document.stage
                model.document.stage = snapshot
                model.backgroundRevision += 1
                model.undoManager?.registerUndo(withTarget: model) { m in
                    MainActor.assumeIsolated {
                        m.document.stage = redo
                        m.backgroundRevision += 1
                    }
                }
            }
        }
        undoManager?.setActionName(label)
    }
}

/// The model only needs a sync hook; LiveAudioEngine implements it.
protocol StudioAudioEngine {
    @MainActor func syncPlayback(_ model: StudioModel)
}


/// Track reference for model-level operations (mirrors the timeline's TrackRow).
enum TrackRowKind {
    case character(Int), audio(Int), image(Int), light(Int), background(Int)
}
