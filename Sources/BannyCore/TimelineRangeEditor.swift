import Foundation

/// A concrete timeline row addressed without depending on Studio's UI types.
public enum TimelineTrackTarget: Hashable, Sendable {
    case character(Int)
    case audio(Int)
    case image(Int)
    case light(Int)
    case background(Int)
}

public enum TimelineRangeOperation: Sendable {
    /// Retain only the portions of clip-based content that overlap the range.
    case keep
    /// Remove the portions inside the range, splitting spanning content.
    case remove
}

public struct TimelineAudioClone: Equatable, Sendable {
    public let sourceID: String
    public let cloneID: String

    public init(sourceID: String, cloneID: String) {
        self.sourceID = sourceID
        self.cloneID = cloneID
    }
}

public struct TimelineRangeEditResult: Equatable, Sendable {
    /// Split audio pieces need the same package media bytes under a new clip id.
    public var audioClones: [TimelineAudioClone]
    public var changed: Bool

    public init(audioClones: [TimelineAudioClone] = [], changed: Bool = false) {
        self.audioClones = audioClones
        self.changed = changed
    }
}

/// Non-ripple range editing for every clip-shaped timeline object. Key
/// performance, reaction, marker, and visibility automation is intentionally
/// outside this editor: range commands must not approximate stateful motion.
public enum TimelineRangeEditor {
    private static let minimumDuration = 0.001

    @discardableResult
    public static func apply(
        _ operation: TimelineRangeOperation,
        from rawFrom: Double,
        to rawTo: Double,
        targets: Set<TimelineTrackTarget>,
        scene: inout SceneState,
        makeID: () -> String
    ) -> TimelineRangeEditResult {
        let from = max(0, min(rawFrom, rawTo))
        let to = max(rawFrom, rawTo)
        guard to - from >= minimumDuration, !targets.isEmpty else {
            return TimelineRangeEditResult()
        }

        let before = scene
        var audioClones: [TimelineAudioClone] = []
        for target in targets {
            switch target {
            case .character(let index):
                guard scene.characters.indices.contains(index),
                      !scene.characters[index].locked else { continue }
                let edited = editAudioClips(
                    scene.characters[index].clips,
                    operation: operation,
                    from: from,
                    to: to,
                    makeID: makeID)
                scene.characters[index].clips = edited.clips
                scene.characters[index].subs = editSubtitles(
                    scene.characters[index].subs,
                    operation: operation,
                    from: from,
                    to: to)
                audioClones += edited.clones

            case .audio(let index):
                guard scene.audioTracks.indices.contains(index),
                      !scene.audioTracks[index].locked else { continue }
                let edited = editAudioClips(
                    scene.audioTracks[index].clips,
                    operation: operation,
                    from: from,
                    to: to,
                    makeID: makeID)
                scene.audioTracks[index].clips = edited.clips
                scene.audioTracks[index].cues = editImageCues(
                    scene.audioTracks[index].cues,
                    operation: operation,
                    from: from,
                    to: to,
                    makeID: makeID)
                audioClones += edited.clones

            case .image(let index):
                guard scene.imageTracks.indices.contains(index),
                      !scene.imageTracks[index].locked else { continue }
                scene.imageTracks[index].cues = editImageCues(
                    scene.imageTracks[index].cues,
                    operation: operation,
                    from: from,
                    to: to,
                    makeID: makeID)

            case .light(let index):
                guard scene.lightTracks.indices.contains(index),
                      !scene.lightTracks[index].locked else { continue }
                scene.lightTracks[index].cues = editLightCues(
                    scene.lightTracks[index].cues,
                    operation: operation,
                    from: from,
                    to: to,
                    makeID: makeID)

            case .background(let index):
                guard scene.backgroundTracks.indices.contains(index),
                      !scene.backgroundTracks[index].locked else { continue }
                scene.backgroundTracks[index].cues = editBackgroundCues(
                    scene.backgroundTracks[index].cues,
                    operation: operation,
                    from: from,
                    to: to,
                    makeID: makeID)
            }
        }
        return TimelineRangeEditResult(audioClones: audioClones, changed: scene != before)
    }

    private static func portions(
        start: Double,
        duration: Double,
        operation: TimelineRangeOperation,
        from: Double,
        to: Double
    ) -> [(start: Double, end: Double)] {
        let end = start + max(0, duration)
        guard end - start >= minimumDuration else { return [] }
        switch operation {
        case .keep:
            let keptStart = max(start, from)
            let keptEnd = min(end, to)
            return keptEnd - keptStart >= minimumDuration
                ? [(keptStart, keptEnd)] : []
        case .remove:
            if end <= from || start >= to { return [(start, end)] }
            var result: [(Double, Double)] = []
            if from - start >= minimumDuration { result.append((start, min(from, end))) }
            if end - to >= minimumDuration { result.append((max(to, start), end)) }
            return result
        }
    }

    private static func editAudioClips(
        _ clips: [AudioClip],
        operation: TimelineRangeOperation,
        from: Double,
        to: Double,
        makeID: () -> String
    ) -> (clips: [AudioClip], clones: [TimelineAudioClone]) {
        var result: [AudioClip] = []
        var clones: [TimelineAudioClone] = []
        for source in clips {
            let slices = portions(start: source.start, duration: source.dur,
                                  operation: operation, from: from, to: to)
            for (sliceIndex, slice) in slices.enumerated() {
                var clip = source
                if sliceIndex > 0 {
                    clip.id = makeID()
                    clones.append(TimelineAudioClone(sourceID: source.id, cloneID: clip.id))
                }
                let sourceEnd = source.start + source.dur
                clip.start = slice.start
                clip.offset = source.offset + slice.start - source.start
                clip.dur = slice.end - slice.start
                if slice.start > source.start + minimumDuration { clip.fadeIn = 0 }
                if slice.end < sourceEnd - minimumDuration { clip.fadeOut = 0 }
                clip.fadeIn = min(clip.fadeIn, clip.dur)
                clip.fadeOut = min(clip.fadeOut, clip.dur)
                result.append(clip)
            }
        }
        return (result.sorted { $0.start < $1.start }, clones)
    }

    private static func editSubtitles(
        _ subtitles: [Subtitle],
        operation: TimelineRangeOperation,
        from: Double,
        to: Double
    ) -> [Subtitle] {
        subtitles.flatMap { source in
            portions(start: source.start, duration: source.dur,
                     operation: operation, from: from, to: to).map { slice in
                var subtitle = source
                subtitle.start = slice.start
                subtitle.dur = slice.end - slice.start
                return subtitle
            }
        }
        .sorted { $0.start < $1.start }
    }

    private static func editImageCues(
        _ cues: [ImageCue],
        operation: TimelineRangeOperation,
        from: Double,
        to: Double,
        makeID: () -> String
    ) -> [ImageCue] {
        cues.flatMap { source in
            portions(start: source.start, duration: source.dur,
                     operation: operation, from: from, to: to)
                .enumerated().map { sliceIndex, slice in
                    var cue = source
                    if sliceIndex > 0 { cue.id = makeID() }
                    cue.playback = source.continuedPlayback(at: slice.start)
                    cue.from = source.placement(at: slice.start)
                    cue.to = source.to == nil ? nil : source.placement(at: slice.end)
                    cue.start = slice.start
                    cue.dur = slice.end - slice.start
                    return cue
                }
        }
        .sorted { $0.start < $1.start }
    }

    private static func editLightCues(
        _ cues: [LightCue],
        operation: TimelineRangeOperation,
        from: Double,
        to: Double,
        makeID: () -> String
    ) -> [LightCue] {
        cues.flatMap { source in
            portions(start: source.start, duration: source.dur,
                     operation: operation, from: from, to: to)
                .enumerated().map { sliceIndex, slice in
                    var cue = source
                    if sliceIndex > 0 { cue.id = makeID() }
                    cue.from = source.state(at: slice.start)
                    cue.to = source.to == nil ? nil : source.state(at: slice.end)
                    cue.start = slice.start
                    cue.dur = slice.end - slice.start
                    return cue
                }
        }
        .sorted { $0.start < $1.start }
    }

    private static func editBackgroundCues(
        _ cues: [BackgroundCue],
        operation: TimelineRangeOperation,
        from: Double,
        to: Double,
        makeID: () -> String
    ) -> [BackgroundCue] {
        cues.flatMap { source in
            portions(start: source.start, duration: source.dur,
                     operation: operation, from: from, to: to)
                .enumerated().map { sliceIndex, slice in
                    var cue = source
                    if sliceIndex > 0 { cue.id = makeID() }
                    cue.camFrom = source.camera(at: slice.start)
                    cue.camTo = source.camTo == nil ? nil : source.camera(at: slice.end)
                    cue.start = slice.start
                    cue.dur = slice.end - slice.start
                    return cue
                }
        }
        .sorted { $0.start < $1.start }
    }
}
