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
            scene.lightTracks.removeAll { $0.cues.isEmpty }
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

    init(document: ShowDocument) {
        var doc = document
        // Exactly one Background track, always present: create it if missing,
        // fold any extras' cues into the first.
        if doc.stage.backgroundTracks.isEmpty {
            doc.stage.backgroundTracks = [BackgroundTrack(id: ShowDocumentFile.newID(),
                                                          name: "Background")]
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
            doc.stage.backgroundTracks[0].name = "Background"
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

    func record() {
        if recording || playing { pause(); return }
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
        for ti in scene.imageTracks.indices {
            guard let ci = scene.imageTracks[ti].cues.firstIndex(where: { $0.id == id }) else { continue }
            var first = scene.imageTracks[ti].cues[ci]
            guard t > first.start + 0.1, t < first.start + first.dur - 0.1 else { return }
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
            scene.imageTracks[ti].cues[ci] = first
            scene.imageTracks[ti].cues.insert(second, at: ci + 1)
            selectedImageCue = second.id
            return
        }
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
            scene.backgroundTracks = [BackgroundTrack(id: ShowDocumentFile.newID(), name: "Background")]
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
                                            name: "Audio \(scene.audioTracks.count + 1)"))
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
