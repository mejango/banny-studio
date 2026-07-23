import Foundation

/// Banny Studio document model.
/// Concepts map 1:1 to the web v1 studio; see docs/superpowers/specs/2026-07-07-banny-studio-native-design.md.

public struct ShowDocument: Equatable, Sendable {
    public var version: Int
    /// The single stage/timeline. (v3 replaced the old scenes array.)
    public var stage: SceneState
    /// Reusable image/video assets ("the set").
    public var assets: [Asset]
    public var show: [ShowSegment]
    public var settings: Settings

    public init(version: Int = 4, stage: SceneState = SceneState(), assets: [Asset] = [],
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
                c.reactions = c.reactions.map { var r = $0; r.start += cursor; return r }
                c.clips = c.clips.map { var k = $0; k.start += cursor; return k }
                c.subs = c.subs.map { var s = $0; s.start += cursor; return s }
                return c
            }
            stage.characters.append(contentsOf: state.characters.map(shifted))
            stage.reactionLibrary.append(contentsOf: state.reactionLibrary)
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

/// A visibility toggle on a track's timeline: the track shows/hides from t onward.
public struct VisibilityEvent: Codable, Equatable, Sendable {
    public var t: Double
    public var visible: Bool

    public init(t: Double, visible: Bool) {
        self.t = t
        self.visible = visible
    }
}

public extension Array where Element == VisibilityEvent {
    /// Presence at time t: last toggle at or before t wins; default visible.
    func isPresent(at t: Double) -> Bool {
        var visible = true
        for ev in self.sorted(by: { $0.t < $1.t }) {
            if ev.t <= t { visible = ev.visible } else { break }
        }
        return visible
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
    /// Locked tracks remain visible but cannot be edited or recorded over.
    public var locked: Bool
    public var cues: [ImageCue]
    public var presence: [VisibilityEvent]

    public init(id: String, name: String, hidden: Bool = false, locked: Bool = false,
                cues: [ImageCue] = [],
                presence: [VisibilityEvent] = []) {
        self.id = id
        self.name = name
        self.hidden = hidden
        self.locked = locked
        self.cues = cues
        self.presence = presence
    }

    private enum CodingKeys: String, CodingKey { case id, name, hidden, locked, cues, presence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        cues = try c.decodeIfPresent([ImageCue].self, forKey: .cues) ?? []
        presence = try c.decodeIfPresent([VisibilityEvent].self, forKey: .presence) ?? []
    }
}

public struct ImageCue: Codable, Equatable, Identifiable, Sendable {
    /// UI-scale defaults shared with character motion controls.
    public static let defaultSpeed = 5.5
    public static let defaultRotationSpeed = 5.5

    public var id: String
    public var assetID: String
    public var start: Double
    public var dur: Double
    /// Placement at cue start.
    public var from: ImagePlacement
    /// Placement at cue end; nil = static. Linear interpolation between.
    public var to: ImagePlacement?
    /// Keyboard/recording translation speed on the shared 1...10 motion scale.
    public var speed: Double
    /// Keyboard/recording rotation speed on the shared motion-control scale.
    public var rotationSpeed: Double
    /// Source-time controls for animated GIFs and videos.
    public var playback: MediaPlayback
    /// Non-destructive color and edge treatment.
    public var appearance: MediaAppearance
    /// Geometric crop applied after appearance processing.
    public var mask: MediaMask
    /// Corner radius as a fraction of the smaller displayed dimension.
    public var maskRadius: Double
    /// Point inside the asset placed at `ImagePlacement.x/y` and used for rotation.
    public var pivot: MediaPivot
    /// Display label; nil falls back to the asset's name.
    public var label: String?

    public init(id: String, assetID: String, start: Double, dur: Double,
                from: ImagePlacement, to: ImagePlacement? = nil,
                speed: Double = Self.defaultSpeed,
                rotationSpeed: Double = Self.defaultRotationSpeed,
                playback: MediaPlayback = MediaPlayback(),
                appearance: MediaAppearance = MediaAppearance(),
                mask: MediaMask = .none, maskRadius: Double = 0.12,
                pivot: MediaPivot = .center,
                label: String? = nil) {
        self.id = id
        self.assetID = assetID
        self.start = start
        self.dur = dur
        self.from = from
        self.to = to
        self.speed = speed
        self.rotationSpeed = rotationSpeed
        self.playback = playback
        self.appearance = appearance
        self.mask = mask
        self.maskRadius = maskRadius
        self.pivot = pivot
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetID, start, dur, from, to, speed, rotationSpeed,
             playback, appearance, mask, maskRadius, pivot, label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        assetID = try c.decode(String.self, forKey: .assetID)
        start = try c.decode(Double.self, forKey: .start)
        dur = try c.decode(Double.self, forKey: .dur)
        from = try c.decode(ImagePlacement.self, forKey: .from)
        to = try c.decodeIfPresent(ImagePlacement.self, forKey: .to)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? Self.defaultSpeed
        rotationSpeed = try c.decodeIfPresent(Double.self, forKey: .rotationSpeed)
            ?? Self.defaultRotationSpeed
        playback = try c.decodeIfPresent(MediaPlayback.self, forKey: .playback) ?? MediaPlayback()
        appearance = try c.decodeIfPresent(MediaAppearance.self, forKey: .appearance)
            ?? MediaAppearance()
        mask = try c.decodeIfPresent(MediaMask.self, forKey: .mask) ?? .none
        maskRadius = try c.decodeIfPresent(Double.self, forKey: .maskRadius) ?? 0.12
        pivot = try c.decodeIfPresent(MediaPivot.self, forKey: .pivot) ?? .center
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }

    /// Interpolated placement at absolute time t (clamped to the cue).
    public func placement(at t: Double) -> ImagePlacement {
        guard let to, dur > 0 else { return from }
        let k = min(1, max(0, (t - start) / dur))
        return ImagePlacement(x: from.x + (to.x - from.x) * k,
                              y: from.y + (to.y - from.y) * k,
                              scale: from.scale + (to.scale - from.scale) * k,
                              rotation: from.rotation + (to.rotation - from.rotation) * k)
    }

    /// Maps the show clock into the trimmed source timeline. The returned time
    /// is clamped inside the source so video generators never seek at EOF.
    public func sourceTime(at t: Double, sourceDuration: Double) -> Double {
        let duration = max(0, sourceDuration)
        guard duration > 0.000_001 else { return 0 }
        let epsilon = min(0.001, duration / 1000)
        let lo = min(max(0, playback.trimStart), max(0, duration - epsilon))
        let requestedEnd = playback.trimEnd ?? duration
        let hi = min(duration, max(lo + epsilon, requestedEnd))
        let lastFrame = max(lo, hi - epsilon)
        if let frozen = playback.freezeAt {
            return min(lastFrame, max(lo, frozen))
        }
        let span = max(epsilon, hi - lo)
        let elapsed = max(0, playback.phaseOffset)
            + max(0, t - start) * max(0.01, playback.rate)
        let phase: Double
        if playback.loop {
            phase = elapsed.truncatingRemainder(dividingBy: span)
        } else {
            phase = min(lastFrame - lo, elapsed)
        }
        return playback.reverse ? max(lo, lastFrame - phase) : min(lastFrame, lo + phase)
    }

    /// Playback settings for a continuation cue beginning at `t`. The source
    /// phase advances with the old cue's clock, so splitting or recording a
    /// path never restarts an animated GIF or video.
    public func continuedPlayback(at t: Double) -> MediaPlayback {
        var continued = playback
        continued.phaseOffset += max(0, t - start) * max(0.01, playback.rate)
        return continued
    }
}

public extension ImageCue {
    /// Hit-tests the visual's rotated rectangular bounds in normalized stage
    /// coordinates. Editors use this to begin a direct-manipulation drag only
    /// when the pointer actually grabs the selected asset.
    func containsStagePoint(x: Double, y: Double, at showTime: Double,
                            assetAspect: Double, stageAspect: Double,
                            placement override: ImagePlacement? = nil) -> Bool {
        let p = override ?? placement(at: showTime)
        let safeStageAspect = max(0.001, stageAspect)
        let safeAssetAspect = max(0.001, assetAspect)

        // Work in stage-width units so X and Y share the same scale before
        // undoing the asset rotation.
        let dx = x - p.x
        let dy = (y - p.y) / safeStageAspect
        let radians = p.rotation * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let localX = dx * cosine + dy * sine
        let localY = -dx * sine + dy * cosine

        let width = max(0, p.scale)
        let height = width / safeAssetAspect
        let px = min(1, max(0, pivot.x))
        let py = min(1, max(0, pivot.y))
        let epsilon = 1e-9
        return localX >= -px * width - epsilon
            && localX <= (1 - px) * width + epsilon
            && localY >= -py * height - epsilon
            && localY <= (1 - py) * height + epsilon
    }
}

public struct MediaPlayback: Equatable, Sendable {
    /// Seconds from the beginning of the source.
    public var trimStart: Double
    /// Source end time in seconds; nil means the asset's full duration.
    public var trimEnd: Double?
    public var rate: Double
    public var reverse: Bool
    public var loop: Bool
    /// A source time in seconds; nil means animated playback.
    public var freezeAt: Double?
    /// Source seconds already traversed when this cue starts. Splits and
    /// recorded motion segments advance this value so playback stays
    /// continuous across adjacent cues.
    public var phaseOffset: Double

    public init(trimStart: Double = 0, trimEnd: Double? = nil, rate: Double = 1,
                reverse: Bool = false, loop: Bool = true, freezeAt: Double? = nil) {
        self.init(trimStart: trimStart, trimEnd: trimEnd, rate: rate,
                  reverse: reverse, loop: loop, freezeAt: freezeAt, phaseOffset: 0)
    }

    public init(trimStart: Double, trimEnd: Double?, rate: Double,
                reverse: Bool, loop: Bool, freezeAt: Double? = nil, phaseOffset: Double) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.rate = rate
        self.reverse = reverse
        self.loop = loop
        self.freezeAt = freezeAt
        self.phaseOffset = phaseOffset
    }
}

extension MediaPlayback: Codable {
    private enum CodingKeys: String, CodingKey {
        case trimStart, trimEnd, rate, reverse, loop, freezeAt, phaseOffset
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        reverse = try c.decodeIfPresent(Bool.self, forKey: .reverse) ?? false
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? true
        freezeAt = try c.decodeIfPresent(Double.self, forKey: .freezeAt)
        phaseOffset = try c.decodeIfPresent(Double.self, forKey: .phaseOffset) ?? 0
    }
}

public enum MediaMask: String, Codable, CaseIterable, Sendable {
    case none, rectangle, roundedRectangle, circle
}

public struct MediaPivot: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0.5, y: Double = 0.5) {
        self.x = x
        self.y = y
    }

    public static let center = MediaPivot()
    /// Natural character anchors in the 400×400 artwork canvas.
    public static let characterHead = MediaPivot(x: 0.5, y: 0.3)
    public static let characterFeet = MediaPivot(x: 0.5, y: 0.82)
    public static let topLeft = MediaPivot(x: 0, y: 0)
    public static let topRight = MediaPivot(x: 1, y: 0)
    public static let bottomLeft = MediaPivot(x: 0, y: 1)
    public static let bottomRight = MediaPivot(x: 1, y: 1)
}

extension MediaPivot: Codable {
    private enum CodingKeys: String, CodingKey { case x, y }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
    }
}

public struct MediaColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double = 1, green: Double = 1, blue: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

extension MediaColor: Codable {
    private enum CodingKeys: String, CodingKey { case red, green, blue }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = try c.decodeIfPresent(Double.self, forKey: .red) ?? 1
        green = try c.decodeIfPresent(Double.self, forKey: .green) ?? 1
        blue = try c.decodeIfPresent(Double.self, forKey: .blue) ?? 1
    }
}

public struct MediaAppearance: Equatable, Sendable {
    public var tint: MediaColor
    public var tintAmount: Double
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    /// Outline width in pixels at a 1920-wide output.
    public var outline: Double
    /// Light-driven shadow intensity, 0...1.
    public var shadow: Double
    /// Tightens low-alpha fringe pixels, 0...1.
    public var cleanup: Double

    public init(tint: MediaColor = MediaColor(), tintAmount: Double = 0,
                brightness: Double = 0, contrast: Double = 1, saturation: Double = 1,
                outline: Double = 0, shadow: Double = 0, cleanup: Double = 0) {
        self.tint = tint
        self.tintAmount = tintAmount
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.outline = outline
        self.shadow = shadow
        self.cleanup = cleanup
    }
}

extension MediaAppearance: Codable {
    private enum CodingKeys: String, CodingKey {
        case tint, tintAmount, brightness, contrast, saturation, outline, shadow, cleanup
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tint = try c.decodeIfPresent(MediaColor.self, forKey: .tint) ?? MediaColor()
        tintAmount = try c.decodeIfPresent(Double.self, forKey: .tintAmount) ?? 0
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        outline = try c.decodeIfPresent(Double.self, forKey: .outline) ?? 0
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? 0
        cleanup = try c.decodeIfPresent(Double.self, forKey: .cleanup) ?? 0
    }
}

/// Pivot position (fractions of stage width/height) + width as a fraction of
/// stage width + rotation in degrees (clockwise about the cue's selected pivot).
public struct ImagePlacement: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var scale: Double
    public var rotation: Double

    public init(x: Double = 0.5, y: Double = 0.5, scale: Double = 0.3, rotation: Double = 0) {
        self.x = x
        self.y = y
        self.scale = scale
        self.rotation = rotation
    }

    private enum CodingKeys: String, CodingKey { case x, y, scale, rotation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 0.3
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }
}

extension ImagePlacement: Codable {}

/// Full-screen backdrop cues; the active cue at t paints the background.
public struct BackgroundTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var hidden: Bool
    public var locked: Bool
    public var cues: [BackgroundCue]
    public var presence: [VisibilityEvent]

    public init(id: String, name: String, hidden: Bool = false, locked: Bool = false,
                cues: [BackgroundCue] = [],
                presence: [VisibilityEvent] = []) {
        self.id = id
        self.name = name
        self.hidden = hidden
        self.locked = locked
        self.cues = cues
        self.presence = presence
    }

    private enum CodingKeys: String, CodingKey { case id, name, hidden, locked, cues, presence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        cues = try c.decodeIfPresent([BackgroundCue].self, forKey: .cues) ?? []
        presence = try c.decodeIfPresent([VisibilityEvent].self, forKey: .presence) ?? []
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
    /// Camera at cue start; nil = no camera (full frame). Optionals decode
    /// as absent on pre-camera documents.
    public var camFrom: CameraState?
    /// Camera at cue end; nil = static. Linear interpolation between.
    public var camTo: CameraState?

    public init(id: String, assetID: String, start: Double, dur: Double, crop: Crop = .cover,
                label: String? = nil, camFrom: CameraState? = nil, camTo: CameraState? = nil) {
        self.id = id
        self.assetID = assetID
        self.start = start
        self.dur = dur
        self.crop = crop
        self.label = label
        self.camFrom = camFrom
        self.camTo = camTo
    }

    /// Interpolated camera at absolute time t (clamped to the cue).
    public func camera(at t: Double) -> CameraState? {
        guard let from = camFrom else { return nil }
        guard let to = camTo, dur > 0 else { return from }
        let k = min(1, max(0, (t - start) / dur))
        return CameraState(x: from.x + (to.x - from.x) * k,
                           y: from.y + (to.y - from.y) * k,
                           zoom: from.zoom + (to.zoom - from.zoom) * k)
    }
}

/// A virtual camera over the whole frame: focus point (fractions of frame
/// width/height, lands at frame center) and zoom (1 = full frame).
public struct CameraState: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var zoom: Double

    public init(x: Double = 0.5, y: Double = 0.5, zoom: Double = 1) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var activeScene: Int
    public var lightSize: Double
    /// Output frame aspect as W:H (16:9 horizontal, 9:16 vertical, or custom).
    public var frameW: Double
    public var frameH: Double

    public init(activeScene: Int = 0, lightSize: Double = 0,
                frameW: Double = 16, frameH: Double = 9) {
        self.activeScene = activeScene
        self.lightSize = lightSize
        self.frameW = frameW
        self.frameH = frameH
    }

    private enum CodingKeys: String, CodingKey { case activeScene, lightSize, frameW, frameH }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeScene = try c.decodeIfPresent(Int.self, forKey: .activeScene) ?? 0
        lightSize = try c.decodeIfPresent(Double.self, forKey: .lightSize) ?? 0
        frameW = try c.decodeIfPresent(Double.self, forKey: .frameW) ?? 16
        frameH = try c.decodeIfPresent(Double.self, forKey: .frameH) ?? 9
    }

    /// Frame aspect ratio (w/h), clamped to something renderable.
    public var frameAspect: Double {
        let w = frameW > 0 ? frameW : 16
        let h = frameH > 0 ? frameH : 9
        return min(4, max(0.25, w / h))
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

/// A named point or span on the production timeline. Markers are navigation
/// anchors; sections make the show's structure explicit without changing what
/// is rendered or exported.
public struct TimelineMarker: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case marker
        case section
    }

    public enum Color: String, Codable, CaseIterable, Sendable {
        case orange
        case blue
        case green
        case purple
        case red
        case gray
    }

    public var id: String
    public var name: String
    public var start: Double
    public var kind: Kind
    /// Only sections use duration. A section is always at least 0.1 seconds.
    public var duration: Double
    public var color: Color

    public init(id: String, name: String, start: Double, kind: Kind = .marker,
                duration: Double = 0, color: Color = .orange) {
        self.id = id
        self.name = name
        self.start = max(0, start)
        self.kind = kind
        self.duration = kind == .section ? max(0.1, duration) : 0
        self.color = color
    }

    public var end: Double {
        kind == .section ? start + max(0.1, duration) : start
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, start, kind, duration, color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Marker"
        start = max(0, try c.decodeIfPresent(Double.self, forKey: .start) ?? 0)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .marker
        let decodedDuration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        duration = kind == .section ? max(0.1, decodedDuration) : 0
        color = try c.decodeIfPresent(Color.self, forKey: .color) ?? .orange
    }
}

public struct SceneState: Equatable, Sendable {
    public var characters: [Character]
    /// Reusable performances referenced by character reaction blocks.
    public var reactionLibrary: [ReactionDefinition]
    public var audioTracks: [AudioTrack]
    public var imageTracks: [ImageTrack]
    public var backgroundTracks: [BackgroundTrack]
    public var lightTracks: [LightTrack]
    public var lights: [Light]
    /// Crop anchor times (seconds) that split the timeline into Show segments.
    public var cropAnchors: [Double]
    /// User-authored navigation markers and named production sections.
    public var markers: [TimelineMarker]
    /// Depth→scale intensity (web slider 0..1.2).
    public var gScale: Double
    /// Jump gravity (0.3..2.5).
    public var gravity: Double
    /// Base size multiplier (0.3..2.5).
    public var gSize: Double
    /// v2 per-scene background (decode-only; migration turns it into a cue).
    public var background: BackgroundSpec?
    /// Display order of timeline rows (track keys); empty = type order.
    public var rowOrder: [String]

    public init(characters: [Character] = [], reactionLibrary: [ReactionDefinition] = [],
                audioTracks: [AudioTrack] = [],
                imageTracks: [ImageTrack] = [], backgroundTracks: [BackgroundTrack] = [],
                lightTracks: [LightTrack] = [],
                lights: [Light] = [], cropAnchors: [Double] = [],
                markers: [TimelineMarker] = [],
                gScale: Double = 0.6, gravity: Double = 1, gSize: Double = 1,
                background: BackgroundSpec? = nil, rowOrder: [String] = []) {
        self.characters = characters
        self.reactionLibrary = reactionLibrary
        self.audioTracks = audioTracks
        self.imageTracks = imageTracks
        self.backgroundTracks = backgroundTracks
        self.lightTracks = lightTracks
        self.lights = lights
        self.cropAnchors = cropAnchors
        self.markers = markers
        self.gScale = gScale
        self.gravity = gravity
        self.gSize = gSize
        self.background = background
        self.rowOrder = rowOrder
    }

    /// End of the last event/clip/caption/cue (web tlDurNeeded's content part).
    public var contentEnd: Double {
        var end = 0.0
        for c in characters {
            end = max(end, c.events.last?.t ?? 0)
            for reaction in c.reactions { end = max(end, reaction.start + reaction.dur) }
            for clip in c.clips { end = max(end, clip.start + clip.dur) }
            for s in c.subs { end = max(end, s.start + s.dur) }
        }
        for t in audioTracks {
            for clip in t.clips { end = max(end, clip.start + clip.dur) }
            for cue in t.cues { end = max(end, cue.start + cue.dur) }
        }
        for t in imageTracks {
            for cue in t.cues { end = max(end, cue.start + cue.dur) }
        }
        for t in backgroundTracks {
            for cue in t.cues { end = max(end, cue.start + cue.dur) }
        }
        for t in lightTracks {
            for cue in t.cues { end = max(end, cue.start + cue.dur) }
        }
        for marker in markers { end = max(end, marker.end) }
        return end
    }

    /// Lights shining at time t: every visible light track's active cue,
    /// interpolated. Falls back to the legacy static `lights` array when no
    /// light track is active (pre-light-track documents keep their sun).
    public func activeLights(at t: Double) -> [ResolvedLight] {
        var out: [ResolvedLight] = []
        for track in lightTracks where !track.hidden && track.presence.isPresent(at: t) {
            for cue in track.cues where t >= cue.start && t < cue.start + cue.dur {
                let state = cue.state(at: t)
                out.append(ResolvedLight(x: state.x, y: state.y,
                                         intensity: state.intensity, size: state.size))
            }
        }
        if out.isEmpty {
            out = lights.map { ResolvedLight(x: $0.x, y: $0.y, intensity: 1) }
        }
        return out
    }

    /// The backdrop to paint at time t: last visible background track's active cue wins.
    public func activeBackgroundCue(at t: Double) -> BackgroundCue? {
        for track in backgroundTracks.reversed() where !track.hidden && track.presence.isPresent(at: t) {
            if let cue = track.cues.last(where: { t >= $0.start && t < $0.start + $0.dur }) {
                return cue
            }
        }
        return nil
    }
}

extension SceneState: Codable {
    private enum CodingKeys: String, CodingKey {
        case characters, reactionLibrary, audioTracks, imageTracks, backgroundTracks, lightTracks, lights,
             cropAnchors, markers, gScale, gravity, gSize, background, rowOrder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        characters = try c.decodeIfPresent([Character].self, forKey: .characters) ?? []
        reactionLibrary = try c.decodeIfPresent([ReactionDefinition].self,
                                                forKey: .reactionLibrary) ?? []
        audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? []
        imageTracks = try c.decodeIfPresent([ImageTrack].self, forKey: .imageTracks) ?? []
        backgroundTracks = try c.decodeIfPresent([BackgroundTrack].self, forKey: .backgroundTracks) ?? []
        lightTracks = try c.decodeIfPresent([LightTrack].self, forKey: .lightTracks) ?? []
        lights = try c.decodeIfPresent([Light].self, forKey: .lights) ?? []
        cropAnchors = try c.decodeIfPresent([Double].self, forKey: .cropAnchors) ?? []
        markers = try c.decodeIfPresent([TimelineMarker].self, forKey: .markers) ?? []
        gScale = try c.decodeIfPresent(Double.self, forKey: .gScale) ?? 0.6
        gravity = try c.decodeIfPresent(Double.self, forKey: .gravity) ?? 1
        gSize = try c.decodeIfPresent(Double.self, forKey: .gSize) ?? 1
        background = try c.decodeIfPresent(BackgroundSpec.self, forKey: .background)
        rowOrder = try c.decodeIfPresent([String].self, forKey: .rowOrder) ?? []
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
    /// Animalese voice profile: base pitch in semitones, speaking rate.
    public var voicePitch: Double
    public var voiceSpeed: Double
    /// Natural speech voice, non-destructive recipe, and lip-sync preference.
    public var speechVoice: SpeechVoiceProfile
    public var clips: [AudioClip]
    public var events: [PerfEvent]
    /// Reusable reaction blocks placed on this character's timeline.
    public var reactions: [ReactionInstance]
    public var armedGroups: Set<EventGroup>
    public var name: String
    public var trackFx: Fx
    public var recStart: StartPose?
    /// Walk speed (web slider 40..600). Not persisted in v1; default 320.
    public var speed: Double
    /// Degrees/second while rotate is held.
    public var rotationSpeed: Double
    /// Explicit normalized artwork pivot for free rotation and flips.
    /// Nil is the recommended automatic mode: feet for grounded rotation,
    /// body center for flips.
    public var rotationPivot: MediaPivot?
    /// Gait wobble amplitude (0..16). Not persisted in v1; default 7.
    public var wobble: Double
    /// Hidden tracks stay in the document but don't render, play, or ship.
    public var hidden: Bool
    /// Locked tracks remain visible but reject editing and recording gestures.
    public var locked: Bool
    /// Solo is an audio-monitoring/export state shared by voice and media tracks.
    public var solo: Bool
    /// Timed show/hide toggles (presence on stage over the timeline).
    public var presence: [VisibilityEvent]

    public init(body: Body, x: Double = 0.5, depth: Double = 0, size: Double = 1, face: Int = 1,
                baseOutfit: [Int: String] = [:], subs: [Subtitle] = [], clips: [AudioClip] = [],
                voicePitch: Double = 0, voiceSpeed: Double = 1,
                speechVoice: SpeechVoiceProfile = SpeechVoiceProfile(),
                events: [PerfEvent] = [], reactions: [ReactionInstance] = [],
                armedGroups: Set<EventGroup> = Set(EventGroup.allCases),
                name: String = "", trackFx: Fx = .defaultCharacterTrack, recStart: StartPose? = nil,
                speed: Double = 320, rotationSpeed: Double = 90,
                rotationPivot: MediaPivot? = nil,
                wobble: Double = 7, hidden: Bool = false, locked: Bool = false,
                solo: Bool = false,
                presence: [VisibilityEvent] = []) {
        self.body = body
        self.x = x
        self.depth = depth
        self.size = size
        self.face = face
        self.baseOutfit = baseOutfit
        self.subs = subs
        self.voicePitch = voicePitch
        self.voiceSpeed = voiceSpeed
        self.speechVoice = speechVoice
        self.clips = clips
        self.events = events
        self.reactions = reactions
        self.armedGroups = armedGroups
        self.name = name
        self.trackFx = trackFx
        self.recStart = recStart
        self.speed = speed
        self.rotationSpeed = rotationSpeed
        self.rotationPivot = rotationPivot
        self.wobble = wobble
        self.hidden = hidden
        self.locked = locked
        self.solo = solo
        self.presence = presence
    }
}

extension Character: Codable {
    private enum CodingKeys: String, CodingKey {
        case body, x, depth, size, face, baseOutfit, subs, clips, events, reactions,
             armedGroups, name, trackFx, recStart, speed, rotationSpeed, wobble, hidden, locked, solo, presence,
             voicePitch, voiceSpeed, speechVoice, rotationPivot
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
        voicePitch = try c.decodeIfPresent(Double.self, forKey: .voicePitch) ?? 0
        voiceSpeed = try c.decodeIfPresent(Double.self, forKey: .voiceSpeed) ?? 1
        speechVoice = try c.decodeIfPresent(SpeechVoiceProfile.self, forKey: .speechVoice)
            ?? SpeechVoiceProfile()
        clips = try c.decodeIfPresent([AudioClip].self, forKey: .clips) ?? []
        events = try c.decodeIfPresent([PerfEvent].self, forKey: .events) ?? []
        reactions = try c.decodeIfPresent([ReactionInstance].self, forKey: .reactions) ?? []
        armedGroups = try c.decodeIfPresent(Set<EventGroup>.self, forKey: .armedGroups)
            ?? Set(EventGroup.allCases)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        trackFx = try c.decodeIfPresent(Fx.self, forKey: .trackFx) ?? .defaultCharacterTrack
        recStart = try c.decodeIfPresent(StartPose.self, forKey: .recStart)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 320
        rotationSpeed = try c.decodeIfPresent(Double.self, forKey: .rotationSpeed) ?? 90
        rotationPivot = try c.decodeIfPresent(MediaPivot.self, forKey: .rotationPivot)
        wobble = try c.decodeIfPresent(Double.self, forKey: .wobble) ?? 7
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        presence = try c.decodeIfPresent([VisibilityEvent].self, forKey: .presence) ?? []
    }
}

public struct StartPose: Equatable, Sendable {
    public var x: Double
    public var depth: Double
    public var face: Int
    /// Free rotation in degrees at the start of the performance.
    public var spin: Double
    /// Extra scale multiplier at the start of the performance.
    public var zoom: Double

    public init(x: Double, depth: Double, face: Int) {
        self.init(x: x, depth: depth, face: face, spin: 0, zoom: 1)
    }

    public init(x: Double, depth: Double, face: Int, spin: Double, zoom: Double) {
        self.x = x
        self.depth = depth
        self.face = face
        self.spin = spin
        self.zoom = zoom
    }
}

extension StartPose: Codable {
    private enum CodingKeys: String, CodingKey { case x, depth, face, spin, zoom }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        depth = try c.decodeIfPresent(Double.self, forKey: .depth) ?? 0
        face = try c.decodeIfPresent(Int.self, forKey: .face) ?? 1
        spin = try c.decodeIfPresent(Double.self, forKey: .spin) ?? 0
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(depth, forKey: .depth)
        try c.encode(face, forKey: .face)
        try c.encode(spin, forKey: .spin)
        try c.encode(zoom, forKey: .zoom)
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
    /// A timed change to the character's motion params (nil = leave unchanged).
    /// Resolved last-writer-wins before t, exactly like outfit changes.
    case motion(t: Double, speed: Double?, rotationSpeed: Double?, wobble: Double?, size: Double?)

    public var t: Double {
        switch self {
        case .key(let t, _, _), .outfit(let t, _, _), .motion(let t, _, _, _, _): return t
        }
    }

    /// The same event moved by dt (timeline migration/paste).
    public func shifted(by dt: Double) -> PerfEvent {
        switch self {
        case .key(let t, let code, let down): return .key(t: t + dt, code: code, down: down)
        case .outfit(let t, let slot, let name): return .outfit(t: t + dt, slot: slot, name: name)
        case .motion(let t, let s, let r, let w, let z):
            return .motion(t: t + dt, speed: s, rotationSpeed: r, wobble: w, size: z)
        }
    }
}

extension PerfEvent: Codable {
    private struct OutfitChange: Codable {
        var slot: Int
        var name: String?
    }
    private struct MotionChange: Codable {
        var speed: Double?
        var rotationSpeed: Double?
        var wobble: Double?
        var size: Double?
    }

    private enum CodingKeys: String, CodingKey {
        case t, code, down, outfit, motion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(Double.self, forKey: .t)
        if let change = try c.decodeIfPresent(OutfitChange.self, forKey: .outfit) {
            self = .outfit(t: t, slot: change.slot, name: change.name)
        } else if let m = try c.decodeIfPresent(MotionChange.self, forKey: .motion) {
            self = .motion(t: t, speed: m.speed, rotationSpeed: m.rotationSpeed,
                           wobble: m.wobble, size: m.size)
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
        case .motion(let t, let s, let r, let w, let z):
            try c.encode(t, forKey: .t)
            try c.encode(MotionChange(speed: s, rotationSpeed: r, wobble: w, size: z),
                         forKey: .motion)
        }
    }
}

/// A named, reusable character performance. Event times are local to the
/// reaction (0...dur). The controls, motion fields, and wardrobe slots present
/// in `events` are the channels this reaction owns while a block is active.
public struct ReactionDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var dur: Double
    public var events: [PerfEvent]

    public init(id: String, name: String, dur: Double, events: [PerfEvent]) {
        self.id = id
        self.name = name
        self.dur = dur
        self.events = events
    }

    public var ownedGroups: Set<EventGroup> {
        Set(events.compactMap { event in
            guard case .key(_, let code, _) = event else { return nil }
            return code.group
        })
    }

    public var outfitSlots: Set<Int> {
        Set(events.compactMap { event in
            guard case .outfit(_, let slot, _) = event else { return nil }
            return slot
        })
    }

    public var ownsWobble: Bool {
        events.contains { event in
            guard case .motion(_, _, _, let wobble, _) = event else { return false }
            return wobble != nil
        }
    }

    public var ownsSize: Bool {
        events.contains { event in
            guard case .motion(_, _, _, _, let size) = event else { return false }
            return size != nil
        }
    }
}

/// One placement of a reusable reaction on a character timeline. Stretching
/// `dur` changes its tempo; `intensity` scales continuous motion without
/// changing discrete expressions or outfit choices.
public struct ReactionInstance: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var reactionID: String
    public var start: Double
    public var dur: Double
    public var intensity: Double

    public init(id: String, reactionID: String, start: Double, dur: Double,
                intensity: Double = 1) {
        self.id = id
        self.reactionID = reactionID
        self.start = start
        self.dur = dur
        self.intensity = intensity
    }

    private enum CodingKeys: String, CodingKey {
        case id, reactionID, start, dur, intensity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        reactionID = try c.decode(String.self, forKey: .reactionID)
        start = try c.decode(Double.self, forKey: .start)
        dur = try c.decode(Double.self, forKey: .dur)
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 1
    }
}

public struct AudioTrack: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var fx: Fx
    public var clips: [AudioClip]
    /// Image cues on the same track — audio tracks are general MEDIA tracks.
    public var cues: [ImageCue]
    public var hidden: Bool
    public var locked: Bool
    public var solo: Bool
    public var presence: [VisibilityEvent]

    public init(id: String, name: String, fx: Fx = .defaultTrack, clips: [AudioClip] = [],
                cues: [ImageCue] = [], hidden: Bool = false, locked: Bool = false,
                solo: Bool = false, presence: [VisibilityEvent] = []) {
        self.id = id
        self.name = name
        self.fx = fx
        self.clips = clips
        self.cues = cues
        self.hidden = hidden
        self.locked = locked
        self.solo = solo
        self.presence = presence
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, fx, clips, cues, hidden, locked, solo, presence
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Audio"
        fx = try c.decodeIfPresent(Fx.self, forKey: .fx) ?? .defaultTrack
        clips = try c.decodeIfPresent([AudioClip].self, forKey: .clips) ?? []
        cues = try c.decodeIfPresent([ImageCue].self, forKey: .cues) ?? []
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        presence = try c.decodeIfPresent([VisibilityEvent].self, forKey: .presence) ?? []
    }
}

public struct AudioClip: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case imported
        case microphone
        case speech
    }

    public var id: String
    public var name: String
    /// Provenance controls specialized non-destructive processing.
    public var kind: Kind
    /// Timeline start (sec).
    public var start: Double
    /// Clip duration on the timeline (sec).
    public var dur: Double
    /// Offset into the source file (sec).
    public var offset: Double
    /// Full source file duration (sec).
    public var srcDur: Double
    public var fx: Fx
    /// True when this clip's fx intentionally diverge from the track mix
    /// (track-level mix edits then leave it alone).
    public var fxOverride: Bool?
    /// Non-destructive edge fades, in seconds, clamped to the visible clip.
    public var fadeIn: Double
    public var fadeOut: Double
    /// Source-relative, deterministic lip-sync generated with speech audio.
    public var mouthCues: [SpeechMouthCue]

    public init(id: String, name: String, start: Double, dur: Double, offset: Double = 0,
                srcDur: Double, fx: Fx = .defaultClip, fxOverride: Bool? = nil,
                fadeIn: Double = 0, fadeOut: Double = 0,
                kind: Kind = .imported, mouthCues: [SpeechMouthCue] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.start = start
        self.dur = dur
        self.offset = offset
        self.srcDur = srcDur
        self.fx = fx
        self.fxOverride = fxOverride
        self.fadeIn = min(max(0, fadeIn), max(0, dur))
        self.fadeOut = min(max(0, fadeOut), max(0, dur))
        self.mouthCues = mouthCues
    }

    /// Linear edge-fade multiplier at an absolute timeline time.
    public func level(at timelineTime: Double) -> Double {
        guard timelineTime >= start, timelineTime <= start + dur else { return 0 }
        let local = timelineTime - start
        let into = fadeIn > 0 ? min(1, max(0, local / min(fadeIn, dur))) : 1
        let remaining = start + dur - timelineTime
        let out = fadeOut > 0 ? min(1, max(0, remaining / min(fadeOut, dur))) : 1
        return min(into, out)
    }

    /// Mouth pose at an absolute timeline time, respecting trims and splits.
    public func mouthShape(at timelineTime: Double) -> MouthShape? {
        guard timelineTime >= start, timelineTime < start + dur else { return nil }
        let sourceTime = offset + timelineTime - start
        return mouthCues.last {
            sourceTime + 1e-9 >= $0.start && sourceTime < $0.start + $0.dur - 1e-9
        }?.shape
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, start, dur, offset, srcDur, fx, fxOverride, fadeIn, fadeOut,
             mouthCues
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Audio"
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind)
            ?? ((id.hasPrefix("tts-") || id.hasPrefix("ani-")) ? .speech : .imported)
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        dur = try c.decodeIfPresent(Double.self, forKey: .dur) ?? 0
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        srcDur = try c.decodeIfPresent(Double.self, forKey: .srcDur) ?? dur
        fx = try c.decodeIfPresent(Fx.self, forKey: .fx) ?? .defaultClip
        fxOverride = try c.decodeIfPresent(Bool.self, forKey: .fxOverride)
        fadeIn = min(max(0, try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0),
                     max(0, dur))
        fadeOut = min(max(0, try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0),
                      max(0, dur))
        mouthCues = try c.decodeIfPresent([SpeechMouthCue].self, forKey: .mouthCues) ?? []
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
    /// Character voices track the speaker by default.
    public static let defaultCharacterTrack = Fx(pan: .follow)
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

/// A light on stage at a moment: position (normalized), intensity 0..1, and
/// size (physical breadth; 120 = web default — bigger softens/widens shadows).
public struct LightState: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var intensity: Double
    public var size: Double

    public init(x: Double = 0.8, y: Double = 0.18, intensity: Double = 1, size: Double = 120) {
        self.x = x
        self.y = y
        self.intensity = intensity
        self.size = size
    }

    private enum CodingKeys: String, CodingKey { case x, y, intensity, size }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 1
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 120
    }
}

/// A light resolved at render time.
public struct ResolvedLight: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var intensity: Double
    public var size: Double

    public init(x: Double, y: Double, intensity: Double, size: Double = 120) {
        self.x = x
        self.y = y
        self.intensity = intensity
        self.size = size
    }
}

public struct LightTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var hidden: Bool
    public var locked: Bool
    public var cues: [LightCue]
    public var presence: [VisibilityEvent]

    public init(id: String, name: String, hidden: Bool = false, locked: Bool = false,
                cues: [LightCue] = [],
                presence: [VisibilityEvent] = []) {
        self.id = id
        self.name = name
        self.hidden = hidden
        self.locked = locked
        self.cues = cues
        self.presence = presence
    }

    private enum CodingKeys: String, CodingKey { case id, name, hidden, locked, cues, presence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        cues = try c.decodeIfPresent([LightCue].self, forKey: .cues) ?? []
        presence = try c.decodeIfPresent([VisibilityEvent].self, forKey: .presence) ?? []
    }
}

public struct LightCue: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var start: Double
    public var dur: Double
    public var from: LightState
    /// State at cue end; nil = static. Linear interpolation between.
    public var to: LightState?
    public var label: String?

    public init(id: String, start: Double, dur: Double, from: LightState,
                to: LightState? = nil, label: String? = nil) {
        self.id = id
        self.start = start
        self.dur = dur
        self.from = from
        self.to = to
        self.label = label
    }

    public func state(at t: Double) -> LightState {
        guard let to, dur > 0 else { return from }
        let k = min(1, max(0, (t - start) / dur))
        return LightState(x: from.x + (to.x - from.x) * k,
                          y: from.y + (to.y - from.y) * k,
                          intensity: from.intensity + (to.intensity - from.intensity) * k,
                          size: from.size + (to.size - from.size) * k)
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
