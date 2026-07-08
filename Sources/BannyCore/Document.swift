import Foundation

/// Banny Studio document model, schema v2.
/// Concepts map 1:1 to the web v1 studio; see docs/superpowers/specs/2026-07-07-banny-studio-native-design.md.

public struct ShowDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var scenes: [Scene]
    public var show: [ShowSegment]
    public var settings: Settings

    public init(version: Int = 2, scenes: [Scene] = [], show: [ShowSegment] = [], settings: Settings = Settings()) {
        self.version = version
        self.scenes = scenes
        self.show = show
        self.settings = settings
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

/// A show playlist segment: a time slice of one scene.
public struct ShowSegment: Codable, Equatable, Sendable {
    public var sceneID: String
    public var name: String
    public var from: Double
    public var to: Double

    public init(sceneID: String, name: String, from: Double, to: Double) {
        self.sceneID = sceneID
        self.name = name
        self.from = from
        self.to = to
    }
}

public struct SceneState: Codable, Equatable, Sendable {
    public var characters: [Character]
    public var audioTracks: [AudioTrack]
    public var lights: [Light]
    /// Crop anchor times (seconds) that split the timeline into Show segments.
    public var cropAnchors: [Double]
    /// Depth→scale intensity (web slider 0..1.2).
    public var gScale: Double
    /// Jump gravity (0.3..2.5).
    public var gravity: Double
    /// Base size multiplier (0.3..2.5).
    public var gSize: Double
    public var background: BackgroundSpec?

    public init(characters: [Character] = [], audioTracks: [AudioTrack] = [], lights: [Light] = [],
                cropAnchors: [Double] = [], gScale: Double = 0.6, gravity: Double = 1, gSize: Double = 1,
                background: BackgroundSpec? = nil) {
        self.characters = characters
        self.audioTracks = audioTracks
        self.lights = lights
        self.cropAnchors = cropAnchors
        self.gScale = gScale
        self.gravity = gravity
        self.gSize = gSize
        self.background = background
    }
}

public enum Body: String, Codable, CaseIterable, Sendable {
    case orange, original, pink, alien
}

public struct Character: Codable, Equatable, Sendable {
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

    public init(body: Body, x: Double = 0.5, depth: Double = 0, size: Double = 1, face: Int = 1,
                baseOutfit: [Int: String] = [:], subs: [Subtitle] = [], clips: [AudioClip] = [],
                events: [PerfEvent] = [], armedGroups: Set<EventGroup> = Set(EventGroup.allCases),
                name: String = "", trackFx: Fx = .defaultTrack, recStart: StartPose? = nil,
                speed: Double = 320, wobble: Double = 7) {
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

    public init(id: String, name: String, fx: Fx = .defaultTrack, clips: [AudioClip] = []) {
        self.id = id
        self.name = name
        self.fx = fx
        self.clips = clips
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
