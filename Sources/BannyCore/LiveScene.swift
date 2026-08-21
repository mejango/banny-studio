import Foundation

/// Live mode: a scene described once, then performed indefinitely by a model.
///
/// The division of labour is deliberate. The model writes the *script* — who
/// speaks, what they say, who moves to which part of the room. Everything that
/// makes a scene watchable rather than merely valid is compiled deterministically
/// from those beats: horizontal zones so concurrent conversations stay legible,
/// facing resolved against the real timeline, walks that cannot interrupt each
/// other, captions anchored over their speaker. A prompt cannot be trusted to
/// hold those invariants; a compiler can.

/// What the user sets up before pressing play.
public struct LiveBrief: Codable, Equatable, Sendable {
    /// Backdrop image or video, relative to the brief file.
    public var background: String
    /// Optional music bed. The only audio in a live scene — performers mime.
    public var backingTrack: String?
    /// Hard stop in seconds, or 0 for open-ended. A live scene has no planned
    /// length: it is as long as the sections the director chooses to commission.
    public var duration: Double
    /// Which model writes the script. See `LiveModel`.
    public var model: String
    public var frameW: Double
    public var frameH: Double
    /// Free text setting the situation: where this is, what the occasion is.
    public var premise: String
    /// Links the cast should know about — what they are discussing, arguing
    /// over, or playing with. Handed to the agent to read for itself.
    public var references: String
    public var cast: [LiveCastMember]
    /// Whether the scene may bring on people who were never cast. A bar fills
    /// up with strangers; a two-hander does not.
    public var mayAddCast: Bool
    /// Whether the scene dresses anyone the director left alone. A costume is a
    /// character note, and the model has read the premise.
    public var mayDressCast: Bool
    /// What there is to wear, as slot number to item names. Filled from the
    /// real catalog so the model can only pick things that exist.
    public var wardrobe: [String: [String]]
    /// Whether to find the point lights in a still backdrop and make them
    /// twinkle. Costs one encode at setup and nothing afterwards.
    public var shimmerBackdrop: Bool

    public init(background: String = "", backingTrack: String? = nil,
                duration: Double = 0, model: String = "claude",
                frameW: Double = 16, frameH: Double = 9,
                premise: String = "", references: String = "",
                cast: [LiveCastMember] = [],
                mayAddCast: Bool = true, mayDressCast: Bool = true,
                wardrobe: [String: [String]] = [:],
                shimmerBackdrop: Bool = true) {
        self.background = background
        self.backingTrack = backingTrack
        self.duration = duration
        self.model = model
        self.frameW = frameW
        self.frameH = frameH
        self.premise = premise
        self.references = references
        self.cast = cast
        self.mayAddCast = mayAddCast
        self.mayDressCast = mayDressCast
        self.wardrobe = wardrobe
        self.shimmerBackdrop = shimmerBackdrop
    }
}

public struct LiveCastMember: Codable, Equatable, Sendable {
    public var name: String
    public var body: Body
    /// Slot number to item name, as in `character.baseOutfit`.
    public var outfit: [String: String]
    /// Who they are and how they behave. Handed to the model verbatim.
    public var prompt: String
    /// Wardrobe changes should be rare and mean something, so they are off
    /// unless the scene explicitly allows this performer to change.
    public var mayChangeWardrobe: Bool
    /// True when the director picked this outfit by hand. The scene dresses
    /// everyone else, but never overrules a deliberate choice.
    public var outfitIsChosen: Bool
    /// Walking pace; the loud one arrives faster than the reluctant one.
    public var speed: Double

    /// True when this is the banny every new show opens with, rather than
    /// somebody the director asked for.
    ///
    /// The placeholder gets into the brief by more than one route — a new
    /// document, an older show, a scene already written over the top of one —
    /// so it is caught here, where the cast is used, rather than at each door
    /// it might come through. A cast of nothing but placeholders is no cast:
    /// left alone it becomes a company of one, the model writes a two-hander
    /// anyway, and every line belonging to the voice that was never cast is
    /// dropped on the way to the stage.
    public var isPlaceholder: Bool {
        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              outfit.isEmpty
        else { return false }
        let bare = name.trimmingCharacters(in: .whitespaces)
        guard bare.isEmpty || bare.lowercased().hasPrefix("banny") else { return false }
        // "Banny", "Banny 1", "Banny 10" — the name and a number, nothing else.
        let tail = bare.dropFirst("banny".count).trimmingCharacters(in: .whitespaces)
        return tail.isEmpty || tail.allSatisfy(\.isNumber)
    }

    /// Nobody turns up undressed. Slots and item names come from the real
    /// catalog: 12 head top, 11 suit top, 9 body, 6 glasses, 13 hand.
    ///
    /// **Hands stay empty.** Clothes travel — a chef's hat is a person, and it
    /// reads the same in any room. A prop does not: a beer names the place,
    /// and these defaults were written for a bar, so every scene since has
    /// been holding a drink in an office at four in the afternoon. What people
    /// carry is the scene's business, chosen once the room is known.
    public static func defaultOutfit(_ n: Int) -> [String: String] {
        let looks: [[String: String]] = [
            ["12": "chef-hat", "11": "doc-coat"],
            ["12": "natty-dred", "11": "irie-shirt"],
            ["6": "cyberpunk-glasses", "11": "punk-jacket"],
            ["12": "club-beanie", "11": "zipper-jacket"],
            ["12": "farmer-hat", "9": "overalls"],
            ["6": "investor-shades", "11": "goat-jersey"],
            ["12": "proff-hair", "11": "zucco-tshirt"],
            ["12": "headphones", "11": "ice-cube"],
            ["12": "geisha-hair", "9": "geisha-body"],
            ["6": "nerd", "9": "sweatsuit"],
        ]
        return looks[((n % looks.count) + looks.count) % looks.count]
    }

    public init(name: String, body: Body, outfit: [String: String] = [:],
                prompt: String = "", mayChangeWardrobe: Bool = false,
                speed: Double = 110, outfitIsChosen: Bool = false) {
        self.name = name
        self.body = body
        self.outfit = outfit
        self.prompt = prompt
        self.mayChangeWardrobe = mayChangeWardrobe
        self.speed = speed
        self.outfitIsChosen = outfitIsChosen
    }
}

/// Where a performer can be asked to stand. Concrete positions are the
/// compiler's business — the model only names a part of the room, so it can
/// never place two conversations on top of each other.
public enum LiveZone: String, Codable, CaseIterable, Sendable {
    case front      // the near row, camera left
    case middle     // the main group
    case far        // the far corner
    case offstage   // out of shot

    /// Normalized x span. Wide enough that two people standing in one can be
    /// a comfortable body-width apart — a banny is roughly 0.16 of the frame
    /// across, so a narrow zone guarantees the pile-up it was meant to prevent.
    public var span: ClosedRange<Double> {
        switch self {
        // Three zones and two gaps across the frame, every one of them at
        // least a body wide: 0.18 zone, 0.20 gap, 0.18, 0.20, 0.18.
        case .front: return 0.03...0.21
        case .middle: return 0.41...0.59
        case .far: return 0.79...0.97
        case .offstage: return -0.22...(-0.18)
        }
    }

    /// How far back the zone stands. Separating the groups in depth as well as
    /// across does most of the work of telling them apart: they differ in size
    /// and in where they sit on the floor, not only in x.
    public var depth: Double {
        switch self {
        case .front: return 0.0
        case .middle: return 0.20
        case .far: return 0.42
        case .offstage: return 0.06
        }
    }
}

public enum LiveLineKind: String, Codable, Sendable {
    case say        // an ordinary turn
    case cut        // takes the floor before the previous speaker finishes
    case over       // lands on top of a line that carries on
    case quiet      // leans in; said for one person only
    case laugh      // the room goes after it
}

/// One instruction from the model. Deliberately small: anything the model is
/// not asked for is something it cannot get wrong.
public enum LiveBeat: Equatable, Sendable {
    case line(who: String, text: String, kind: LiveLineKind)
    case move(who: String, zone: LiveZone)
    case enters(who: String, zone: LiveZone)
    case exits(who: String)
    case gesture(who: String, name: String)
    case wardrobe(who: String, slot: Int, item: String?)
    case hold(seconds: Double)
}

extension LiveBeat: Codable {
    private enum CodingKeys: String, CodingKey {
        case beat, who, text, kind, zone, name, slot, item, seconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let beat = try c.decode(String.self, forKey: .beat)
        func who() throws -> String { try c.decode(String.self, forKey: .who) }
        switch beat {
        case "line":
            self = .line(who: try who(),
                         text: try c.decode(String.self, forKey: .text),
                         kind: try c.decodeIfPresent(LiveLineKind.self, forKey: .kind) ?? .say)
        case "move":
            self = .move(who: try who(), zone: try c.decode(LiveZone.self, forKey: .zone))
        case "enters":
            self = .enters(who: try who(),
                           zone: try c.decodeIfPresent(LiveZone.self, forKey: .zone) ?? .middle)
        case "exits":
            self = .exits(who: try who())
        case "gesture":
            self = .gesture(who: try who(), name: try c.decode(String.self, forKey: .name))
        case "wardrobe":
            self = .wardrobe(who: try who(),
                             slot: try c.decode(Int.self, forKey: .slot),
                             item: try c.decodeIfPresent(String.self, forKey: .item))
        case "hold":
            self = .hold(seconds: try c.decode(Double.self, forKey: .seconds))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .beat, in: c,
                debugDescription: "unknown beat \"\(beat)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .line(who, text, kind):
            try c.encode("line", forKey: .beat); try c.encode(who, forKey: .who)
            try c.encode(text, forKey: .text); try c.encode(kind, forKey: .kind)
        case let .move(who, zone):
            try c.encode("move", forKey: .beat); try c.encode(who, forKey: .who)
            try c.encode(zone, forKey: .zone)
        case let .enters(who, zone):
            try c.encode("enters", forKey: .beat); try c.encode(who, forKey: .who)
            try c.encode(zone, forKey: .zone)
        case let .exits(who):
            try c.encode("exits", forKey: .beat); try c.encode(who, forKey: .who)
        case let .gesture(who, name):
            try c.encode("gesture", forKey: .beat); try c.encode(who, forKey: .who)
            try c.encode(name, forKey: .name)
        case let .wardrobe(who, slot, item):
            try c.encode("wardrobe", forKey: .beat); try c.encode(who, forKey: .who)
            try c.encode(slot, forKey: .slot); try c.encodeIfPresent(item, forKey: .item)
        case let .hold(seconds):
            try c.encode("hold", forKey: .beat); try c.encode(seconds, forKey: .seconds)
        }
    }

    public var who: String? {
        switch self {
        case let .line(who, _, _), let .move(who, _), let .enters(who, _),
             let .exits(who), let .gesture(who, _), let .wardrobe(who, _, _):
            return who
        case .hold:
            return nil
        }
    }
}

/// What the model is asked to return each round.
public struct LiveBeatBatch: Codable, Equatable, Sendable {
    public var beats: [LiveBeat]
    public init(beats: [LiveBeat]) { self.beats = beats }
}
