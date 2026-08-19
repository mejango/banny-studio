import Foundation
import Testing
@testable import BannyCore

/// Reading the backdrop replaces the built-in staging with something derived
/// from the actual picture. The governing rule is that a bad read must never be
/// worse than no read at all — every doubtful value falls back.
struct LiveSetTests {
    func room(_ json: String) -> LiveSet? { LiveSet.parse(json) }

    let good = """
    {"zones":{"front":{"from":0.05,"to":0.30,"depth":0.0},
              "middle":{"from":0.40,"to":0.60,"depth":0.25},
              "far":{"from":0.70,"to":0.95,"depth":0.5}},
     "gSize":2.1,"reading":"bar along the back, open floor in front"}
    """

    @Test func aGoodReadReplacesTheBuiltInStaging() throws {
        let r = try #require(room(good))
        #expect(r.span(for: .front) == 0.05...0.30)
        #expect(r.depth(for: .middle) == 0.25)
        #expect(r.gSize == 2.1)
        #expect(r.reading?.isEmpty == false)
    }

    @Test func theCompilerStagesToTheRoom() {
        let r = room(good)
        let xs = LiveCompiler.positions(in: .far, count: 2, room: r)
        #expect(xs.allSatisfy { (0.70...0.95).contains($0) },
                "the far group ignored the room: \(xs)")
        // And without one, the built-in zone still governs.
        let fallback = LiveCompiler.positions(in: .far, count: 2)
        #expect(fallback.allSatisfy { LiveZone.far.span.contains($0) })
    }

    @Test func aZoneNarrowerThanABodyIsRefused() throws {
        let r = try #require(room("""
        {"zones":{"front":{"from":0.10,"to":0.12,"depth":0.0},
                  "middle":{"from":0.40,"to":0.60,"depth":0.2},
                  "far":{"from":0.70,"to":0.95,"depth":0.4}}}
        """))
        // Too narrow to hold anyone: keep the built-in front zone.
        #expect(r.span(for: .front) == LiveZone.front.span)
        #expect(r.span(for: .middle) == 0.40...0.60)
    }

    @Test func aZoneOffTheEdgeOfTheFrameIsRefused() throws {
        let r = try #require(room("""
        {"zones":{"front":{"from":-0.4,"to":0.2,"depth":0.0},
                  "middle":{"from":0.40,"to":0.60,"depth":0.2},
                  "far":{"from":0.70,"to":0.95,"depth":0.4}}}
        """))
        #expect(r.span(for: .front) == LiveZone.front.span)
    }

    @Test func anAbsurdDepthIsRefused() throws {
        let r = try #require(room("""
        {"zones":{"front":{"from":0.05,"to":0.30,"depth":7.0},
                  "middle":{"from":0.40,"to":0.60,"depth":0.2},
                  "far":{"from":0.70,"to":0.95,"depth":0.4}}}
        """))
        #expect(r.depth(for: .front) == LiveZone.front.depth)
    }

    /// Groups sitting inside each other is the exact thing zones exist to
    /// prevent, so a read that does it is thrown away whole.
    @Test func overlappingGroupsAreRejectedOutright() {
        #expect(room("""
        {"zones":{"front":{"from":0.05,"to":0.50,"depth":0.0},
                  "middle":{"from":0.40,"to":0.70,"depth":0.2},
                  "far":{"from":0.70,"to":0.95,"depth":0.4}}}
        """) == nil)
    }

    @Test func aReadNamingOnlyOneGroupIsRejected() {
        #expect(room("""
        {"zones":{"middle":{"from":0.40,"to":0.60,"depth":0.2}}}
        """) == nil)
    }

    @Test func prosePastTheAnswerDoesNotDefeatIt() throws {
        let r = try #require(room("Here is the room:\n```json\n\(good)\n```\nHope that helps."))
        #expect(r.gSize == 2.1)
    }

    @Test func nonsenseIsSimplyNoRoom() {
        #expect(room("I could not open that file.") == nil)
        #expect(room("{\"error\":\"nope\"}") == nil)
    }

    /// A real answer, from Claude reading the sunset bar backdrop we shot the
    /// 30-minute film on. Kept verbatim: a fixture the model actually produced
    /// is worth more than one I would have invented.
    @Test func arealReadOfTheSunsetBarIsAccepted() throws {
        let answer = """
        {"zones":{"front":{"from":0.05,"to":0.24,"depth":0.10},\
        "middle":{"from":0.28,"to":0.47,"depth":0.14},\
        "far":{"from":0.51,"to":0.70,"depth":0.18}},"gSize":1.9,\
        "reading":"A beach bar at sunset: a tiled counter with drinks and three \
        barstools spans the left two-thirds, ocean and setting sun behind it, \
        palms rooted in the bottom-right tiles, so the only walkable floor is \
        the near strip in front of the counter (left of the palm trunks)."}
        """
        let r = try #require(room(answer))
        #expect(r.span(for: .front) == 0.05...0.24)
        #expect(r.span(for: .far) == 0.51...0.70)
        #expect(r.gSize == 1.9)
        // Every group is wide enough to hold a pair, and none overlap.
        for zone in [LiveZone.front, .middle, .far] {
            let span = r.span(for: zone)
            #expect(span.upperBound - span.lowerBound >= LiveCompiler.minimumGap - 1e-9)
        }
        // And the cast is staged onto the walkable strip, not the palms.
        let xs = LiveCompiler.positions(in: .far, count: 2, room: r)
        #expect(xs.allSatisfy { $0 <= 0.71 }, "staged into the palms: \(xs)")
    }

    @Test func theQuestionNamesTheFileAndTheScene() {
        let p = LiveSet.prompt(imagePath: "/tmp/bar.png",
                                premise: "A quiet bar at closing time.", cast: 3)
        #expect(p.contains("/tmp/bar.png"))
        #expect(p.contains("A quiet bar at closing time."))
        // It must ask for standable floor, not merely for coordinates.
        #expect(p.contains("cannot stand on"))
        #expect(p.contains("0.17"))
    }
}

/// The set editor writes zones by hand, so a hand-placed set has to survive the
/// same journey a read one does.
struct LiveSetEditingTests {
    @Test func aHandPlacedSetRoundTripsThroughStorage() throws {
        let placed = LiveSet(zones: [
            "front": .init(from: 0.04, to: 0.26, depth: 0.02),
            "middle": .init(from: 0.34, to: 0.52, depth: 0.18),
            "far": .init(from: 0.60, to: 0.82, depth: 0.40),
        ], gSize: 1.9, reading: "Placed by hand.")
        let back = try JSONDecoder().decode(
            LiveSet.self, from: JSONEncoder().encode(placed))
        #expect(back == placed)
        #expect(back.isUsable)
        #expect(back.span(for: .middle) == 0.34...0.52)
    }

    /// Dragging a band narrower than a body is possible; staging must still
    /// hold the line the same way it does for a bad read.
    @Test func aBandDraggedTooNarrowFallsBackToTheBuiltIn() {
        let pinched = LiveSet(zones: [
            "front": .init(from: 0.30, to: 0.34, depth: 0.0),
            "middle": .init(from: 0.44, to: 0.62, depth: 0.2),
            "far": .init(from: 0.72, to: 0.94, depth: 0.4),
        ])
        #expect(pinched.span(for: .front) == LiveZone.front.span)
        #expect(pinched.span(for: .middle) == 0.44...0.62)
    }

    /// The editor draws each band where the feet land, and reads a drag back
    /// through the same curve. The two must agree or a band drifts as you drag.
    @Test func theGroundPlaneInvertsCleanly() {
        func feet(_ d: Double) -> Double {
            let up = max(0, d)
            let lift = 0.09 * up + 0.33 * (up * up) * (3 - 2 * up)
            return 0.929 - lift + max(0, -d) * 0.09
        }
        func depth(atFeetY y: Double) -> Double {
            var best = 0.0, error = Double.infinity
            var d = -0.1
            while d <= 0.9 {
                let e = abs(feet(d) - y)
                if e < error { error = e; best = d }
                d += 0.005
            }
            return best
        }
        // Monotonic, so a walk finds it: further back is always higher up.
        for d in stride(from: -0.1, through: 0.85, by: 0.05) {
            #expect(abs(depth(atFeetY: feet(d)) - d) < 0.01,
                    "depth \(d) did not survive the round trip")
        }
        #expect(feet(0.0) > feet(0.5), "further away must sit higher in frame")
    }
}
