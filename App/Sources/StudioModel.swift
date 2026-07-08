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
    var undoManager: UndoManager?

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
    var selectedLightCue: String?
    private var markClipboard: [(character: Int, code: EventCode, start: Double, end: Double)] = []

    /// ⌘C: copy selected marks (times kept relative to the earliest mark).
    func copySelectedMarks() {
        guard !selectedMarks.isEmpty else { return }
        let t0 = selectedMarks.map(\.start).min() ?? 0
        markClipboard = selectedMarks.map { ($0.character, $0.code, $0.start - t0, $0.end - t0) }
    }

    /// ⌘V: paste the copied marks at the playhead onto their original characters.
    func pasteMarks() {
        guard !markClipboard.isEmpty else { return }
        registerUndoSnapshot(label: "Paste Marks")
        for m in markClipboard {
            guard scene.characters.indices.contains(m.character) else { continue }
            var events = scene.characters[m.character].events
            events.append(.key(t: ((time + m.start) * 1000).rounded() / 1000, code: m.code, down: true))
            events.append(.key(t: ((time + m.end) * 1000).rounded() / 1000, code: m.code, down: false))
            events.sort { $0.t < $1.t }
            scene.characters[m.character].events = events
        }
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
            // Empty image tracks disappear.
            scene.imageTracks.removeAll { $0.cues.isEmpty }
            selectedImageCue = nil
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

    // Freeform: while paused, arrows walk the selected characters' start pose in
    // real time (a 60 Hz nudge loop lives in EditorView); face flips immediately.
    private func freeformKey(code: EventCode, down: Bool) {
        guard down else { return }
        for i in selection {
            var c = scene.characters[i]
            switch code {
            case .arrowLeft where c.face != -1: c.face = -1
            case .arrowRight where c.face != 1: c.face = 1
            default: break
            }
            scene.characters[i] = c
        }
    }

    /// 60 Hz freeform integration while paused with arrows held (web step() freeform).
    func freeformNudge(dt: Double) {
        guard !playing, !recording, !heldCodes.isEmpty else { return }
        let dx = (heldCodes.contains(.arrowRight) ? 1.0 : 0) - (heldCodes.contains(.arrowLeft) ? 1.0 : 0)
        let dz = (heldCodes.contains(.arrowUp) ? 1.0 : 0) - (heldCodes.contains(.arrowDown) ? 1.0 : 0)
        guard dx != 0 || dz != 0 else { return }
        for i in selection {
            var c = scene.characters[i]
            guard (dx > 0 && c.face == 1) || (dx < 0 && c.face == -1) || dx == 0 else { continue }
            let depthRate = (c.speed / 320) * 0.36 / max(scene.gScale, 0.1)
            c.x = min(1 - 0.044, max(0.044, c.x + c.speed / 900 * dx * dt))
            c.depth = min(1, max(-12, c.depth + dz * dt * depthRate))
            if time < 0.1 {
                c.recStart = StartPose(x: c.x, depth: c.depth, face: c.face)
            }
            scene.characters[i] = c
        }
    }

    // MARK: - Characters

    func addCharacter(body: Body) {
        guard scene.characters.count < 10 else { return }
        registerUndoSnapshot(label: "Add Character")
        scene.characters.append(Character(body: body, x: 0.35 + 0.06 * Double(scene.characters.count)))
        selection = [scene.characters.count - 1]
    }

    func removeCharacter(at index: Int) {
        guard scene.characters.indices.contains(index) else { return }
        registerUndoSnapshot(label: "Remove Character")
        scene.characters.remove(at: index)
        selection = scene.characters.isEmpty ? [] : [min(index, scene.characters.count - 1)]
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

    func addImageTrack(assetID: String, assetName: String) {
        registerUndoSnapshot(label: "Add Image Track")
        let cue = ImageCue(id: ShowDocumentFile.newID(), assetID: assetID,
                           start: time, dur: 5, from: ImagePlacement())
        scene.imageTracks.append(ImageTrack(id: ShowDocumentFile.newID(),
                                            name: assetName, cues: [cue]))
        selectedImageCue = cue.id
    }

    func addBackgroundCue(assetID: String, assetName: String) {
        registerUndoSnapshot(label: "Set Background")
        if scene.backgroundTracks.isEmpty {
            scene.backgroundTracks = [BackgroundTrack(id: ShowDocumentFile.newID(), name: "Backgrounds")]
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

    // MARK: - Show playlist

    func addShowSegment(from: Double, to: Double) {
        document.show.append(ShowSegment(
            name: "\(String(format: "%.1f", from))–\(String(format: "%.1f", to))s",
            from: from, to: to))
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
