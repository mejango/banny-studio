import XCTest
@testable import BannyCore

final class CanonicalEncodingTests: XCTestCase {
    func testCharacterArmedGroupsEncodeInStableSemanticOrder() throws {
        var character = Character(body: .orange)
        character.armedGroups = [.zoom, .talk, .move, .blink]
        let document = ShowDocument(
            stage: SceneState(
                characters: [character],
                backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))

        let first = try ShowJSONCodec.encode(document: document)
        let second = try ShowJSONCodec.encode(
            document: ShowJSONCodec.decodeDocument(first))
        XCTAssertEqual(first, second)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        let stage = try XCTUnwrap(root["stage"] as? [String: Any])
        let characters = try XCTUnwrap(stage["characters"] as? [[String: Any]])
        XCTAssertEqual(
            characters[0]["armedGroups"] as? [String],
            ["move", "talk", "blink", "zoom"])
    }
}
