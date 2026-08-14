import Foundation
import Testing
@testable import BannyCore

/// `wings` widens the stage so performers can walk fully out of frame and wait
/// there. Zero must reproduce the original web-app edge margin exactly — every
/// existing show and the golden fixtures depend on that.
struct StageWingsTests {
    /// Hold one direction long enough to pin against the clamp from centre.
    private func walk(_ code: EventCode, seconds: Double) -> [PerfEvent] {
        [.key(t: 0, code: code, down: true), .key(t: seconds, code: code, down: false)]
    }

    private func x(after events: [PerfEvent], wings: Double, at t: Double,
                   from start: Double = 0.5) -> Double {
        simulatePosition(events: events,
                         recStart: StartPose(x: start, depth: 0, face: 1),
                         speed: 320, gScale: 0.6, wings: wings, at: t).x
    }

    @Test func defaultKeepsTheOriginalEdgeMargin() {
        // 20s at speed 320 is far more travel than the stage is wide.
        #expect(abs(x(after: walk(.arrowRight, seconds: 20), wings: 0, at: 20) - 0.956) < 1e-9)
        #expect(abs(x(after: walk(.arrowLeft, seconds: 20), wings: 0, at: 20) - 0.044) < 1e-9)
    }

    @Test func omittingWingsDecodesToZero() throws {
        let json = #"{"characters":[],"gScale":0.6}"#
        let stage = try JSONDecoder().decode(SceneState.self, from: Data(json.utf8))
        #expect(stage.wings == 0)
    }

    @Test func wingsLetAPerformerLeaveTheFrameEntirely() {
        // A full body is about 0.14 of stage width, so 0.25 of wing is enough
        // to park a performer completely out of shot on either side.
        let right = x(after: walk(.arrowRight, seconds: 20), wings: 0.25, at: 20)
        let left = x(after: walk(.arrowLeft, seconds: 20), wings: 0.25, at: 20)
        #expect(abs(right - 1.206) < 1e-9)
        #expect(abs(left - (-0.206)) < 1e-9)
        #expect(right > 1.0)      // past the right edge of the frame
        #expect(left < 0.0)       // past the left edge
    }

    @Test func performerStaysOffstageUntilWalkedBack() {
        var events = walk(.arrowRight, seconds: 20)
        // Nothing else happens for a minute: the pose must hold off-frame
        // rather than snapping back to the old margin.
        let parked = x(after: events, wings: 0.25, at: 80)
        #expect(parked > 1.0)

        // Walking back in returns them to ordinary stage space.
        events += [.key(t: 80, code: .arrowLeft, down: true),
                   .key(t: 83, code: .arrowLeft, down: false)]
        let returned = x(after: events, wings: 0.25, at: 83)
        #expect(returned < 0.9)
    }

    @Test func negativeWingsAreTreatedAsNone() {
        let clamped = x(after: walk(.arrowRight, seconds: 20), wings: -0.5, at: 20)
        #expect(abs(clamped - 0.956) < 1e-9)
    }

    /// The timeline cache keys on the simulation inputs. Two scenes that differ
    /// only by `wings` must not share a cached timeline.
    @Test func timelineCacheDistinguishesWings() {
        let events = walk(.arrowRight, seconds: 20)
        let start = StartPose(x: 0.5, depth: 0, face: 1)
        let cache = PositionTimelineCache()
        let narrow = cache.timeline(events: events, recStart: start, speed: 320,
                                    gScale: 0.6, wings: 0, coveringAtLeast: 20)
        let wide = cache.timeline(events: events, recStart: start, speed: 320,
                                  gScale: 0.6, wings: 0.25, coveringAtLeast: 20)
        #expect(abs(narrow.pose(at: 20).x - 0.956) < 1e-9)
        #expect(wide.pose(at: 20).x > 1.0)
    }

    /// Checkpointed playback must agree with the one-shot integration off-stage
    /// too, or scrubbing past an exit would disagree with export.
    @Test func checkpointsStayExactOffstage() {
        let events = walk(.arrowRight, seconds: 20)
        let start = StartPose(x: 0.5, depth: 0, face: 1)
        let timeline = PositionTimeline(events: events, recStart: start, speed: 320,
                                        gScale: 0.6, wings: 0.25, upTo: 40,
                                        checkpointStrideSteps: 60)
        for t in stride(from: 0.0, through: 40.0, by: 0.37) {
            let oneShot = simulatePosition(events: events, recStart: start, speed: 320,
                                           gScale: 0.6, wings: 0.25, at: t)
            #expect(abs(timeline.pose(at: t).x - oneShot.x) < 1e-9)
        }
    }
}
