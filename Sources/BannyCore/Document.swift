import Foundation

/// Banny Studio document model, schema v2.
/// Concepts map 1:1 to the web v1 studio; see docs/superpowers/specs/2026-07-07-banny-studio-native-design.md.

public struct ShowDocument: Equatable, Sendable {
    public var version: Int
    /// The single stage/timeline. (v3 replaced the old scenes array.)
    public var stage: SceneState
    /// Reusable image/video assets ("the set").
    public var assets: [Asset]
    public var show: [ShowSegment]
    public var settings: Settings

    public init(version: Int = 3, stage: SceneState = SceneState(), assets: [Asset] = [],
                show: [ShowSegment] = [], settings: Settings = Settings()) {
        self.version = version
        self.stage = stage
        self.assets = assets
        self.show = show
        self.settings = settings
    }
}

extension ShowDocument: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, stage, assets, show, settings, scenes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        if version >= 3 {
            self.version = version
            self.stage = try c.decode(SceneState.self, forKey: .stage)
            self.assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
            self.show = try c.decodeIfPresent([ShowSegment].self, forKey: .show) ?? []
            self.settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        } else {
            // v2: scenes array → concatenate onto one timeline.
            let scenes = try c.decodeIfPresent([Scene].self, forKey: .scenes) ?? []
            let show = try c.decodeIfPresent([ShowSegment].self, forKey: .show) ?? []
            let settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
            self = ShowDocument.migrateScenes(scenes, show: show, settings: settings)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(stage, forKey: .stage)
        try c.encode(assets, forKey: .assets)
        try c.encode(show, forKey: .show)
        try c.encode(settings, forKey: .settings)
    }

    /// Lays v1/v2 scenes out back-to-back on the single v3 timeline. Scene
    /// backgrounds become cues on one Background track; their media files
    /// (previously bg/<sceneID>.<ext>) become bank assets keyed by scene id.
    public static func migrateScenes(_ scenes: [Scene], show: [ShowSegment],
                                     settings: Settings) -> ShowDocument {
        var stage = SceneState()
        var assets: [Asset] = []
        var bgCues: [BackgroundCue] = []
        var offsets: [String: Double] = [:]
        var cursor = 0.0

        for scene in scenes {
            let state = scene.state
            offsets[scene.id] = cursor
            let sceneEnd = max(1, state.contentEnd) + 0.5

            func shifted(_ character: Character) -> Character {
                var c = character
                c.events = c.events.map { $0.shifted(by: cursor) }
                c.clips = c.clips.map { var k = $0; k.start += cursor; return k }
                c.subs = c.subs.map { var s = $0; s.start += cursor; return s }
                return c
            }
            stage.characters.append(contentsOf: state.characters.map(shifted))
            for track in state.audioTracks {
                var t = track
                t.clips = t.clips.map { var k = $0; k.start += cursor; return k }
                stage.audioTracks.append(t)
            }
            stage.cropAnchors.append(contentsOf: state.cropAnchors.map { $0 + cursor })
            if stage.lights.isEmpty { stage.lights = state.lights }
            if scenes.first?.id == scene.id {
                stage.gScale = state.gScale
                stage.gravity = state.gravity
                stage.gSize = state.gSize
            }
            if let bg = state.background {
                let (file, crop, kind): (String, Crop, Asset.Kind)
                switch bg {
                case .image(let f, let c): (file, crop, kind) = (f, c, .image)
                case .video(let f, let c): (file, crop, kind) = (f, c, .video)
                }
                if !assets.contains(where: { $0.id == scene.id }) {
                    assets.append(Asset(id: scene.id, name: scene.name, kind: kind, file: file))
                }
                bgCues.append(BackgroundCue(id: scene.id + "-bg", assetID: scene.id,
                                            start: cursor, dur: sceneEnd, crop: crop))
            }
            cursor += sceneEnd
        }
        if !bgCues.isEmpty {
            stage.backgroundTracks = [BackgroundTrack(id: "bgtrack", name: "Backgrounds", cues: bgCues)]
        }
        let migratedShow = show.compactMap { seg -> ShowSegment? in
            guard let off = offsets[seg.sceneID] else { return nil }
            return ShowSegment(sceneID: "", name: seg.name, from: seg.from + off, to: seg.to + off)
        }
        return ShowDocument(stage: stage, assets: assets, show: migratedShow,
                            settings: Settings(activeScene: 0, lightSize: settings.lightSize))
    }
}

/// A reusable set asset (image or video) stored in the package's assets/ folder.
public struct Asset: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, video }
    public var id: String
    public var name: String
    public var kind: Kind
    /// File name inside the package assets/ folder.
    public var file: String

    public init(id: String, name: String, kind: Kind, file: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.file = file
    }
}

/// A non-character image on stage: placed, sized, optionally moving over time.
public struct ImageTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var hidden: Bool
    public var cues: [ImageCue]

    public init(id: String, name: String, hidden: Bool = false, cues: [ImageCue] = []) {
        self.id = id
        self.name = name
        self.hidden = hidden
        self.cues = cues
    }

    private enum CodingKeys: String, CodingKey { case id, name, hidden, cues }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        cues = try c.decodeIfPresent([ImageCue].self, forKey: .cues) ?? []
    }
}

public struct ImageCue: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var assetID: String
    public var start: Double
    public var dur: Double
    /// Placement at cue start.
    public var from: ImagePlacement
    /// Placement at cue end; nil = static. Linear interpolation between.
    public var to: ImagePlacement?
    /// Display label; nil falls back to the asset's name.
    public var label: String?

    public init(id: String, assetID: String, start: Double, dur: Double,
                from: ImagePlacement, to: ImagePlacement? = nil, label: String? = nil) {
        self.id = id
        self.assetID = assetID
        self.start = start
        self.dur = dur
        self.from = from
        self.to = to
        self.label = label
    }

    /// Interpolated placement at absolute time t (clamped to the cue).
    public func placement(at t: Double) -> ImagePlacement {
        guard let to, dur > 0 else { return from }
        let k = min(1, max(0, (t - start) / dur))
        return ImagePlacement(x: from.x + (to.x - from.x) * k,
                              y: from.y + (to.y - from.y) * k,
                              scale: from.scale + (to.scale - from.scale) * k)
    }
}

/// Center position (fractions of stage width/height) + width as a fraction of stage width.
public struct ImagePlacement: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var scale: Double

    public init(x: Double = 0.5, y: Double = 0.5, scale: Double = 0.3) {
        self.x = x
        self.y = y
        self.scale = scale
    }
}

/// Full-screen backdrop cues; the active cue at t paints the background.
public struct BackgroundTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var hidden: Bool
    public var cues: [BackgroundCue]

    public init(id: String, name: String, hidden: Bool = false, cues: [BackgroundCue] = []) {
        self.id = id
        self.name = name
        self.hidden = hidden
        self.cues = cues
    }

    private enum CodingKeys: String, CodingKey { case id, name, hidden, cues }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        cues = try c.decodeIfPresent([BackgroundCue].self, forKey: .cues) ?? []
    }
}

public struct BackgroundCue: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var assetID: String
    public var start: Double
    public var dur: Double
    public var crop: Crop
    /// Display label; nil falls back to the asset's name.
    public var label: String?

    public init(id: String, assetID: String, start: Double, dur: Double, crop: Crop = .cover,
                label: String? = nil) {
        self.id = id
        self.assetID = assetID
        self.start = start
        self.dur = dur
        self.crop = crop
        self.label = label
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var activeScene: Int
    public var lightSize: Double

    public init(activeScene: Int = 0, lightSize: Double = 0) {
        self.activeScene = activeScene
        self.lightSize = lightSize
    }
}

public struct Scene: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var state: SceneState

    public init(id: String, name: String, state: SceneState) {
        self.id = id
        self.name = name
        self.state = state
    }
}

/// A show playlist segment: a time slice of the timeline.
public struct ShowSegment: Codable, Equatable, Sendable {
    /// v2 legacy scene reference; empty on v3 documents.
    public var sceneID: String
    public var name: String
    public var from: Double
    public var to: Double

    public init(sceneID: String = "", name: String, from: Double, to: Double) {
        self.sceneID = sceneID
        self.name = name
        self.from = from
        self.to = to
    }

    private enum CodingKeys: String, CodingKey { case sceneID, name, from, to }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sceneID = try c.decodeIfPresent(String.self, forKey: .sceneID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        from = try c.decode(Double.self, forKey: .from)
        to = try c.decode(Double.self, forKey: .to)
    }
}

public struct SceneState: Equatable, Sendable {
    public var characters: [Character]
    public var audioTracks: [AudioTrack]
    public var imageTracks: [ImageTrack]
    public var backgroundTracks: [BackgroundTrack]
    public var lights: [Light]
    /// Crop anchor times (seconds) that split the timeline into Show segments.
    public var cropAnchors: [Double]
    /// Depth→scale intensity (web slider 0..1.2).
    public var gScale: Double
    /// Jump gravity (0.3..2.5).
    public var gravity: Double
    /// Base size multiplier (0.3..2.5).
    public var gSize: Double
    /// v2 per-scene background (decode-only; migration turns it into a cue).
    public var background: BackgroundSpec?

    public init(characters: [Character] = [], audioTracks: [AudioTrack] = [],
                imageTracks: [ImageTrack] = [], backgroundTracks: [BackgroundTrack] = [],
                lights: [Light] = [], cropAnchors: [Double] = [],
                gScale: Double = 0.6, gravity: Double = 1, gSize: Double = 1,
                background: BackgroundSpec? = nil) {
        self.characters = characters
        self.audioTracks = audioTracks
        self.imageTracks = imageTracks
        self.backgroundTracks = backgroundTracks
        self.lights = lights
        self.cropAnchors = cropAnchors
        self.gScale = gScale
        self.gravity = gravity
        self.gSize = gSize
        self.background = background
    }

    /// End of the last event/clip/caption/cue (web tlDurNeeded's content part).
    public var contentEnd: Double {
        var end = 0.0
        for c in characters {
            end = max(end, c.events.last?.t ?? 0)
            for clip in c.clips { end = max(end, clip.start + clip.dur) }
            for s in c.subs { end = max(end, s.start + s.dur) }
        }
        for t in audioTracks {
            for clip in t.clips { end = max(end, clip.start + clip.dur) }
        }
        for t in imageTracks {
            for cue in t.cues { end = max(end, cue.start + cue.dur) }
        }
        for t in backgroundTracks {
            for cue in t.cues { end = max(end, cue.start + cue.dur) }
        }
        return end
    }

    /// The backdrop to paint at time t: last visible background track's active cue wins.
    public func activeBackgroundCue(at t: Double) -> BackgroundCue? {
        for track in backgroundTracks.reversed() where !track.hidden {
            if let cue = track.cues.last(where: { t >= $0.start && t < $0.start + $0.dur }) {
                return cue
            }
        }
        return nil
    }
}

extension SceneState: Codable {
    private enum CodingKeys: String, CodingKey {
        case characters, audioTracks, imageTracks, backgroundTracks, lights,
             cropAnchors, gScale, gravity, gSize, background
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        characters = try c.decodeIfPresent([Character].self, forKey: .characters) ?? []
        audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? []
        imageTracks = try c.decodeIfPresent([ImageTrack].self, forKey: .imageTracks) ?? []
        backgroundTracks = try c.decodeIfPresent([BackgroundTrack].self, forKey: .backgroundTracks) ?? []
        lights = try c.decodeIfPresent([Light].self, forKey: .lights) ?? []
        cropAnchors = try c.decodeIfPresent([Double].self, forKey: .cropAnchors) ?? []
        gScale = try c.decodeIfPresent(Double.self, forKey: .gScale) ?? 0.6
        gravity = try c.decodeIfPresent(Double.self, forKey: .gravity) ?? 1
        gSize = try c.decodeIfPresent(Double.self, forKey: .gSize) ?? 1
        background = try c.decodeIfPresent(BackgroundSpec.self, forKey: .background)
    }
}

public enum Body: String, Codable, CaseIterable, Sendable {
    case orange, original, pink, alien
}

public struct Character: Equatable, Sendable {
    public var body: Body
    /// Foot X as a fraction of stage width, 0..1.
    public var x: Double
    /// Depth: >0 farther/smaller, <0 closer/bigger. Clamped [-12, 1].
    public var depth: Double
    /// Size preset multiplier: 1 (Normal), 0.62 (Small), 0.38 (Baby).
    public var size: Double
    /// Facing: 1 right, -1 left.
    public var face: Int
    /// Outfit at t=0: slot id → outfit name.
    public var baseOutfit: [Int: String]
    public var subs: [Subtitle]
    public var clips: [AudioClip]
    public var events: [PerfEvent]
    public var armedGroups: Set<EventGroup>
    public var name: String
    public var trackFx: Fx
    public var recStart: StartPose?
    /// Walk speed (web slider 40..600). Not persisted in v1; default 320.
    public var speed: Double
    /// Gait wobble amplitude (0..16). Not persisted in v1; default 7.
    public var wobble: Double
    /// Hidden tracks stay in the document but don't render, play, or ship.
    public var hidden: Bool

    public init(body: Body, x: Double = 0.5, depth: Double = 0, size: Double = 1, face: Int = 1,
                baseOutfit: [Int: String] = [:], subs: [Subtitle] = [], clips: [AudioClip] = [],
                events: [PerfEvent] = [], armedGroups: Set<EventGroup> = Set(EventGroup.allCases),
                name: String = "", trackFx: Fx = .defaultTrack, recStart: StartPose? = nil,
                speed: Double = 320, wobble: Double = 7, hidden: Bool = false) {
        self.body = body
        self.x = x
        self.depth = depth
        self.size = size
        self.face = face
        self.baseOutfit = baseOutfit
        self.subs = subs
        self.clips = clips
        self.events = events
        self.armedGroups = armedGroups
        self.name = name
        self.trackFx = trackFx
        self.recStart = recStart
        self.speed = speed
        self.wobble = wobble
        self.hidden = hidden
    }
}

extension Character: Codable {
    private enum CodingKeys: String, CodingKey {
        case body, x, depth, size, face, baseOutfit, subs, clips, events,
             armedGroups, name, trackFx, recStart, speed, wobble, hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        body = try c.decode(Body.self, forKey: .body)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        depth = try c.decodeIfPresent(Double.self, forKey: .depth) ?? 0
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1
        face = try c.decodeIfPresent(Int.self, forKey: .face) ?? 1
        baseOutfit = try c.decodeIfPresent([Int: String].self, forKey: .baseOutfit) ?? [:]
        subs = try c.decodeIfPresent([Subtitle].self, forKey: .subs) ?? []
        clips = try c.decodeIfPresent([AudioClip].self, forKey: .clips) ?? []
        events = try c.decodeIfPresent([PerfEvent].self, forKey: .events) ?? []
        armedGroups = try c.decodeIfPresent(Set<EventGroup>.self, forKey: .armedGroups)
            ?? Set(EventGroup.allCases)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        trackFx = try c.decodeIfPresent(Fx.self, forKey: .trackFx) ?? .defaultTrack
        recStart = try c.decodeIfPresent(StartPose.self, forKey: .recStart)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 320
        wobble = try c.decodeIfPresent(Double.self, forKey: .wobble) ?? 7
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

public struct StartPose: Codable, Equatable, Sendable {
    public var x: Double
    public var depth: Double
    public var face: Int

    public init(x: Double, depth: Double, face: Int) {
        self.x = x
        self.depth = depth
        self.face = face
    }
}

public struct Subtitle: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var dur: Double

    public init(text: String, start: Double, dur: Double) {
        self.text = text
        self.start = start
        self.dur = dur
    }
}

/// A recorded performance event. Serializes as `{t, code, down}` or `{t, outfit: {slot, name}}`.
public enum PerfEvent: Equatable, Sendable {
    case key(t: Double, code: EventCode, down: Bool)
    case outfit(t: Double, slot: Int, name: String?)

    public var t: Double {
        switch self {
        case .key(let t, _, _), .outfit(let t, _, _): return t
        }
    }

    /// The same event moved by dt (timeline migration/paste).
    public func shifted(by dt: Double) -> PerfEvent {
        switch self {
        case .key(let t, let code, let down): return .key(t: t + dt, code: code, down: down)
        case .outfit(let t, let slot, let name): return .outfit(t: t + dt, slot: slot, name: name)
        }
    }
}

extension PerfEvent: Codable {
    private struct OutfitChange: Codable {
        var slot: Int
        var name: String?
    }

    private enum CodingKeys: String, CodingKey {
        case t, code, down, outfit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(Double.self, forKey: .t)
        if let change = try c.decodeIfPresent(OutfitChange.self, forKey: .outfit) {
            self = .outfit(t: t, slot: change.slot, name: change.name)
        } else {
            self = .key(t: t,
                        code: try c.decode(EventCode.self, forKey: .code),
                        down: try c.decode(Bool.self, forKey: .down))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .key(let t, let code, let down):
            try c.encode(t, forKey: .t)
            try c.encode(code, forKey: .code)
            try c.encode(down, forKey: .down)
        case .outfit(let t, let slot, let name):
            try c.encode(t, forKey: .t)
            try c.encode(OutfitChange(slot: slot, name: name), forKey: .outfit)
        }
    }
}

public struct AudioTrack: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var fx: Fx
    public var clips: [AudioClip]
    public var hidden: Bool

    public init(id: String, name: String, fx: Fx = .defaultTrack, clips: [AudioClip] = [],
                hidden: Bool = false) {
        self.id = id
        self.name = name
        self.fx = fx
        self.clips = clips
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey { case id, name, fx, clips, hidden }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Audio"
        fx = try c.decodeIfPresent(Fx.self, forKey: .fx) ?? .defaultTrack
        clips = try c.decodeIfPresent([AudioClip].self, forKey: .clips) ?? []
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

public struct AudioClip: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Timeline start (sec).
    public var start: Double
    /// Clip duration on the timeline (sec).
    public var dur: Double
    /// Offset into the source file (sec).
    public var offset: Double
    /// Full source file duration (sec).
    public var srcDur: Double
    public var fx: Fx

    public init(id: String, name: String, start: Double, dur: Double, offset: Double = 0,
                srcDur: Double, fx: Fx = .defaultClip) {
        self.id = id
        self.name = name
        self.start = start
        self.dur = dur
        self.offset = offset
        self.srcDur = srcDur
        self.fx = fx
    }
}

public struct Fx: Codable, Equatable, Sendable {
    public var gain: Double
    /// 3-band EQ gains, dB.
    public var low: Double
    public var mid: Double
    public var high: Double
    /// Reverb wet mix 0..1.
    public var reverb: Double
    public var pan: Pan

    public init(gain: Double = 1, low: Double = 0, mid: Double = 0, high: Double = 0,
                reverb: Double = 0, pan: Pan) {
        self.gain = gain
        self.low = low
        self.mid = mid
        self.high = high
        self.reverb = reverb
        self.pan = pan
    }

    public static let defaultClip = Fx(pan: .follow)
    public static let defaultTrack = Fx(pan: .narrow)
}

/// Pan mode: named modes from the web app, or a fixed numeric pan -1..1.
public enum Pan: Equatable, Sendable {
    case follow, narrow, wide
    case value(Double)
}

extension Pan: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) {
            self = .value(n)
            return
        }
        switch try c.decode(String.self) {
        case "follow": self = .follow
        case "narrow": self = .narrow
        case "wide": self = .wide
        case let other:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown pan \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .follow: try c.encode("follow")
        case .narrow: try c.encode("narrow")
        case .wide: try c.encode("wide")
        case .value(let n): try c.encode(n)
        }
    }
}

/// Sun position, normalized 0..1 of stage width/height.
public struct Light: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum Crop: String, Codable, Sendable {
    case cover, fit, stretch, tile
}

/// Background media reference. `file` is a path inside the .bannyshow package's bg/ folder.
public enum BackgroundSpec: Equatable, Sendable {
    case image(file: String, crop: Crop)
    case video(file: String, crop: Crop)
}

extension BackgroundSpec: Codable {
    private enum CodingKeys: String, CodingKey { case type, file, crop }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let file = try c.decode(String.self, forKey: .file)
        let crop = try c.decode(Crop.self, forKey: .crop)
        switch try c.decode(String.self, forKey: .type) {
        case "image": self = .image(file: file, crop: crop)
        case "video": self = .video(file: file, crop: crop)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown bg type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .image(let file, let crop):
            try c.encode("image", forKey: .type)
            try c.encode(file, forKey: .file)
            try c.encode(crop, forKey: .crop)
        case .video(let file, let crop):
            try c.encode("video", forKey: .type)
            try c.encode(file, forKey: .file)
            try c.encode(crop, forKey: .crop)
        }
    }
}
