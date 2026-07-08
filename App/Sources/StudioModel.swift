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
    var activeSceneIndex: Int
    /// Held live keys → the codes currently down, per character (drives live sim while recording).
    private(set) var heldCodes: Set<EventCode> = []

    init(document: ShowDocument) {
        self.document = document
        self.activeSceneIndex = min(max(0, document.settings.activeScene), max(0, document.scenes.count - 1))
    }

    var scene: SceneState {
        get { document.scenes[activeSceneIndex].state }
        set { document.scenes[activeSceneIndex].state = newValue }
    }

    var simulator: SceneSimulator { SceneSimulator(state: scene) }

    /// Timeline duration: web tlDurNeeded — max content end + 3s, clamped 20..3600.
    var duration: Double {
        var end = 0.0
        for c in scene.characters {
            end = max(end, c.events.last?.t ?? 0)
            for clip in c.clips { end = max(end, clip.start + clip.dur) }
            for s in c.subs { end = max(end, s.start + s.dur) }
        }
        for t in scene.audioTracks {
            for clip in t.clips { end = max(end, clip.start + clip.dur) }
        }
        return min(3600, max(20, (end + 3).rounded(.up)))
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

    // MARK: - Scenes

    func addScene() {
        pause()
        registerUndoSnapshot(label: "Add Scene")
        document.scenes.append(BannyCore.Scene(id: ShowDocumentFile.newID(),
                                               name: "Scene \(document.scenes.count + 1)",
                                               state: ShowDocumentFile.defaultSceneState()))
        switchScene(to: document.scenes.count - 1)
    }

    func removeScene(at index: Int) {
        guard document.scenes.count > 1, document.scenes.indices.contains(index) else { return }
        pause()
        registerUndoSnapshot(label: "Delete Scene")
        document.scenes.remove(at: index)
        activeSceneIndex = min(activeSceneIndex > index ? activeSceneIndex - 1 : activeSceneIndex,
                               document.scenes.count - 1)
        document.settings.activeScene = activeSceneIndex
    }

    func switchScene(to index: Int) {
        guard document.scenes.indices.contains(index) else { return }
        pause()
        activeSceneIndex = index
        document.settings.activeScene = index
        time = 0
        selection = scene.characters.isEmpty ? [] : [0]
    }

    func moveScene(from: Int, to: Int) {
        guard from != to, document.scenes.indices.contains(from) else { return }
        registerUndoSnapshot(label: "Reorder Scenes")
        let current = document.scenes[activeSceneIndex]
        let moved = document.scenes.remove(at: from)
        document.scenes.insert(moved, at: min(to, document.scenes.count))
        activeSceneIndex = document.scenes.firstIndex { $0.id == current.id } ?? 0
        document.settings.activeScene = activeSceneIndex
    }

    // MARK: - Show playlist

    func addShowSegment(from: Double, to: Double) {
        let scene = document.scenes[activeSceneIndex]
        document.show.append(ShowSegment(
            sceneID: scene.id,
            name: "\(scene.name) \(String(format: "%.1f", from))–\(String(format: "%.1f", to))s",
            from: from, to: to))
    }

    // MARK: - Undo

    /// Scene-state snapshot undo, mirroring the web's per-scene undo stack.
    func registerUndoSnapshot(label: String) {
        let snapshot = scene
        let sceneIndex = activeSceneIndex
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let redo = model.document.scenes[sceneIndex].state
                model.document.scenes[sceneIndex].state = snapshot
                model.undoManager?.registerUndo(withTarget: model) { m in
                    MainActor.assumeIsolated {
                        m.document.scenes[sceneIndex].state = redo
                    }
                }
            }
        }
        undoManager?.setActionName(label)
    }
}

extension ShowDocumentFile {
    /// Placeholder until phase 4 wires AVAudioEngine in.
    var audioEngine: StudioAudioEngine? { nil }
}

/// Phase 4 fills this in; the model only needs a sync hook.
protocol StudioAudioEngine {
    @MainActor func syncPlayback(_ model: StudioModel)
}
