import Foundation
import Testing
@testable import BannyRender
@testable import BannyCore

/// Captions may name their own spot on screen, so concurrent conversations can
/// each be captioned over the pair having them. Captions without placement keep
/// the original single stacked block.
struct PlacedCaptionTests {
    let W = 1920.0, H = 1080.0

    @Test func placementIsOptional() {
        let plain = Subtitle(text: "hi", start: 0, dur: 1)
        #expect(!plain.isPlaced)
        #expect(Subtitle(text: "hi", start: 0, dur: 1, x: 0.2, y: 0.3).isPlaced)
        // Half a placement is not a placement — it would be ambiguous.
        #expect(!Subtitle(text: "hi", start: 0, dur: 1, x: 0.2).isPlaced)
    }

    @Test func boxCentresOnItsAnchor() throws {
        let l = try #require(CaptionLayoutEngine.placed(
            text: "over here", frameWidth: W, outputHeight: H,
            anchorX: 0.25, anchorY: 0.40))
        #expect(abs((l.boxX + l.boxWidth / 2) - 0.25 * W) < 1.0)
        #expect(abs((l.boxY + l.boxHeight / 2) - 0.40 * H) < 1.0)
    }

    @Test func twoCaptionsCanSitApartAtOnce() throws {
        let left = try #require(CaptionLayoutEngine.placed(
            text: "left conversation", frameWidth: W, outputHeight: H,
            anchorX: 0.2, anchorY: 0.5))
        let right = try #require(CaptionLayoutEngine.placed(
            text: "right conversation", frameWidth: W, outputHeight: H,
            anchorX: 0.8, anchorY: 0.5))
        #expect(left.boxX + left.boxWidth < right.boxX)   // genuinely disjoint
    }

    @Test func sizeScalesTheType() throws {
        let small = try #require(CaptionLayoutEngine.placed(
            text: "same words", frameWidth: W, outputHeight: H,
            anchorX: 0.5, anchorY: 0.5, size: 0.6))
        let big = try #require(CaptionLayoutEngine.placed(
            text: "same words", frameWidth: W, outputHeight: H,
            anchorX: 0.5, anchorY: 0.5, size: 1.8))
        #expect(big.fontSize > small.fontSize * 2.5)
        #expect(big.boxHeight > small.boxHeight)
    }

    @Test func widthCapsTheBoxAndForcesWrapping() throws {
        let wide = try #require(CaptionLayoutEngine.placed(
            text: "a reasonably long line of dialogue that has to wrap somewhere",
            frameWidth: W, outputHeight: H, anchorX: 0.5, anchorY: 0.5, maxWidth: 0.8))
        let narrow = try #require(CaptionLayoutEngine.placed(
            text: "a reasonably long line of dialogue that has to wrap somewhere",
            frameWidth: W, outputHeight: H, anchorX: 0.5, anchorY: 0.5, maxWidth: 0.2))
        #expect(narrow.boxWidth < wide.boxWidth)
        #expect(narrow.lines.count > wide.lines.count)
        #expect(narrow.boxWidth <= 0.2 * W + 1)
    }

    /// An anchor near an edge must not push the box off screen.
    @Test func boxStaysInsideTheFrame() throws {
        for (ax, ay) in [(0.0, 0.0), (1.0, 1.0), (0.0, 1.0), (1.0, 0.0)] {
            let l = try #require(CaptionLayoutEngine.placed(
                text: "pinned to a corner", frameWidth: W, outputHeight: H,
                anchorX: ax, anchorY: ay))
            #expect(l.boxX >= 0)
            #expect(l.boxY >= 0)
            #expect(l.boxX + l.boxWidth <= W)
            #expect(l.boxY + l.boxHeight <= H)
        }
    }

    @Test func placementSurvivesTheRoundTrip() throws {
        let s = Subtitle(text: "hi", start: 1, dur: 2, x: 0.3, y: 0.2, size: 1.4, width: 0.5)
        let back = try JSONDecoder().decode(
            Subtitle.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func omittedPlacementDecodesToNil() throws {
        let json = #"{"text":"hi","start":0,"dur":1}"#
        let s = try JSONDecoder().decode(Subtitle.self, from: Data(json.utf8))
        #expect(s.x == nil && s.y == nil && s.size == nil && s.width == nil)
        #expect(!s.isPlaced)
    }
}

/// Concurrent captions must all stay readable — that is the whole point of
/// letting them be placed independently.
struct CaptionStackingTests {
    let H = 1080.0
    func box(_ x: Double, _ y: Double, _ w: Double = 400, _ h: Double = 80) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    @Test func boxesThatDoNotTouchAreLeftAlone() {
        let input = [box(0, 800), box(900, 800)]
        let out = CaptionLayoutEngine.stack(input, gap: 12, height: H)
        #expect(out == input)
    }

    @Test func aClashIsPushedClearAndStaysClear() {
        // Two captions asking for nearly the same spot.
        let out = CaptionLayoutEngine.stack([box(100, 500), box(180, 505)],
                                            gap: 12, height: H)
        #expect(out.count == 2)
        #expect(!out[0].insetBy(dx: -1, dy: -1).intersects(out[1]))
        #expect(out[1].maxY <= out[0].minY)          // the later one went above
    }

    @Test func orderIsPreservedSoCallersCanZipThemBack() {
        let input = [box(0, 600), box(20, 605), box(40, 610)]
        let out = CaptionLayoutEngine.stack(input, gap: 10, height: H)
        #expect(out.count == input.count)
        #expect(out[0].minX == 0 && out[1].minX == 20 && out[2].minX == 40)
    }

    @Test func everythingStaysOnScreenEvenWhenCrowded() {
        let many = (0..<8).map { box(200, 300 + Double($0) * 4) }
        let out = CaptionLayoutEngine.stack(many, gap: 10, height: H)
        for r in out {
            #expect(r.minY >= 0)
            #expect(r.maxY <= H)
        }
    }

    @Test func runningOutOfHeadroomDropsBelowInsteadOfOffTheTop() {
        // Six stacked boxes cannot fit above y=200, so later ones go downward.
        let many = (0..<6).map { box(200, 150 + Double($0) * 3) }
        let out = CaptionLayoutEngine.stack(many, gap: 10, height: H)
        #expect(out.allSatisfy { $0.minY >= 0 })
        for i in out.indices {
            for j in out.indices where j > i {
                #expect(!out[i].insetBy(dx: -1, dy: -1).intersects(out[j]))
            }
        }
    }
}

/// A placed caption belongs to a body on screen. If that body is gone — walked
/// off or dissolved out — the caption goes with it.
struct PlacedCaptionPresenceTests {
    @Test func absentSpeakerHasNoPresence() {
        let gone = [VisibilityEvent(t: 10, visible: false)]
        #expect(gone.opacity(at: 11) == 0)          // renderer drops the caption
        #expect(gone.opacity(at: 9) == 1)           // and keeps it before that
    }

    @Test func aDissolvingSpeakerKeepsTheCaptionUntilMostlyGone() {
        let fading = [VisibilityEvent(t: 10, visible: false, fade: 1)]
        #expect(fading.opacity(at: 9.6) > 0.05)     // still there, still captioned
        #expect(fading.opacity(at: 10.49) < 0.05)   // as good as gone
    }
}
