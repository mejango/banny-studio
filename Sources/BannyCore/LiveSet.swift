import Foundation

/// The stage as read from the backdrop.
///
/// Without this, a live scene is staged in a generic wide room that happens to
/// have the user's picture behind it: the zones are fixed constants whether the
/// backdrop is a bar, a beach or a lift, and the cast's feet meet the floor by
/// coincidence. A room describes where people can actually stand in *this*
/// picture, and how big a person is when they stand there.
///
/// Every field is optional in the sense that a missing or nonsensical one falls
/// back to the built-in staging. A bad read must never be worse than no read.
public struct LiveSet: Codable, Equatable, Sendable {
    public struct Spot: Codable, Equatable, Sendable {
        /// Normalized x range this group occupies.
        public var from: Double
        public var to: Double
        /// How far back it stands, 0 nearest the camera.
        public var depth: Double

        public init(from: Double, to: Double, depth: Double) {
            self.from = from
            self.to = to
            self.depth = depth
        }

        var span: ClosedRange<Double> { min(from, to)...max(from, to) }
    }

    /// Standable areas, keyed by zone name: front, middle, far.
    public var zones: [String: Spot]
    /// Stage scale for this room — how large a performer is against this art.
    public var gSize: Double?
    /// One line on why the room was read this way, shown in the app.
    public var reading: String?

    public init(zones: [String: Spot] = [:], gSize: Double? = nil,
                reading: String? = nil) {
        self.zones = zones
        self.gSize = gSize
        self.reading = reading
    }

    /// Where this zone stands in this room, or the built-in staging when the
    /// room has nothing usable to say about it.
    public func span(for zone: LiveZone) -> ClosedRange<Double> {
        guard let spot = zones[zone.rawValue] else { return zone.span }
        let span = spot.span
        // A zone narrower than a body, or off the edge of the frame, is worse
        // than the default it replaced.
        guard span.lowerBound >= -0.05, span.upperBound <= 1.05,
              span.upperBound - span.lowerBound >= LiveCompiler.minimumGap
        else { return zone.span }
        return span
    }

    public func depth(for zone: LiveZone) -> Double {
        guard let spot = zones[zone.rawValue], (-0.2...0.9).contains(spot.depth)
        else { return zone.depth }
        return spot.depth
    }

    /// True when the read produced enough to stage with. A room that only names
    /// one zone, or names them all on top of each other, is discarded.
    public var isUsable: Bool {
        let named = LiveZone.allCases.filter { $0 != .offstage }
            .compactMap { zones[$0.rawValue] }
        guard named.count >= 2 else { return false }
        let sorted = named.map(\.span).sorted { $0.lowerBound < $1.lowerBound }
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.lowerBound < a.upperBound {
            return false          // groups would sit inside each other
        }
        return true
    }

    /// What the model is asked, once, before the scene starts. It is given the
    /// backdrop to look at; everything here is about *this* picture.
    public static func prompt(imagePath: String, premise: String,
                              cast: Int) -> String {
        """
        Look at the image at \(imagePath). It is the set for a scene, and \
        pixel-art characters will be staged standing in it.

        THE SCENE
        \(premise)

        Work out where \(cast) or so characters can plausibly stand on the \
        floor of this room, in three groups across the frame, and how large a \
        person should be so they belong in the picture rather than sitting on \
        top of it.

        Coordinates are fractions of the image: x 0 is the left edge, 1 the \
        right. Depth is 0 for the nearest standable floor and 1 for the far \
        wall — use it for how far back a group stands, which also decides how \
        small they are.

        Three groups, left to right, named front, middle and far. Each needs a \
        clear stretch of walkable floor at least 0.17 wide, and they must not \
        overlap. Avoid anything a person cannot stand on or in — a bar counter, \
        a table, water, a wall.

        `gSize` is the character scale, where 1.7 suits a room whose floor \
        fills the lower third of the frame. Make a person shorter than the \
        doorways and taller than the furniture.

        Return ONLY this JSON, no prose:
        {"zones":{"front":{"from":0.0,"to":0.0,"depth":0.0},
                  "middle":{"from":0.0,"to":0.0,"depth":0.0},
                  "far":{"from":0.0,"to":0.0,"depth":0.0}},
         "gSize":1.7,
         "reading":"one sentence on what you saw"}
        """
    }

    /// Pulls a room out of whatever the model said, the same way beats are
    /// found: the first object that decodes and is usable wins.
    public static func parse(_ answer: String) -> LiveSet? {
        for object in LiveJSON.objects(in: answer) {
            if let room = try? JSONDecoder().decode(LiveSet.self, from: Data(object.utf8)),
               room.isUsable {
                return room
            }
        }
        return nil
    }
}
