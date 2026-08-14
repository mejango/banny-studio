import Foundation
import Testing
@testable import BannyCore

/// A presence toggle can carry a `fade`, dissolving a performer in or out
/// instead of cutting. No fade must behave exactly as before.
struct PresenceFadeTests {
    @Test func withoutFadeTheToggleStaysAHardCut() {
        let p = [VisibilityEvent(t: 0, visible: false), VisibilityEvent(t: 10, visible: true)]
        #expect(p.opacity(at: 9.999) == 0)
        #expect(p.opacity(at: 10) == 1)
        #expect(p.isPresent(at: 10))
        #expect(!p.isPresent(at: 9.999))
    }

    @Test func defaultsToVisibleWithNoEvents() {
        let empty: [VisibilityEvent] = []
        #expect(empty.opacity(at: 0) == 1)
        #expect(empty.isPresent(at: 123) == true)
    }

    @Test func spawnFadeIsCentredOnTheToggle() {
        // A 1s spawn at t=10 runs 9.5 -> 10.5, so the toggle time is the
        // midpoint of the dissolve rather than its start.
        let p = [VisibilityEvent(t: 0, visible: false),
                 VisibilityEvent(t: 10, visible: true, fade: 1)]
        #expect(p.opacity(at: 9.4) == 0)
        #expect(abs(p.opacity(at: 10.0) - 0.5) < 1e-9)
        #expect(p.opacity(at: 10.6) == 1)
    }

    @Test func unspawnFadeRunsTheOtherWay() {
        let p = [VisibilityEvent(t: 20, visible: false, fade: 2)]
        #expect(p.opacity(at: 18.9) == 1)
        #expect(abs(p.opacity(at: 20.0) - 0.5) < 1e-9)
        #expect(p.opacity(at: 21.1) == 0)
        #expect(!p.isPresent(at: 21.1))
    }

    /// Mid-dissolve the performer is partly there, which is what lets the
    /// renderer draw them at reduced alpha instead of popping.
    @Test func isPresentCoversTheWholeDissolve() {
        let p = [VisibilityEvent(t: 0, visible: false),
                 VisibilityEvent(t: 10, visible: true, fade: 1)]
        #expect(!p.isPresent(at: 9.4))
        #expect(p.isPresent(at: 9.8))
        #expect(p.isPresent(at: 10.6))
    }

    @Test func fadeSurvivesTheRoundTrip() throws {
        let p = [VisibilityEvent(t: 4, visible: true, fade: 0.6)]
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode([VisibilityEvent].self, from: data)
        #expect(back == p)
        #expect(back[0].fade == 0.6)
    }

    @Test func omittedFadeDecodesToNil() throws {
        let json = #"[{"t":3,"visible":false}]"#
        let p = try JSONDecoder().decode([VisibilityEvent].self, from: Data(json.utf8))
        #expect(p[0].fade == nil)
        #expect(p.opacity(at: 3) == 0)
    }

    @Test func negativeFadeIsTreatedAsAHardCut() {
        let p = [VisibilityEvent(t: 5, visible: false, fade: -2)]
        #expect(p.opacity(at: 4.999) == 1)
        #expect(p.opacity(at: 5) == 0)
    }
}
