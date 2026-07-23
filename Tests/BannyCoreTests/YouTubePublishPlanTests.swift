import XCTest
@testable import BannyCore

final class YouTubePublishPlanTests: XCTestCase {
    func testChaptersFollowExportRangeAndYouTubeMinimums() {
        var document = ShowDocument.starter(characterCount: 1)
        document.show = [ShowSegment(name: "Cut", from: 20, to: 65)]
        document.stage.markers = [
            TimelineMarker(id: "before", name: "Cold open", start: 15,
                           kind: .section, duration: 15),
            TimelineMarker(id: "middle", name: "The turn", start: 32,
                           kind: .section, duration: 12),
            TimelineMarker(id: "end", name: "Final beat", start: 47,
                           kind: .section, duration: 18),
        ]

        XCTAssertEqual(
            YouTubePublishPlan.chapters(for: document),
            [
                .init(title: "Cold open", seconds: 0),
                .init(title: "The turn", seconds: 12),
                .init(title: "Final beat", seconds: 27),
            ])
        XCTAssertEqual(
            YouTubePublishPlan.chapterText(for: document),
            "0:00 Cold open\n0:12 The turn\n0:27 Final beat")
    }

    func testInvalidChapterTimingProducesNoChapterBlock() {
        var document = ShowDocument.starter(characterCount: 1)
        document.show = [ShowSegment(name: "Cut", from: 0, to: 35)]
        document.stage.markers = [
            TimelineMarker(id: "one", name: "One", start: 0,
                           kind: .section, duration: 5),
            TimelineMarker(id: "two", name: "Two", start: 5,
                           kind: .section, duration: 5),
            TimelineMarker(id: "three", name: "Three", start: 10,
                           kind: .section, duration: 25),
        ]

        XCTAssertTrue(YouTubePublishPlan.chapters(for: document).isEmpty)
        XCTAssertEqual(
            YouTubePublishPlan.description("Description", appendingChaptersFrom: document),
            "Description")
    }

    func testWebVTTClipsAndRetimesCaptions() {
        let character = Character(
            body: .orange,
            subs: [
                Subtitle(text: "Before", start: 5, dur: 4),
                Subtitle(text: "Hello --> there", start: 9, dur: 4),
                Subtitle(text: "Later", start: 18.5, dur: 4),
                Subtitle(text: "After", start: 25, dur: 2),
            ])
        let document = ShowDocument(
            stage: SceneState(characters: [character]),
            show: [ShowSegment(name: "Cut", from: 10, to: 20)])

        XCTAssertEqual(
            YouTubePublishPlan.webVTT(for: document),
            """
            WEBVTT

            1
            00:00:00.000 --> 00:00:03.000
            Hello → there

            2
            00:00:08.500 --> 00:00:10.000
            Later

            """)
    }

    func testDescriptionIncludesValidChaptersAndStaysWithinLimit() {
        var document = ShowDocument.starter(characterCount: 1)
        document.show = [ShowSegment(name: "Cut", from: 0, to: 35)]
        document.stage.markers = [
            TimelineMarker(id: "one", name: "One", start: 0,
                           kind: .section, duration: 10),
            TimelineMarker(id: "two", name: "Two", start: 10,
                           kind: .section, duration: 10),
            TimelineMarker(id: "three", name: "Three", start: 20,
                           kind: .section, duration: 15),
        ]

        let value = YouTubePublishPlan.description(
            String(repeating: "a", count: 4_970),
            appendingChaptersFrom: document)
        XCTAssertEqual(value.count, 5_000)
        XCTAssertTrue(value.hasSuffix("0:00 One\n0:10 Two\n0:20 Three"))
    }

    func testMetadataLimitsUseYouTubeCharactersAndUTF8Bytes() {
        let title = YouTubePublishPlan.videoTitle(
            "  \(String(repeating: "🎬", count: 120)) <launch>  ")
        XCTAssertEqual(title.count, 100)
        XCTAssertFalse(title.contains("<"))
        XCTAssertFalse(title.contains(">"))

        let description = YouTubePublishPlan.videoDescription(
            String(repeating: "😀", count: 2_000) + "<end>")
        XCTAssertLessThanOrEqual(description.utf8.count, 5_000)
        XCTAssertEqual(description.utf8.count, 5_000)
        XCTAssertFalse(description.contains("<"))
    }
}
