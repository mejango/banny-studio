import SwiftUI
import Observation
import AVFoundation
import ImageIO
import BannyCore

struct ReactionSelection: Equatable {
    var character: Int
    var id: String
}

/// One source-relative automatic mouth interval selected on the timeline.
/// The index is stable while editing because mouth intervals are constrained
/// between their neighbours instead of silently reordering beneath the user.
struct MouthCueSelection: Equatable {
    var character: Int
    var clipID: String
    var cueIndex: Int
}

/// Ephemeral lip sync for inspector voice previews. It deliberately lives
/// outside the document: previewing never edits clips, moves the playhead, or
/// creates undo history.
struct SpeechMouthPreview: Equatable {
    let token: UUID
    let characterIndex: Int
    let startedAt: TimeInterval
    let duration: Double
    let cues: [SpeechMouthCue]

    /// Resolves against the same monotonic clock that starts preview audio.
    /// Waveform gaps deliberately close the mouth rather than removing the
    /// preview override.
    func shape(at clockTime: TimeInterval) -> MouthShape? {
        let elapsed = clockTime - startedAt
        guard elapsed >= 0, elapsed < duration else { return nil }
        // Automatic mouth is deliberately the same binary action as holding M.
        return SpeechMouthCue.shape(in: cues, at: elapsed) == nil ? .closed : .open
    }
}

/// Per-document editor state: transport, recording, selection, scene switching.
/// Stage state is always derived via SceneSimulator — this model only owns the
/// document and the clock.
@MainActor
@Observable
final class StudioModel {
    var document: ShowDocument {
        didSet { file?.updateDocumentSnapshot(document) }
    }
    weak var file: ShowDocumentFile? {
        didSet { file?.updateDocumentSnapshot(document) }
    }
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
    private var characterRecordUndoScene: SceneState?
    private var startWall: TimeInterval = 0

    // Editor state.
    var selection: Set<Int> = [0] {
        didSet {
            // Track intent separately from the unordered multi-selection.
            // Non-character tracks keep `selection` around, but Scenes needs
            // one predictable performer for stopped-stage previews.
            let added = selection.subtracting(oldValue)
            if let index = added.max() {
                lastSelectedCharacterIndex = index
            } else if selection.count == 1 {
                lastSelectedCharacterIndex = selection.first
            }
        }
    }
    private(set) var lastSelectedCharacterIndex: Int? = 0
    /// The track whose inspector the right panel shows (TrackRow key).
    var selectedTrackKey: String? = "c-0"
    var activeSceneIndex: Int
    /// Held live keys → the codes currently down, per character (drives live sim while recording).
    private(set) var heldCodes: Set<EventCode> = []
    /// Live-only mouth poses while the character inspector previews a voice.
    var speechMouthPreview: SpeechMouthPreview?
    @ObservationIgnored var speechMouthPreviewCleanupTask: Task<Void, Never>?
    /// Bumped whenever background media changes so caches invalidate.
    var backgroundRevision = 0
    @ObservationIgnored private var visualDurationCache: [String: Double] = [:]

    // Timeline selection (shared with keyboard shortcuts).
    var selectedMarks: Set<PerfMark> = []
    var selectedClips: Set<String> = []
    /// Image cue selected on the timeline (drag on stage repositions it).
    var selectedImageCue: String?
    var selectedBackgroundCue: String?
    /// Marquee/multi-select of scene cues (move or delete together). The single
    /// `selectedBackgroundCue` stays the inspector/camera focus.
    var selectedBackgroundCues: Set<String> = []
    /// A clicked outfit-change dot: (character, index into its events).
    var selectedOutfitEvent: (char: Int, index: Int)?
    /// A clicked motion-change keyframe: (character, index into its events).
    var selectedMotionEvent: (char: Int, index: Int)?
    /// A reusable reaction block selected on a character lane.
    var selectedReaction: ReactionSelection?
    /// A baked automatic-mouth interval selected in the Mouth lane.
    var selectedMouthCue: MouthCueSelection?
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
        let editableClipboard = markClipboard.filter {
            scene.characters[safe: $0.character]?.locked == false
        }
        guard !editableClipboard.isEmpty else { return }
        registerUndoSnapshot(label: "Paste Marks")
        let base = selectedMarks.map(\.end).max().map { $0 + 0.05 } ?? time
        var pasted: Set<PerfMark> = []
        for m in editableClipboard {
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
    func duplicateSelectedMarksInPlace(registerUndo: Bool = true) {
        let editableMarks = selectedMarks.filter {
            scene.characters[safe: $0.character]?.locked == false
        }
        guard !editableMarks.isEmpty else { return }
        if registerUndo {
            registerUndoSnapshot(label: "Duplicate Marks")
        }
        var dups: Set<PerfMark> = []
        for m in editableMarks {
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
        guard !isClipLocked(id) else { return }
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
            clip.fadeIn = min(clip.fadeIn, clip.dur)
            clip.fadeOut = min(clip.fadeOut, clip.dur)
        }
    }

    /// ⌘-drag: clone a clip in place (media ref copied) and return the copy's id.
    func duplicateClip(id: String, registerUndo: Bool = true) -> String? {
        guard !isClipLocked(id) else { return nil }
        if registerUndo {
            registerUndoSnapshot(label: "Duplicate Clip")
        }
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

    func audioClip(id: String) -> AudioClip? {
        for character in scene.characters {
            if let clip = character.clips.first(where: { $0.id == id }) { return clip }
        }
        for track in scene.audioTracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
    }

    func setClipFades(id: String, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        guard audioClip(id: id) != nil, !isClipLocked(id) else { return }
        setClip(id: id) { value in
            if let fadeIn { value.fadeIn = min(max(0, fadeIn), value.dur) }
            if let fadeOut { value.fadeOut = min(max(0, fadeOut), value.dur) }
        }
    }

    /// Duration shared by two selected overlapping clips, when they belong to
    /// the same track and can form a conventional crossfade.
    var selectedCrossfadeDuration: Double? {
        guard selectedClips.count == 2 else { return nil }
        let ids = Array(selectedClips)
        guard let firstOwner = clipOwner(id: ids[0]),
              let secondOwner = clipOwner(id: ids[1]),
              firstOwner.key == secondOwner.key else { return nil }
        let ordered = [firstOwner.clip, secondOwner.clip].sorted { $0.start < $1.start }
        let overlap = ordered[0].start + ordered[0].dur - ordered[1].start
        return overlap > 0.02 ? overlap : nil
    }

    func applyCrossfadeToSelectedClips() {
        guard selectedClips.count == 2, let overlap = selectedCrossfadeDuration else { return }
        let clips = selectedClips.compactMap { audioClip(id: $0) }.sorted { $0.start < $1.start }
        guard clips.count == 2, !clips.contains(where: { isClipLocked($0.id) }) else { return }
        registerUndoSnapshot(label: "Crossfade Clips")
        setClip(id: clips[0].id) { $0.fadeOut = min($0.dur, overlap) }
        setClip(id: clips[1].id) { $0.fadeIn = min($0.dur, overlap) }
        resyncAudioIfPlaying()
    }

    private func clipOwner(id: String) -> (key: String, clip: AudioClip)? {
        for (index, character) in scene.characters.enumerated() {
            if let clip = character.clips.first(where: { $0.id == id }) {
                return ("c-\(index)", clip)
            }
        }
        for track in scene.audioTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                return (track.id, clip)
            }
        }
        return nil
    }

    /// ⌘-drag: clone a cue in place; returns the copy's id.
    func duplicateCue(
        kind: TrackRowKind,
        id: String,
        registerUndo: Bool = true
    ) -> String? {
        guard !isTrackLocked(kind) else { return nil }
        if registerUndo {
            registerUndoSnapshot(label: "Duplicate Cue")
        }
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
    private var reactionClipboard: (character: Int, block: ReactionInstance)?

    var hasTimelineSelection: Bool {
        !selectedMarks.isEmpty || !selectedClips.isEmpty || selectedImageCue != nil
            || selectedLightCue != nil || selectedBackgroundCue != nil
            || !selectedBackgroundCues.isEmpty || selectedOutfitEvent != nil
            || selectedMotionEvent != nil || selectedReaction != nil
            || selectedMouthCue != nil
    }

    /// Mouth automation belongs to its source clip, so it is movable/deletable
    /// but is not offered as a free-floating clipboard item.
    var hasCopyableTimelineSelection: Bool {
        hasTimelineSelection && selectedMouthCue == nil
    }

    /// True when ← / → should shift the timeline selection rather than drive a
    /// track's pen (single cues are edited via their pen/inspector, so they're
    /// drag-only — this excludes them to avoid hijacking light/camera arrows).
    var hasArrowMovableSelection: Bool {
        !selectedMarks.isEmpty || !selectedClips.isEmpty
            || selectedOutfitEvent != nil || selectedMotionEvent != nil
            || !selectedBackgroundCues.isEmpty || selectedReaction != nil
            || selectedMouthCue != nil
    }

    /// ← / → on the timeline: shift every arrow-movable selected element. dt sec.
    func nudgeTimelineSelection(by dt: Double) {
        guard dt != 0, hasArrowMovableSelection else { return }
        let editableMarks = Set(selectedMarks.filter {
            scene.characters[safe: $0.character]?.locked == false
        })
        let editableClips = selectedClips.filter { !isClipLocked($0) }
        let editableBackgrounds = selectedBackgroundCues.filter { !isBackgroundCueLocked($0) }
        let editableOutfit = selectedOutfitEvent.map {
            scene.characters[safe: $0.char]?.locked == false
        } ?? false
        let editableMotion = selectedMotionEvent.map {
            scene.characters[safe: $0.char]?.locked == false
        } ?? false
        let editableReaction = selectedReaction.map {
            scene.characters[safe: $0.character]?.locked == false
        } ?? false
        let editableMouth = selectedMouthCue.map {
            scene.characters[safe: $0.character]?.locked == false
        } ?? false
        guard !editableMarks.isEmpty || !editableClips.isEmpty
                || !editableBackgrounds.isEmpty || editableOutfit
                || editableMotion || editableReaction || editableMouth else { return }
        registerUndoSnapshot(label: "Nudge Selection")
        // Marks (per character).
        if !editableMarks.isEmpty {
            for ci in Set(editableMarks.map(\.character)) where scene.characters.indices.contains(ci) {
                var events = scene.characters[ci].events
                let hit = editableMarks.filter { $0.character == ci }
                events = events.map { ev in
                    guard case .key(let t, let code, let down) = ev,
                          hit.contains(where: { $0.code == code && t >= $0.start - 1e-6 && t <= $0.end + 1e-6 })
                    else { return ev }
                    return .key(t: max(0, ((t + dt) * 1000).rounded() / 1000), code: code, down: down)
                }
                events.sort { $0.t < $1.t }
                scene.characters[ci].events = events
            }
            selectedMarks = Set(selectedMarks.map { mark in
                guard editableMarks.contains(mark) else { return mark }
                return PerfMark(character: mark.character, code: mark.code,
                                start: max(0, mark.start + dt), end: max(0, mark.end + dt))
            })
        }
        // Clips (character + audio tracks).
        for id in editableClips {
            if let clip = audioClip(id: id) {
                moveClip(id: id, toStart: clip.start + dt)
            }
        }
        // Marquee'd scene cues move as a group (single cues are drag-only).
        for id in editableBackgrounds {
            for ti in scene.backgroundTracks.indices {
                if let ci = scene.backgroundTracks[ti].cues.firstIndex(where: { $0.id == id }) {
                    scene.backgroundTracks[ti].cues[ci].start = max(0, scene.backgroundTracks[ti].cues[ci].start + dt)
                }
            }
        }
        // Outfit event.
        if editableOutfit, let sel = selectedOutfitEvent, scene.characters.indices.contains(sel.char),
           scene.characters[sel.char].events.indices.contains(sel.index),
           case .outfit(let t, _, _) = scene.characters[sel.char].events[sel.index] {
            moveOutfitEvent(char: sel.char, index: sel.index, to: t + dt)
        }
        // Motion keyframe.
        if editableMotion, let sel = selectedMotionEvent, scene.characters.indices.contains(sel.char),
           scene.characters[sel.char].events.indices.contains(sel.index),
           case .motion(let t, _, _, _, _) = scene.characters[sel.char].events[sel.index] {
            moveMotionEvent(char: sel.char, index: sel.index, to: t + dt)
        }
        if editableReaction, let selection = selectedReaction,
           scene.characters.indices.contains(selection.character),
           let index = scene.characters[selection.character].reactions
            .firstIndex(where: { $0.id == selection.id }) {
            scene.characters[selection.character].reactions[index].start = max(
                0, scene.characters[selection.character].reactions[index].start + dt)
        }
        if editableMouth, let selection = selectedMouthCue,
           let cue = mouthCueValue(selection) {
            moveMouthCue(selection, toStart: cue.start + dt, registerUndo: false)
        }
    }

    /// Every selected scene cue (the multi-set, else the single).
    func bgCueSelection() -> Set<String> {
        if !selectedBackgroundCues.isEmpty { return selectedBackgroundCues }
        return selectedBackgroundCue.map { [$0] } ?? []
    }

    // MARK: - Motion keyframes (timed speed/rotation/wobble/size like outfit changes)

    /// Motion params effective at t: the base value overridden by the last
    /// timed `.motion` change at or before t.
    func resolvedMotion(characterIndex i: Int, at t: Double)
        -> (speed: Double, rotationSpeed: Double, wobble: Double, size: Double) {
        guard let c = scene.characters[safe: i] else { return (320, 90, 7, 1) }
        var speed = c.speed, rotationSpeed = c.rotationSpeed, wobble = c.wobble, size = c.size
        for ev in c.events {
            guard ev.t <= t + 1e-9 else { break }
            if case .motion(_, let s, let r, let w, let z) = ev {
                if let s { speed = s }
                if let r { rotationSpeed = r }
                if let w { wobble = w }
                if let z { size = z }
            }
        }
        return (speed, rotationSpeed, wobble, size)
    }

    /// Edits a motion param at time t: at the very start it moves the base
    /// value; later it creates or updates a timed keyframe (merging into one
    /// within 30ms). Mirrors how `setOutfit` splits base vs timed.
    func setMotionParam(characterIndex i: Int, at t: Double,
                        speed: Double? = nil, rotationSpeed: Double? = nil,
                        wobble: Double? = nil, size: Double? = nil,
                        registerUndo: Bool = true) {
        guard scene.characters.indices.contains(i), !scene.characters[i].locked else { return }
        if registerUndo {
            registerUndoSnapshot(label: t < 0.05 ? "Adjust Motion" : "Motion Keyframe")
        }
        if t < 0.05 {
            if let speed { scene.characters[i].speed = speed }
            if let rotationSpeed { scene.characters[i].rotationSpeed = rotationSpeed }
            if let wobble { scene.characters[i].wobble = wobble }
            if let size { scene.characters[i].size = size }
            return
        }
        var events = scene.characters[i].events
        let stamp = (t * 1000).rounded() / 1000
        if let idx = events.firstIndex(where: {
            if case .motion(let mt, _, _, _, _) = $0 { return abs(mt - stamp) < 0.03 }; return false
        }), case .motion(let mt, let s0, let r0, let w0, let z0) = events[idx] {
            events[idx] = .motion(t: mt, speed: speed ?? s0,
                                  rotationSpeed: rotationSpeed ?? r0,
                                  wobble: wobble ?? w0, size: size ?? z0)
        } else {
            events.append(.motion(t: stamp, speed: speed, rotationSpeed: rotationSpeed,
                                  wobble: wobble, size: size))
            events.sort { $0.t < $1.t }
        }
        scene.characters[i].events = events
    }

    /// Character rotation pivot is a base transform rather than a timed motion
    /// parameter. Nil restores Auto (feet for grounded spin, center for flips).
    func setRotationPivot(characterIndex i: Int, pivot: MediaPivot?,
                          registerUndo: Bool = true) {
        guard scene.characters.indices.contains(i), !scene.characters[i].locked else { return }
        let clamped = pivot.map {
            MediaPivot(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y)))
        }
        guard scene.characters[i].rotationPivot != clamped else { return }
        if registerUndo { registerUndoSnapshot(label: "Change Rotation Pivot") }
        scene.characters[i].rotationPivot = clamped
    }

    /// Moves a motion keyframe to time t (arrow-nudge / drag), keeping the
    /// selection on it.
    func moveMotionEvent(char: Int, index: Int, to t: Double) {
        guard scene.characters.indices.contains(char),
              !scene.characters[char].locked,
              scene.characters[char].events.indices.contains(index),
              case .motion(_, let s, let r, let w, let z) = scene.characters[char].events[index] else { return }
        let nt = max(0, (t * 1000).rounded() / 1000)
        var events = scene.characters[char].events
        events.remove(at: index)
        let moved = PerfEvent.motion(t: nt, speed: s, rotationSpeed: r, wobble: w, size: z)
        let insertAt = events.firstIndex { $0.t > nt } ?? events.count
        events.insert(moved, at: insertAt)
        scene.characters[char].events = events
        selectedMotionEvent = (char, insertAt)
    }

    /// Moves an outfit-change event to time t, keeping events sorted and the
    /// selection on the same event.
    func moveOutfitEvent(char: Int, index: Int, to t: Double) {
        guard scene.characters.indices.contains(char),
              !scene.characters[char].locked,
              scene.characters[char].events.indices.contains(index),
              case .outfit(_, let slot, let name) = scene.characters[char].events[index] else { return }
        let nt = max(0, (t * 1000).rounded() / 1000)
        var events = scene.characters[char].events
        events.remove(at: index)
        let moved = PerfEvent.outfit(t: nt, slot: slot, name: name)
        let insertAt = events.firstIndex { $0.t > nt } ?? events.count
        events.insert(moved, at: insertAt)
        scene.characters[char].events = events
        selectedOutfitEvent = (char, insertAt)
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
        var pickedReaction: (Int, ReactionInstance)?
        if let selection = selectedReaction,
           scene.characters.indices.contains(selection.character),
           let block = scene.characters[selection.character].reactions
            .first(where: { $0.id == selection.id }) {
            pickedReaction = (selection.character, block)
            t0 = min(t0, block.start)
        }
        guard t0 < .greatestFiniteMagnitude else { return }
        markClipboard = selectedMarks.map { ($0.character, $0.code, $0.start - t0, $0.end - t0) }
        clipClipboard = pickedClips.map { owner, clip in
            var c = clip; c.start -= t0; return (owner, c)
        }
        imageCueClipboard = pickedImage.map { tid, cue in var c = cue; c.start -= t0; return (tid, c) }
        lightCueClipboard = pickedLight.map { tid, cue in var c = cue; c.start -= t0; return (tid, c) }
        bgCueClipboard = pickedBG.map { var c = $0; c.start -= t0; return c }
        reactionClipboard = pickedReaction.map { character, block in
            var copy = block
            copy.start -= t0
            return (character, copy)
        }
    }

    /// ⌘V / right-click Paste: at `anchor` when given, right after the current
    /// selection when one exists, else at the playhead. Pasted items select,
    /// so repeated ⌘V chains.
    func pasteTimeline(at anchor: Double? = nil) {
        let canPasteMarks = markClipboard.contains {
            scene.characters[safe: $0.character]?.locked == false
        }
        let canPasteClips = clipClipboard.contains { owner, _ in
            if owner.hasPrefix("c"), let index = Int(owner.dropFirst()) {
                return scene.characters[safe: index]?.locked == false
            }
            return scene.audioTracks.first(where: { $0.id == owner })?.locked == false
        }
        let canPasteImages = imageCueClipboard.contains { trackID, _ in
            scene.imageTracks.first(where: { $0.id == trackID })?.locked == false
                || scene.audioTracks.first(where: { $0.id == trackID })?.locked == false
        }
        let canPasteLights = lightCueClipboard.contains { trackID, _ in
            scene.lightTracks.first(where: { $0.id == trackID })?.locked == false
        }
        let canPasteBackgrounds = !bgCueClipboard.isEmpty
            && scene.backgroundTracks.first?.locked == false
        let canPasteReaction = reactionClipboard.map { clipboard in
            scene.characters[safe: clipboard.character]?.locked == false
                && scene.reactionLibrary.contains(where: { $0.id == clipboard.block.reactionID })
        } ?? false
        guard canPasteMarks || canPasteClips || canPasteImages || canPasteLights
                || canPasteBackgrounds || canPasteReaction else { return }
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
            if let selection = selectedReaction,
               scene.characters.indices.contains(selection.character),
               let block = scene.characters[selection.character].reactions
                .first(where: { $0.id == selection.id }) {
                selEnd = max(selEnd, block.start + block.dur)
            }
            if selEnd > 0 { base = selEnd + 0.05 }
        }
        registerUndoSnapshot(label: "Paste")
        var pastedMarks: Set<PerfMark> = []
        for m in markClipboard {
            guard scene.characters[safe: m.character]?.locked == false else { continue }
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
            var inserted = false
            if owner.hasPrefix("c"), let i = Int(owner.dropFirst()),
               scene.characters[safe: i]?.locked == false {
                scene.characters[i].clips.append(c)
                inserted = true
            } else if let ti = scene.audioTracks.firstIndex(where: { $0.id == owner }),
                      !scene.audioTracks[ti].locked {
                scene.audioTracks[ti].clips.append(c)
                inserted = true
            }
            guard inserted else { continue }
            if let media = file?.audio[oldID] { file?.audio[c.id] = media }
            pastedClips.insert(c.id)
        }
        for (tid, cue) in imageCueClipboard {
            var c = cue
            c.id = ShowDocumentFile.newID()
            c.start = cue.start + base
            if let ti = scene.imageTracks.firstIndex(where: { $0.id == tid }),
               !scene.imageTracks[ti].locked {
                scene.imageTracks[ti].cues.append(c)
                scene.imageTracks[ti].cues.sort { $0.start < $1.start }
                selectedImageCue = c.id
            } else if let ti = scene.audioTracks.firstIndex(where: { $0.id == tid }),
                      !scene.audioTracks[ti].locked {
                scene.audioTracks[ti].cues.append(c)
                scene.audioTracks[ti].cues.sort { $0.start < $1.start }
                selectedImageCue = c.id
            }
        }
        for (tid, cue) in lightCueClipboard {
            var c = cue
            c.id = ShowDocumentFile.newID()
            c.start = cue.start + base
            if let ti = scene.lightTracks.firstIndex(where: { $0.id == tid }),
               !scene.lightTracks[ti].locked {
                scene.lightTracks[ti].cues.append(c)
                scene.lightTracks[ti].cues.sort { $0.start < $1.start }
                selectedLightCue = c.id
            }
        }
        for cue in bgCueClipboard {
            var c = cue
            c.id = ShowDocumentFile.newID()
            c.start = cue.start + base
            if scene.backgroundTracks.first?.locked == false {
                scene.backgroundTracks[0].cues.append(c)
                scene.backgroundTracks[0].cues.sort { $0.start < $1.start }
                selectedBackgroundCue = c.id
            }
        }
        if let (character, source) = reactionClipboard,
           scene.characters[safe: character]?.locked == false,
           scene.reactionLibrary.contains(where: { $0.id == source.reactionID }) {
            var block = source
            block.id = ShowDocumentFile.newID()
            block.start += base
            scene.characters[character].reactions.append(block)
            scene.characters[character].reactions.sort { $0.start < $1.start }
            selectedReaction = ReactionSelection(character: character, id: block.id)
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
        let editableMarks = Set(selectedMarks.filter {
            scene.characters[safe: $0.character]?.locked != true
        })
        if !editableMarks.isEmpty {
            registerUndoSnapshot(label: "Delete Marks")
            for charIndex in Set(editableMarks.map(\.character)) {
                let charMarks = Set(editableMarks.filter { $0.character == charIndex })
                scene.characters[charIndex].events =
                    TimelineMath.removeMarks(charMarks, from: scene.characters[charIndex].events)
            }
            selectedMarks.subtract(editableMarks)
        }
        let editableClips = selectedClips.filter { !isClipLocked($0) }
        for id in editableClips { removeClip(id: id) }
        selectedClips.subtract(editableClips)
        if let id = selectedImageCue, !isImageCueLocked(id) {
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
               !scene.characters[sel.char].locked,
               scene.characters[sel.char].events.indices.contains(sel.index),
               case .outfit = scene.characters[sel.char].events[sel.index] {
                registerUndoSnapshot(label: "Delete Outfit Change")
                scene.characters[sel.char].events.remove(at: sel.index)
            }
            selectedOutfitEvent = nil
        }
        if let sel = selectedMotionEvent {
            if scene.characters.indices.contains(sel.char),
               !scene.characters[sel.char].locked,
               scene.characters[sel.char].events.indices.contains(sel.index),
               case .motion = scene.characters[sel.char].events[sel.index] {
                registerUndoSnapshot(label: "Delete Motion Keyframe")
                scene.characters[sel.char].events.remove(at: sel.index)
            }
            selectedMotionEvent = nil
        }
        if let selection = selectedReaction {
            if scene.characters.indices.contains(selection.character),
               !scene.characters[selection.character].locked {
                registerUndoSnapshot(label: "Delete Reaction Block")
                scene.characters[selection.character].reactions.removeAll { $0.id == selection.id }
            }
            selectedReaction = nil
        }
        if let selection = selectedMouthCue {
            deleteMouthCue(selection, registerUndo: true)
        }
        let bgKill = bgCueSelection().filter { !isBackgroundCueLocked($0) }
        if !bgKill.isEmpty {
            registerUndoSnapshot(label: "Delete Scene Cue")
            for i in scene.backgroundTracks.indices {
                scene.backgroundTracks[i].cues.removeAll { bgKill.contains($0.id) }
            }
            selectedBackgroundCue = nil
            selectedBackgroundCues = []
            backgroundRevision += 1
        }
        if let id = selectedLightCue, !isLightCueLocked(id) {
            registerUndoSnapshot(label: "Delete Light Cue")
            for i in scene.lightTracks.indices {
                scene.lightTracks[i].cues.removeAll { $0.id == id }
            }
            selectedLightCue = nil
        }
    }

    /// The selected background (scene) cue, if any.
    var selectedBackgroundCueValue: BackgroundCue? {
        guard let id = selectedBackgroundCue else { return nil }
        for t in scene.backgroundTracks {
            if let c = t.cues.first(where: { $0.id == id }) { return c }
        }
        return nil
    }

    func updateSelectedBackgroundCue(_ body: (inout BackgroundCue) -> Void) {
        guard let id = selectedBackgroundCue, !isBackgroundCueLocked(id) else { return }
        for ti in scene.backgroundTracks.indices {
            if let ci = scene.backgroundTracks[ti].cues.firstIndex(where: { $0.id == id }) {
                body(&scene.backgroundTracks[ti].cues[ci])
                return
            }
        }
    }

    /// Output frame aspect (w/h) from the document settings.
    var frameAspect: Double { document.settings.frameAspect }

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

    /// Source duration for an animated GIF or video. Static images return nil,
    /// which keeps playback-only controls out of their inspector.
    func visualSourceDuration(assetID: String) -> Double? {
        if let cached = visualDurationCache[assetID] { return cached }
        guard let asset = document.assets.first(where: { $0.id == assetID }),
              let media = file?.assetsMedia[assetID] else { return nil }
        let duration: Double?
        switch asset.kind {
        case .video:
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("visual-meta-\(assetID).\(media.ext)")
            if !FileManager.default.fileExists(atPath: url.path) {
                try? media.data.write(to: url)
            }
            let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
            duration = seconds.isFinite && seconds > 0 ? seconds : nil
        case .image:
            guard let source = CGImageSourceCreateWithData(media.data as CFData, nil),
                  CGImageSourceGetCount(source) > 1 else { return nil }
            var seconds = 0.0
            for i in 0..<CGImageSourceGetCount(source) {
                let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil)
                    as? [CFString: Any]
                let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                var delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
                if delay <= 0 { delay = gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0 }
                seconds += delay <= 0.011 ? 0.1 : delay
            }
            duration = seconds > 0 ? seconds : nil
        }
        if let duration { visualDurationCache[assetID] = duration }
        return duration
    }

    /// The selected visual belongs to the selected media/image track, so its
    /// performance controls may claim the keyboard instead of a character.
    var selectedVisualCueOnSelectedTrack: Bool {
        guard let key = selectedTrackKey, let owner = selectedImageCueOwner else { return false }
        return owner.trackID == key
    }

    /// Scenes remains the editing/record target, but while transport is
    /// stopped its performance keys preview the most recently selected
    /// character. This makes perspective, gravity, and global-size changes
    /// immediately testable without bouncing between inspectors.
    var scenePreviewCharacterIndex: Int? {
        if let index = lastSelectedCharacterIndex,
           scene.characters.indices.contains(index) {
            return index
        }
        return selection.sorted().last(where: scene.characters.indices.contains)
            ?? scene.characters.indices.first
    }

    var scenesTrackSelected: Bool {
        guard let key = selectedTrackKey else { return false }
        return scene.backgroundTracks.contains(where: { $0.id == key })
    }

    /// Character rotate/zoom reset chords and the regular performance
    /// vocabulary share this decision in the keyboard monitor.
    var acceptsCharacterPerformanceKeys: Bool {
        if selectedTrackKey == nil || selectedTrackKey?.hasPrefix("c-") == true { return true }
        return scenesTrackSelected && !isCameraRecording && scenePreviewCharacterIndex != nil
    }

    func updateSelectedImageCue(_ body: (inout ImageCue) -> Void) {
        guard let id = selectedImageCue, !isImageCueLocked(id) else { return }
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

    /// Whether the placement visible at the playhead differs from the visual
    /// cue's saved starting placement.
    var selectedImageCueStartStateMismatch: Bool {
        guard let cue = selectedImageCueValue else { return false }
        let p = cue.placement(at: time)
        return abs(p.x - cue.from.x) > 0.0005 || abs(p.y - cue.from.y) > 0.0005
            || abs(p.scale - cue.from.scale) > 0.0005
            || abs(p.rotation - cue.from.rotation) > 0.05
    }

    /// Uses the complete placement visible at the playhead as this cue's start.
    func commitSelectedImageCueStartState() {
        guard let cue = selectedImageCueValue, selectedImageCueStartStateMismatch else { return }
        let state = cue.placement(at: time)
        registerUndoSnapshot(label: "Set Visual Start State")
        updateSelectedImageCue { $0.from = state }
    }

    /// Image cue on a MEDIA (audio) track.
    func addMediaImageCue(trackIndex: Int, assetID: String, at t: Double) {
        guard scene.audioTracks.indices.contains(trackIndex),
              !scene.audioTracks[trackIndex].locked else { return }
        registerUndoSnapshot(label: "Add Visual Cue")
        let cue = ImageCue(id: ShowDocumentFile.newID(), assetID: assetID,
                           start: t, dur: 5, from: ImagePlacement())
        scene.audioTracks[trackIndex].cues.append(cue)
        scene.audioTracks[trackIndex].cues.sort { $0.start < $1.start }
        selectedTrackKey = scene.audioTracks[trackIndex].id
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
        // v4 adds production markers, track locks/solo, and audio fades. Their
        // decoders supply lossless defaults for older documents, so migration
        // is simply recording the schema now represented in memory.
        if doc.version < 4 { doc.version = 4 }
        self.document = doc
        self.activeSceneIndex = 0
    }

    /// The single stage/timeline (v3+).
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

    private enum ImageRecordOwner {
        case imageTrack(Int)
        case mediaTrack(Int)
    }

    /// Immutable identity for one take. Keeping owner, cue, and asset together
    /// prevents partially configured recording state.
    private struct ImageRecordTarget {
        let owner: ImageRecordOwner
        let cueID: String
        let assetID: String
    }

    private var imageRecordTarget: ImageRecordTarget?
    private var imageSamples: [(t: Double, x: Double, y: Double, scale: Double, rotation: Double)] = []
    private var imagePen = ImagePlacement()
    var imageRecordCueID: String? { imageRecordTarget?.cueID }
    var isImageRecording: Bool { imageRecordTarget != nil }
    var imagePenNow: ImagePlacement? {
        isImageRecording ? imagePen : nil
    }

    func imageRecordSample(x: Double, y: Double) {
        guard isImageRecording else { return }
        imagePen.x = min(1.2, max(-0.2, x))
        imagePen.y = min(1.2, max(-0.2, y))
        if let last = imageSamples.last, time - last.t < 0.15 { return }
        imageSamples.append((time, imagePen.x, imagePen.y, imagePen.scale, imagePen.rotation))
    }

    /// Captures holds as well as movement. Without periodic stationary samples,
    /// waiting before a drag would be simplified into one slow move from the
    /// beginning of the take to the first pointer update.
    func imageRecordTick() {
        guard isImageRecording else { return }
        imageRecordSample(x: imagePen.x, y: imagePen.y)
    }

    /// Applies the live pen to the known recording owner in O(cues in one
    /// track), avoiding a scan of every visual track on every rendered frame.
    func applyImageRecordingPreview(to preview: inout SceneState) {
        guard let target = imageRecordTarget else { return }
        func apply(to cues: inout [ImageCue]) {
            guard let index = cues.firstIndex(where: { $0.id == target.cueID }) else { return }
            cues[index].from = imagePen
            cues[index].to = nil
        }
        switch target.owner {
        case .imageTrack(let index) where preview.imageTracks.indices.contains(index):
            apply(to: &preview.imageTracks[index].cues)
        case .mediaTrack(let index) where preview.audioTracks.indices.contains(index):
            apply(to: &preview.audioTracks[index].cues)
        default:
            break
        }
    }

    private func imageCues(for target: ImageRecordTarget) -> [ImageCue]? {
        switch target.owner {
        case .imageTrack(let index) where scene.imageTracks.indices.contains(index):
            return scene.imageTracks[index].cues
        case .mediaTrack(let index) where scene.audioTracks.indices.contains(index):
            return scene.audioTracks[index].cues
        default:
            return nil
        }
    }

    private func imageCue(for target: ImageRecordTarget) -> ImageCue? {
        imageCues(for: target)?.first { $0.id == target.cueID }
    }

    private func replaceImageCues(for target: ImageRecordTarget, with cues: [ImageCue]) {
        switch target.owner {
        case .imageTrack(let index) where scene.imageTracks.indices.contains(index)
            && !scene.imageTracks[index].locked:
            scene.imageTracks[index].cues = cues
        case .mediaTrack(let index) where scene.audioTracks.indices.contains(index)
            && !scene.audioTracks[index].locked:
            scene.audioTracks[index].cues = cues
        default:
            break
        }
    }

    private func commitImageRecording() {
        defer {
            imageRecordTarget = nil
            imageSamples = []
        }
        if let last = imageSamples.last, time - last.t > 0.02 {
            imageSamples.append((time, imagePen.x, imagePen.y, imagePen.scale, imagePen.rotation))
        }
        guard imageSamples.count >= 2, let target = imageRecordTarget else { return }
        switch target.owner {
        case .imageTrack(let index):
            guard scene.imageTracks[safe: index]?.locked == false else { return }
        case .mediaTrack(let index):
            guard scene.audioTracks[safe: index]?.locked == false else { return }
        }
        let recordedCueID = target.cueID
        let origin = imageSamples[0]
        guard imageSamples.contains(where: {
            abs($0.x - origin.x) > 0.001 || abs($0.y - origin.y) > 0.001
                || abs($0.scale - origin.scale) > 0.001
                || abs($0.rotation - origin.rotation) > 0.1
        }) else { return }
        registerUndoSnapshot(label: "Record Image Motion")
        let recordedCue = imageCue(for: target)
        let recordedLabel = recordedCue?.label
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
               abs(a.scale + (c.scale - a.scale) * f - b.scale) < 0.01,
               abs(a.rotation + (c.rotation - a.rotation) * f - b.rotation) < 0.5 {
                pts.remove(at: i)
            } else {
                i += 1
            }
        }
        let assetID = target.assetID
        let recordedSpeed = recordedCue?.speed ?? ImageCue.defaultSpeed
        let recordedRotationSpeed = recordedCue?.rotationSpeed
            ?? ImageCue.defaultRotationSpeed
        let recordedPlayback = recordedCue?.playback ?? MediaPlayback()
        let recordedAppearance = recordedCue?.appearance ?? MediaAppearance()
        let recordedMask = recordedCue?.mask ?? .none
        let recordedMaskRadius = recordedCue?.maskRadius ?? 0.12
        let recordedPivot = recordedCue?.pivot ?? .center
        let last = pts[pts.count - 1]
        let recordedEnd = ImagePlacement(x: last.x, y: last.y, scale: last.scale,
                                         rotation: last.rotation)
        var recordedIDs: [String] = []
        var continuationID: String?
        func rebuilt(_ cues: [ImageCue]) -> [ImageCue] {
            var out: [ImageCue] = []
            for var cue in cues {
                let end = cue.start + cue.dur
                if cue.id != recordedCueID || end <= t0 + 0.01 || cue.start >= tEnd - 0.01 {
                    out.append(cue)
                } else if cue.start < t0, end > tEnd {
                    var tail = cue
                    tail.id = ShowDocumentFile.newID()
                    continuationID = tail.id
                    tail.from = recordedEnd
                    tail.playback = cue.continuedPlayback(at: tEnd)
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
                    cue.from = recordedEnd
                    cue.playback = cue.continuedPlayback(at: tEnd)
                    cue.dur = end - tEnd
                    cue.start = tEnd
                    continuationID = cue.id
                    out.append(cue)
                }
            }
            for k in 0..<(pts.count - 1) {
                let a = pts[k], b = pts[k + 1]
                guard b.t - a.t > 0.02 else { continue }
                let id = ShowDocumentFile.newID()
                recordedIDs.append(id)
                let playback = recordedCue?.continuedPlayback(at: a.t) ?? recordedPlayback
                out.append(ImageCue(
                    id: id, assetID: assetID, start: a.t, dur: b.t - a.t,
                    from: ImagePlacement(x: a.x, y: a.y, scale: a.scale,
                                         rotation: a.rotation),
                    to: ImagePlacement(x: b.x, y: b.y, scale: b.scale,
                                       rotation: b.rotation),
                    speed: recordedSpeed, rotationSpeed: recordedRotationSpeed,
                    playback: playback, appearance: recordedAppearance,
                    mask: recordedMask, maskRadius: recordedMaskRadius,
                    pivot: recordedPivot,
                    label: k == 0 ? recordedLabel : ""))
            }
            return out.sorted { $0.start < $1.start }
        }
        guard let existingCues = imageCues(for: target) else { return }
        replaceImageCues(for: target, with: rebuilt(existingCues))
        selectedImageCue = continuationID ?? recordedIDs.last
    }

    // MARK: - Camera path recording (drive the frame's cut of the scene live)

    /// Pen speeds while recording: pan in frame-widths/sec, zoom in zoom/sec.
    var cameraPanSpeed: Double
        = UserDefaults.standard.object(forKey: "cameraPanSpeed") as? Double ?? 0.4 {
        didSet { UserDefaults.standard.set(cameraPanSpeed, forKey: "cameraPanSpeed") }
    }
    var cameraZoomSpeed: Double
        = UserDefaults.standard.object(forKey: "cameraZoomSpeed") as? Double ?? 1.2 {
        didSet { UserDefaults.standard.set(cameraZoomSpeed, forKey: "cameraZoomSpeed") }
    }

    /// Preview camera while the Scenes track is selected and paused: arrows,
    /// +/−, and stage drags aim the frame WITHOUT recording; "Set start
    /// position" commits it (mirrors the characters' freeform → commit flow).
    private(set) var cameraFreeform: CameraState?
    var cameraFreeformActive: Bool { cameraFreeform != nil }

    /// The camera the pen starts from: the active cue's camera at the playhead.
    private func currentCueCamera() -> CameraState {
        scene.activeBackgroundCue(at: time)?.camera(at: time) ?? CameraState()
    }

    /// Stage drag while the Scenes track is selected: grab-the-world pan.
    func cameraFreeformDrag(dx: Double, dy: Double) {
        guard scene.backgroundTracks.first?.locked != true else { return }
        var pen = cameraFreeform ?? currentCueCamera()
        pen.x = min(1.5, max(-0.5, pen.x - dx / max(0.1, pen.zoom)))
        pen.y = min(1.5, max(-0.5, pen.y - dy / max(0.1, pen.zoom)))
        cameraFreeform = pen
    }

    /// Saves the previewed framing as the scene cue's camera start.
    func commitCameraStart() {
        guard let pen = cameraFreeform else { return }
        defer { cameraFreeform = nil }
        let id = selectedBackgroundCue ?? scene.activeBackgroundCue(at: time)?.id
        guard let id, !isBackgroundCueLocked(id) else { return }
        registerUndoSnapshot(label: "Set Frame Start")
        for ti in scene.backgroundTracks.indices {
            if let ci = scene.backgroundTracks[ti].cues.firstIndex(where: { $0.id == id }) {
                scene.backgroundTracks[ti].cues[ci].camFrom = pen
                return
            }
        }
    }

    private(set) var cameraRecording = false
    private var cameraSamples: [(t: Double, x: Double, y: Double, zoom: Double)] = []
    /// The camera "pen": arrows pan the focus, +/- zoom, stage drags aim it.
    private var cameraPen: (x: Double, y: Double, zoom: Double) = (0.5, 0.5, 1)
    var isCameraRecording: Bool { cameraRecording }
    var cameraPenNow: (x: Double, y: Double, zoom: Double)? { cameraRecording ? cameraPen : nil }

    func cameraRecordSample(x: Double? = nil, y: Double? = nil) {
        guard cameraRecording else { return }
        if let x { cameraPen.x = min(1.5, max(-0.5, x)) }
        if let y { cameraPen.y = min(1.5, max(-0.5, y)) }
        if let last = cameraSamples.last, time - last.t < 0.15 { return } // ~7Hz
        cameraSamples.append((time, cameraPen.x, cameraPen.y, cameraPen.zoom))
    }

    /// Turns the recorded pen path into camera keyframes on the Scenes track:
    /// cues overlapping the take split into linear from→to pieces (same
    /// punch-in shape as light takes); the piece after the take holds the
    /// final camera.
    private func commitCameraRecording() {
        defer {
            cameraRecording = false
            cameraSamples = []
        }
        guard cameraSamples.count >= 2,
              scene.backgroundTracks.first?.locked == false else { return }
        registerUndoSnapshot(label: "Record Camera")
        // Simplify: drop samples that barely deviate from their neighbours' line.
        var pts = cameraSamples
        var i = 1
        while i < pts.count - 1 {
            let a = pts[i - 1], b = pts[i], c = pts[i + 1]
            let f = (b.t - a.t) / max(0.001, c.t - a.t)
            if abs(a.x + (c.x - a.x) * f - b.x) < 0.008,
               abs(a.y + (c.y - a.y) * f - b.y) < 0.008,
               abs(a.zoom + (c.zoom - a.zoom) * f - b.zoom) < 0.02 {
                pts.remove(at: i)
            } else {
                i += 1
            }
        }
        let t0 = pts[0].t
        let tEnd = pts[pts.count - 1].t
        func cam(at t: Double) -> CameraState {
            if t <= t0 { return CameraState(x: pts[0].x, y: pts[0].y, zoom: pts[0].zoom) }
            for k in 0..<(pts.count - 1) where t < pts[k + 1].t {
                let a = pts[k], b = pts[k + 1]
                let f = (t - a.t) / max(0.001, b.t - a.t)
                return CameraState(x: a.x + (b.x - a.x) * f,
                                   y: a.y + (b.y - a.y) * f,
                                   zoom: a.zoom + (b.zoom - a.zoom) * f)
            }
            let last = pts[pts.count - 1]
            return CameraState(x: last.x, y: last.y, zoom: last.zoom)
        }
        var out: [BackgroundCue] = []
        for cue in scene.backgroundTracks[0].cues {
            let end = cue.start + cue.dur
            if end <= t0 + 0.01 || cue.start >= tEnd - 0.01 {
                out.append(cue)
                continue
            }
            if cue.start < t0 - 0.02 {
                var head = cue
                if head.camTo != nil { head.camTo = cue.camera(at: t0) }
                head.dur = t0 - cue.start
                out.append(head)
            }
            let lo = max(cue.start, t0)
            let hi = min(end, tEnd)
            let bounds = [lo] + pts.map(\.t).filter { $0 > lo + 0.02 && $0 < hi - 0.02 } + [hi]
            for k in 0..<(bounds.count - 1) where bounds[k + 1] - bounds[k] > 0.02 {
                var piece = cue
                piece.id = ShowDocumentFile.newID()
                piece.start = bounds[k]
                piece.dur = bounds[k + 1] - bounds[k]
                piece.camFrom = cam(at: bounds[k])
                piece.camTo = cam(at: bounds[k + 1])
                out.append(piece)
            }
            if end > tEnd + 0.02 {
                var tail = cue
                tail.id = ShowDocumentFile.newID()
                tail.start = tEnd
                tail.dur = end - tEnd
                tail.camFrom = cam(at: tEnd)
                tail.camTo = nil
                out.append(tail)
            }
        }
        scene.backgroundTracks[0].cues = out.sorted { $0.start < $1.start }
        backgroundRevision += 1
    }

    // MARK: - Light path recording ("draw" the light over time)

    private(set) var lightRecordTrack: Int?
    private var lightSamples: [(t: Double, x: Double, y: Double, intensity: Double, size: Double)] = []
    var isLightRecording: Bool { lightRecordTrack != nil }
    var lastLightSample: (t: Double, x: Double, y: Double, intensity: Double, size: Double)? { lightSamples.last }
    var lightPenNow: (x: Double, y: Double, intensity: Double, size: Double)? { isLightRecording ? lightPen : nil }

    /// Keyboard light control: arrows move, +/- change intensity.
    enum LightKey: Hashable {
        case up, down, left, right, plus, minus, sizeDown, sizeUp, rotateLeft, rotateRight
    }
    private(set) var heldLightKeys: Set<LightKey> = []
    /// The "pen": position/intensity the keys steer (recording or nudging).
    private var lightPen: (x: Double, y: Double, intensity: Double, size: Double) = (0.8, 0.18, 1, 120)

    func lightKey(_ key: LightKey, down: Bool) {
        if down {
            if let kind = selectedTrackKind, isTrackLocked(kind) { return }
            if heldLightKeys.isEmpty, selectedVisualCueOnSelectedTrack, !recording, !playing {
                registerUndoSnapshot(label: "Place Visual")
            }
            heldLightKeys.insert(key)
        } else {
            heldLightKeys.remove(key)
        }
    }

    /// 60Hz driver (stage render loop): recording draws with the pen; paused
    /// with a light track selected nudges the current cue directly.
    func lightTick(dt: Double) {
        guard !heldLightKeys.isEmpty else { return }
        let dx = (heldLightKeys.contains(.right) ? 1.0 : 0) - (heldLightKeys.contains(.left) ? 1.0 : 0)
        let dy = (heldLightKeys.contains(.down) ? 1.0 : 0) - (heldLightKeys.contains(.up) ? 1.0 : 0)
        let di = (heldLightKeys.contains(.plus) ? 1.0 : 0) - (heldLightKeys.contains(.minus) ? 1.0 : 0)
        let ds = (heldLightKeys.contains(.sizeUp) ? 1.0 : 0) - (heldLightKeys.contains(.sizeDown) ? 1.0 : 0)
        let dr = (heldLightKeys.contains(.rotateRight) ? 1.0 : 0)
            - (heldLightKeys.contains(.rotateLeft) ? 1.0 : 0)
        if isImageRecording {
            let cue = selectedImageCueValue
            let moveRate = Self.speed(fromUI: cue?.speed ?? ImageCue.defaultSpeed) / 900
            let rotateRate = Self.rotationSpeed(
                fromUI: cue?.rotationSpeed ?? ImageCue.defaultRotationSpeed)
            imagePen.x = min(1.2, max(-0.2, imagePen.x + dx * moveRate * dt))
            imagePen.y = min(1.2, max(-0.2, imagePen.y + dy * moveRate * dt))
            // +/− zooms; shift+arrows rotates like a character.
            imagePen.scale = min(1.2, max(0.05, imagePen.scale + (ds + di) * 0.35 * dt))
            imagePen.rotation += dr * rotateRate * dt
            imageRecordSample(x: imagePen.x, y: imagePen.y)
            return
        }
        // Parked visual cues use the same four performance controls as
        // characters: L/R, F/B, rotate, and zoom. The cue half under the
        // playhead decides whether its start or animated end is adjusted.
        if !playing, selectedVisualCueOnSelectedTrack,
           let current = selectedImageCueValue,
           time >= current.start, time < current.start + current.dur {
            let editEnd = current.to != nil && time > current.start + current.dur / 2
            let moveRate = Self.speed(fromUI: current.speed) / 900
            let rotateRate = Self.rotationSpeed(fromUI: current.rotationSpeed)
            func nudge(_ p: inout ImagePlacement) {
                p.x = min(1.2, max(-0.2, p.x + dx * moveRate * dt))
                p.y = min(1.2, max(-0.2, p.y + dy * moveRate * dt))
                p.scale = min(1.2, max(0.05, p.scale + (ds + di) * 0.35 * dt))
                p.rotation += dr * rotateRate * dt
            }
            updateSelectedImageCue { cue in
                if editEnd, var end = cue.to {
                    nudge(&end)
                    cue.to = end
                } else {
                    nudge(&cue.from)
                }
            }
            return
        }
        if isCameraRecording {
            cameraPen.x = min(1.5, max(-0.5, cameraPen.x + dx * cameraPanSpeed * dt))
            cameraPen.y = min(1.5, max(-0.5, cameraPen.y + dy * cameraPanSpeed * dt))
            cameraPen.zoom = min(4, max(0.5, cameraPen.zoom + di * cameraZoomSpeed * dt))
            cameraRecordSample()
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
        // Paused nudge of the FRAME while the Scenes track is selected: the
        // preview pen moves; "Set start state" commits it.
        if !playing, let key = selectedTrackKey,
           scene.backgroundTracks.contains(where: { $0.id == key && !$0.locked }) {
            var pen = cameraFreeform ?? currentCueCamera()
            pen.x = min(1.5, max(-0.5, pen.x + dx * cameraPanSpeed * dt))
            pen.y = min(1.5, max(-0.5, pen.y + dy * cameraPanSpeed * dt))
            pen.zoom = min(4, max(0.5, pen.zoom + di * cameraZoomSpeed * dt))
            cameraFreeform = pen
            return
        }
        // Paused nudge of the selected/active cue on the selected light track.
        guard !playing, let key = selectedTrackKey,
              let li = scene.lightTracks.firstIndex(where: { $0.id == key }),
              !scene.lightTracks[li].locked,
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
              !scene.lightTracks[li].locked, lightSamples.count >= 2 else { return }
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
        guard file?.isMicRecording != true else { return }
        if let kind = selectedTrackKind, isTrackLocked(kind) { return }
        characterRecordUndoScene = nil
        // A selected image cue records its motion: drag it around as time rolls.
        if let id = selectedImageCue, let owner = selectedImageCueOwner,
           selectedVisualCueOnSelectedTrack {
            guard time >= owner.cue.start, time < owner.cue.start + owner.cue.dur else { return }
            let recordOwner: ImageRecordOwner
            if let index = scene.audioTracks.firstIndex(where: { $0.id == owner.trackID }) {
                recordOwner = .mediaTrack(index)
            } else if let index = scene.imageTracks.firstIndex(where: { $0.id == owner.trackID }) {
                recordOwner = .imageTrack(index)
            } else {
                return
            }
            clearFreeform()
            imageRecordTarget = ImageRecordTarget(owner: recordOwner, cueID: id,
                                                  assetID: owner.cue.assetID)
            imageSamples = []
            let p = owner.cue.placement(at: time)
            imagePen = p
            imageSamples = [(time, p.x, p.y, p.scale, p.rotation)]
            recording = true
            playing = true
            startWall = Date.timeIntervalSinceReferenceDate - time
            file?.audioEngine?.syncPlayback(self)
            return
        }
        // The selected Scenes track records the CAMERA: arrows pan, +/- zoom,
        // stage drags aim the focus.
        if let key = selectedTrackKey,
           scene.backgroundTracks.contains(where: { $0.id == key }) {
            // An uncommitted freeform framing becomes the take's start.
            let cam = cameraFreeform
                ?? scene.activeBackgroundCue(at: time)?.camera(at: time) ?? CameraState()
            clearFreeform()
            cameraRecording = true
            cameraSamples = []
            cameraPen = (cam.x, cam.y, cam.zoom)
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
        let editableSelection = selection.filter {
            scene.characters[safe: $0]?.locked == false
        }
        guard !editableSelection.isEmpty else { return }
        // Character events are written live during a take. Capture the scene
        // before any placement or recStart changes so one Undo removes the
        // complete take and restores the exact pre-recording state.
        characterRecordUndoScene = scene
        // Freeform placement at the start becomes the take's complete start state.
        for i in editableSelection where startStateMismatch(characterIndex: i) {
            if let pose = displayedPose(characterIndex: i) {
                var c = scene.characters[i]
                c.x = pose.x
                c.depth = pose.depth
                c.face = pose.face
                c.size = pose.size
                c.recStart = StartPose(x: pose.x, depth: pose.depth, face: pose.face,
                                       spin: pose.spin, zoom: pose.zoom)
                scene.characters[i] = c
            }
        }
        clearFreeform()
        recTargets = Set(editableSelection)
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
        if isCameraRecording {
            commitCameraRecording()
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
        let undoScene = characterRecordUndoScene
        characterRecordUndoScene = nil
        recording = false
        recTargets = []
        recPunched = [:]
        if let undoScene { registerStageUndo(undoScene, label: "Record") }
    }

    /// Web recEvent: only armed groups; first press of a group replaces that group
    /// from the record point onward (earlier work kept), closing holds that cross it.
    func recordEvent(code: EventCode, down: Bool) {
        guard recording else { return }
        let group = code.group
        let stamp = (time * 1000).rounded() / 1000
        for i in recTargets {
            var c = scene.characters[i]
            guard !c.locked, c.armedGroups.contains(group) else { continue }
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
    /// Latest gravity-scaled landing among synthetic one-shot actions. Resolve
    /// this from the events and current scene gravity so adjusting Gravity
    /// during a preview cannot strand the character partway through a turn.
    private var freeformActionSettleUntil: Double {
        var end = 0.0
        for events in freeformEvents.values {
            for event in events {
                guard case .key(let t, let code, true) = event else { continue }
                let duration: Double?
                switch code {
                case .keyJ:
                    duration = SceneSimulator.jumpDuration(gravity: scene.gravity)
                case .keyF, .keyD:
                    duration = SceneSimulator.flipDuration(gravity: scene.gravity)
                default:
                    duration = nil
                }
                if let duration { end = max(end, t + duration) }
            }
        }
        // Cross the simulator's strict progress < 1 boundary by one frame.
        return end + 1.0 / 60.0
    }

    /// Motion can still be decaying after the keys lift. The general grace
    /// handles turns/resets; one-shot actions remain live through their exact
    /// gravity-scaled landing and recovery.
    var freeformSettling: Bool {
        freeformActive
            && freeformClock < max(freeformLastEvent + 1.5, freeformActionSettleUntil)
    }

    func clearFreeform() {
        freeformEvents = [:]
        freeformStarts = [:]
        freeformClock = 0
        freeformLastEvent = 0
        cameraFreeform = nil
    }

    private func freeformKey(code: EventCode, down: Bool) {
        let targets: Set<Int>
        if scenesTrackSelected, let index = scenePreviewCharacterIndex {
            targets = [index]
        } else {
            targets = selection
        }
        for i in targets where scene.characters.indices.contains(i)
            && !scene.characters[i].locked {
            if freeformStarts[i] == nil {
                let pose = simulator.pose(characterIndex: i, at: time)
                freeformStarts[i] = StartPose(x: pose.x, depth: pose.depth, face: pose.face,
                                              spin: pose.spin, zoom: pose.zoom)
            }
            freeformEvents[i, default: []].append(.key(t: freeformClock, code: code, down: down))
        }
        freeformLastEvent = freeformClock
    }

    /// Advances the freeform clock at 60 Hz (driven by the stage render loop).
    /// Freeform is a PREVIEW: the "Set start state" button (or hitting REC)
    /// commits the complete spatial state shown on stage.
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
        c.reactions = []
        c.recStart = start
        c.subs = []
        let motion = resolvedMotion(characterIndex: i, at: time)
        c.speed = motion.speed
        c.rotationSpeed = motion.rotationSpeed
        c.wobble = basePose.wobble
        c.size = basePose.size
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

    /// True when the character on stage differs from its saved start transform.
    func startStateMismatch(characterIndex i: Int) -> Bool {
        guard freeformActive, time < 0.1, scene.characters.indices.contains(i),
              let pose = displayedPose(characterIndex: i) else { return false }
        let c = scene.characters[i]
        let start = c.recStart ?? StartPose(x: c.x, depth: c.depth, face: c.face)
        return abs(pose.x - start.x) > 0.005 || abs(pose.depth - start.depth) > 0.02
            || pose.face != start.face || abs(pose.spin - start.spin) > 0.05
            || abs(pose.zoom - start.zoom) > 0.002 || abs(pose.size - c.size) > 0.002
    }

    /// Saves the complete spatial state shown on stage as the character's start.
    func commitStartState(characterIndex i: Int) {
        guard scene.characters.indices.contains(i),
              !scene.characters[i].locked,
              let pose = displayedPose(characterIndex: i) else { return }
        registerUndoSnapshot(label: "Set Start State")
        var c = scene.characters[i]
        c.x = pose.x
        c.depth = pose.depth
        c.face = pose.face
        c.size = pose.size
        c.recStart = StartPose(x: pose.x, depth: pose.depth, face: pose.face,
                               spin: pose.spin, zoom: pose.zoom)
        scene.characters[i] = c
        clearFreeform()
    }

    // MARK: - Characters

    // UI-facing 1–10 motion scale; documents keep the web simulation units
    // (speed 40–600, wobble 0–16) so playback math and old shows are untouched.
    static func uiSpeed(_ speed: Double) -> Double { 1 + (speed - 40) / 560 * 9 }
    static func speed(fromUI ui: Double) -> Double { 40 + (ui - 1) / 9 * 560 }
    static func uiRotationSpeed(_ degreesPerSecond: Double) -> Double {
        uiSpeed(degreesPerSecond * 320 / 90)
    }
    static func rotationSpeed(fromUI ui: Double) -> Double {
        speed(fromUI: ui) / 320 * 90
    }
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
        guard !isTrackLocked(kind) else { return }
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
            for ri in c.reactions.indices { c.reactions[ri].id = ShowDocumentFile.newID() }
            scene.characters.append(c)
        case .audio(let i):
            guard var t = scene.audioTracks[safe: i] else { return }
            t.id = ShowDocumentFile.newID()
            t.name += " copy"
            t.clips = cloneClips(t.clips)
            for ci in t.cues.indices { t.cues[ci].id = ShowDocumentFile.newID() }
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
        guard file?.isMicRecording != true,
              scene.characters.indices.contains(index),
              !scene.characters[index].locked else { return }
        registerUndoSnapshot(label: "Remove Character")
        scene.characters.remove(at: index)
        selectedReaction = nil
        selectedMouthCue = nil
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
        guard scene.characters.indices.contains(characterIndex),
              !scene.characters[characterIndex].locked else { return }
        registerUndoSnapshot(label: "Outfit")
        var c = scene.characters[characterIndex]
        if let name { c.baseOutfit[slot] = name } else { c.baseOutfit.removeValue(forKey: slot) }
        scene.characters[characterIndex] = c
    }

    /// Timed wardrobe change at an explicit time (the lane's wardrobe strip).
    func setOutfitEvent(characterIndex: Int, slot: Int, name: String?, at t: Double) {
        guard scene.characters.indices.contains(characterIndex),
              !scene.characters[characterIndex].locked else { return }
        registerUndoSnapshot(label: "Outfit Change")
        var c = scene.characters[characterIndex]
        let ev = PerfEvent.outfit(t: t, slot: slot, name: name)
        let insertAt = c.events.firstIndex { $0.t > t } ?? c.events.count
        c.events.insert(ev, at: insertAt)
        scene.characters[characterIndex] = c
    }

    func setOutfit(characterIndex: Int, slot: Int, name: String?) {
        guard scene.characters.indices.contains(characterIndex),
              !scene.characters[characterIndex].locked else { return }
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
        guard scene.imageTracks.indices.contains(trackIndex),
              !scene.imageTracks[trackIndex].locked else { return }
        registerUndoSnapshot(label: "Add Visual Cue")
        let cue = ImageCue(id: ShowDocumentFile.newID(), assetID: assetID,
                           start: t, dur: 5, from: ImagePlacement())
        scene.imageTracks[trackIndex].cues.append(cue)
        scene.imageTracks[trackIndex].cues.sort { $0.start < $1.start }
        selectedTrackKey = scene.imageTracks[trackIndex].id
        selectedImageCue = cue.id
    }

    func addImageTrack(assetID: String, assetName: String) {
        registerUndoSnapshot(label: "Add Visual Track")
        let cue = ImageCue(id: ShowDocumentFile.newID(), assetID: assetID,
                           start: time, dur: 5, from: ImagePlacement())
        let track = ImageTrack(id: ShowDocumentFile.newID(), name: assetName, cues: [cue])
        scene.imageTracks.append(track)
        selectedTrackKey = track.id
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
              !scene.lightTracks[track].locked,
              let ci = scene.lightTracks[track].cues.firstIndex(where: { $0.id == id }) else { return }
        scene.lightTracks[track].cues[ci].start = start
    }

    /// ⌘-drag on a chain: clone the whole run in place; returns the copies' ids.
    func duplicateLightRun(
        track: Int,
        containing id: String,
        registerUndo: Bool = true
    ) -> [String]? {
        guard scene.lightTracks.indices.contains(track),
              !scene.lightTracks[track].locked else { return nil }
        let run = Self.lightRun(in: scene.lightTracks[track].cues, containing: id)
        guard !run.isEmpty else { return nil }
        if registerUndo {
            registerUndoSnapshot(label: "Duplicate Light Take")
        }
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
            guard !scene.lightTracks[ti].locked else { return }
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
        guard !isImageCueLocked(id) else { return }
        func split(_ cues: inout [ImageCue]) -> Bool {
            guard let ci = cues.firstIndex(where: { $0.id == id }) else { return false }
            var first = cues[ci]
            guard t > first.start + 0.1, t < first.start + first.dur - 0.1 else { return true }
            registerUndoSnapshot(label: "Split Image")
            let mid = first.placement(at: t)
            var second = first
            second.id = ShowDocumentFile.newID()
            second.playback = first.continuedPlayback(at: t)
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
            guard !scene.backgroundTracks[ti].locked else { return }
            var first = scene.backgroundTracks[ti].cues[ci]
            guard t > first.start + 0.1, t < first.start + first.dur - 0.1 else { return }
            registerUndoSnapshot(label: "Split Background")
            let midCam = first.camera(at: t)
            var second = first
            second.id = ShowDocumentFile.newID()
            second.start = t
            second.dur = first.start + first.dur - t
            first.dur = t - first.start
            // An animated camera keeps its ramp by meeting at the split point.
            if first.camTo != nil {
                first.camTo = midCam
                second.camFrom = midCam
            }
            scene.backgroundTracks[ti].cues[ci] = first
            scene.backgroundTracks[ti].cues.insert(second, at: ci + 1)
            selectedBackgroundCue = second.id
            return
        }
    }

    func addBackgroundCue(assetID: String, assetName: String, at startTime: Double? = nil) {
        let time = startTime ?? self.time
        let createsTrack = scene.backgroundTracks.isEmpty
        guard createsTrack || !scene.backgroundTracks[0].locked else { return }
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
        guard file?.isMicRecording != true, !isTrackLocked(row) else { return }
        registerUndoSnapshot(label: "Delete Track")
        switch row {
        case .character(let i):
            guard scene.characters.indices.contains(i) else { return }
            scene.characters.remove(at: i)
            selection = scene.characters.isEmpty ? [] : [min(i, scene.characters.count - 1)]
            selectedMarks = []
            selectedReaction = nil
            selectedMouthCue = nil
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
        guard scene.lightTracks.indices.contains(trackIndex),
              !scene.lightTracks[trackIndex].locked else { return }
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

    // MARK: - Production structure and track safety

    /// Adds a named navigation point or a span. Sections default to the marked
    /// export range when it contains the playhead, otherwise a useful 5 seconds.
    @discardableResult
    func addTimelineMarker(kind: TimelineMarker.Kind, at requestedTime: Double? = nil) -> String {
        let start = max(0, requestedTime ?? time)
        let number = scene.markers.filter { $0.kind == kind }.count + 1
        let name = kind == .section ? "Section \(number)" : "Marker \(number)"
        let duration: Double
        if kind == .section, let range = exportRange, start >= range.from, start < range.to {
            duration = max(0.1, range.to - start)
        } else {
            duration = kind == .section ? 5 : 0
        }
        let marker = TimelineMarker(id: ShowDocumentFile.newID(), name: name, start: start,
                                    kind: kind, duration: duration,
                                    color: kind == .section ? .blue : .orange)
        registerUndoSnapshot(label: kind == .section ? "Add Section" : "Add Marker")
        scene.markers.append(marker)
        scene.markers.sort { $0.start < $1.start }
        return marker.id
    }

    func updateTimelineMarker(id: String, _ transform: (inout TimelineMarker) -> Void) {
        guard let index = scene.markers.firstIndex(where: { $0.id == id }) else { return }
        transform(&scene.markers[index])
        scene.markers[index].start = max(0, scene.markers[index].start)
        scene.markers[index].duration = scene.markers[index].kind == .section
            ? max(0.1, scene.markers[index].duration) : 0
        scene.markers.sort { $0.start < $1.start }
    }

    func deleteTimelineMarker(id: String) {
        guard scene.markers.contains(where: { $0.id == id }) else { return }
        registerUndoSnapshot(label: "Delete Marker")
        scene.markers.removeAll { $0.id == id }
    }

    func isTrackLocked(_ kind: TrackRowKind) -> Bool {
        switch kind {
        case .character(let i): return scene.characters[safe: i]?.locked ?? false
        case .audio(let i): return scene.audioTracks[safe: i]?.locked ?? false
        case .image(let i): return scene.imageTracks[safe: i]?.locked ?? false
        case .light(let i): return scene.lightTracks[safe: i]?.locked ?? false
        case .background(let i): return scene.backgroundTracks[safe: i]?.locked ?? false
        }
    }

    func toggleTrackLock(_ kind: TrackRowKind) {
        guard !recording, file?.isMicRecording != true else { return }
        switch kind {
        case .character(let i):
            guard scene.characters.indices.contains(i) else { return }
            registerUndoSnapshot(label: scene.characters[i].locked ? "Unlock Track" : "Lock Track")
            scene.characters[i].locked.toggle()
        case .audio(let i):
            guard scene.audioTracks.indices.contains(i) else { return }
            registerUndoSnapshot(label: scene.audioTracks[i].locked ? "Unlock Track" : "Lock Track")
            scene.audioTracks[i].locked.toggle()
        case .image(let i):
            guard scene.imageTracks.indices.contains(i) else { return }
            registerUndoSnapshot(label: scene.imageTracks[i].locked ? "Unlock Track" : "Lock Track")
            scene.imageTracks[i].locked.toggle()
        case .light(let i):
            guard scene.lightTracks.indices.contains(i) else { return }
            registerUndoSnapshot(label: scene.lightTracks[i].locked ? "Unlock Track" : "Lock Track")
            scene.lightTracks[i].locked.toggle()
        case .background(let i):
            guard scene.backgroundTracks.indices.contains(i) else { return }
            registerUndoSnapshot(label: scene.backgroundTracks[i].locked ? "Unlock Track" : "Lock Track")
            scene.backgroundTracks[i].locked.toggle()
        }
    }

    func isTrackSoloed(_ kind: TrackRowKind) -> Bool {
        switch kind {
        case .character(let i): return scene.characters[safe: i]?.solo ?? false
        case .audio(let i): return scene.audioTracks[safe: i]?.solo ?? false
        default: return false
        }
    }

    func toggleTrackSolo(_ kind: TrackRowKind) {
        switch kind {
        case .character(let i):
            guard scene.characters.indices.contains(i) else { return }
            registerUndoSnapshot(label: scene.characters[i].solo ? "Unsolo Track" : "Solo Track")
            scene.characters[i].solo.toggle()
        case .audio(let i):
            guard scene.audioTracks.indices.contains(i) else { return }
            registerUndoSnapshot(label: scene.audioTracks[i].solo ? "Unsolo Track" : "Solo Track")
            scene.audioTracks[i].solo.toggle()
        default:
            return
        }
        resyncAudioIfPlaying()
    }

    func isClipLocked(_ id: String) -> Bool {
        for character in scene.characters where character.clips.contains(where: { $0.id == id }) {
            return character.locked
        }
        for track in scene.audioTracks where track.clips.contains(where: { $0.id == id }) {
            return track.locked
        }
        return false
    }

    func isImageCueLocked(_ id: String) -> Bool {
        for track in scene.imageTracks where track.cues.contains(where: { $0.id == id }) {
            return track.locked
        }
        for track in scene.audioTracks where track.cues.contains(where: { $0.id == id }) {
            return track.locked
        }
        return false
    }

    func isBackgroundCueLocked(_ id: String) -> Bool {
        scene.backgroundTracks.contains {
            $0.locked && $0.cues.contains(where: { $0.id == id })
        }
    }

    func isLightCueLocked(_ id: String) -> Bool {
        scene.lightTracks.contains {
            $0.locked && $0.cues.contains(where: { $0.id == id })
        }
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

    /// Applies a validated raw character edit as one ordinary timeline edit.
    func applyAdvancedJSON(character: Character, at index: Int) {
        guard file?.isMicRecording != true,
              scene.characters.indices.contains(index),
              !scene.characters[index].locked else { return }
        pause()
        registerUndoSnapshot(label: "Edit Character JSON")
        scene.characters[index] = character
        clearSelectionAfterJSONEdit(preferredCharacter: index)
    }

    /// Applies a validated complete show document. Unlike normal editor undo,
    /// this snapshot includes assets, export range, and settings as well as the
    /// stage because all of them are exposed by the full-show JSON scope.
    func applyAdvancedJSON(document newDocument: ShowDocument,
                           preferredCharacter: Int) {
        guard file?.isMicRecording != true else { return }
        pause()
        registerDocumentUndoSnapshot(label: "Edit Show JSON",
                                     preferredCharacter: preferredCharacter)
        restoreDocument(DocumentUndoSnapshot(document: newDocument, time: time,
                                             preferredCharacter: preferredCharacter))
    }

    /// Restores a named project checkpoint as one undoable document operation.
    func restoreCheckpoint(_ checkpoint: ShowCheckpoint) {
        guard file?.isMicRecording != true else { return }
        pause()
        registerDocumentUndoSnapshot(label: "Restore Checkpoint",
                                     preferredCharacter: selection.first ?? 0)
        var restored = checkpoint.document
        if restored.version < 4 { restored.version = 4 }
        restoreDocument(DocumentUndoSnapshot(document: restored, time: checkpoint.time,
                                             preferredCharacter: selection.first ?? 0))
    }

    private func clearSelectionAfterJSONEdit(preferredCharacter: Int) {
        selectedMarks = []
        selectedClips = []
        selectedImageCue = nil
        selectedBackgroundCue = nil
        selectedBackgroundCues = []
        selectedOutfitEvent = nil
        selectedMotionEvent = nil
        selectedReaction = nil
        selectedMouthCue = nil
        selectedLightCue = nil
        clearFreeform()
        if scene.characters.isEmpty {
            selection = []
            selectedTrackKey = scene.backgroundTracks.first?.id
        } else {
            let index = min(max(0, preferredCharacter), scene.characters.count - 1)
            selection = [index]
            selectedTrackKey = "c-\(index)"
        }
    }

    private struct DocumentUndoSnapshot {
        let document: ShowDocument
        let time: Double
        let preferredCharacter: Int
    }

    private func registerDocumentUndoSnapshot(label: String, preferredCharacter: Int) {
        let snapshot = DocumentUndoSnapshot(
            document: document,
            time: time,
            preferredCharacter: selection.first ?? preferredCharacter)
        registerDocumentUndo(snapshot, label: label)
    }

    /// Undo and redo use the same transition, so repeated undo/redo cycles keep
    /// working and always reconcile editor selection, time, rendering, and audio.
    private func registerDocumentUndo(_ snapshot: DocumentUndoSnapshot, label: String) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let inverse = DocumentUndoSnapshot(
                    document: model.document,
                    time: model.time,
                    preferredCharacter: model.selection.first ?? snapshot.preferredCharacter)
                model.restoreDocument(snapshot)
                model.registerDocumentUndo(inverse, label: label)
            }
        }
        undoManager?.setActionName(label)
    }

    private func restoreDocument(_ snapshot: DocumentUndoSnapshot) {
        document = snapshot.document
        backgroundRevision += 1
        clearSelectionAfterJSONEdit(preferredCharacter: snapshot.preferredCharacter)
        time = min(max(0, snapshot.time), duration)
        file?.audioEngine?.syncPlayback(self)
    }

    /// Stage snapshot undo (the whole timeline state).
    func registerUndoSnapshot(label: String) {
        registerStageUndo(document.stage, label: label)
    }

    /// Registers a snapshot captured before a continuous gesture. Drag
    /// handlers apply live values first, so they must preserve their initial
    /// state explicitly rather than accidentally registering the final state.
    func registerUndoSnapshot(_ snapshot: SceneState, label: String) {
        registerStageUndo(snapshot, label: label)
    }

    private func registerStageUndo(_ snapshot: SceneState, label: String) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let inverse = model.document.stage
                model.document.stage = snapshot
                model.backgroundRevision += 1
                model.file?.audioEngine?.syncPlayback(model)
                model.registerStageUndo(inverse, label: label)
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
