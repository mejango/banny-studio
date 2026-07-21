import XCTest
@testable import BannyCore

final class StarterDocumentTests: XCTestCase {
    func testStarterRoundTripsThroughPackage() throws {
        let doc = ShowDocument.starter(characterCount: 2)
        XCTAssertEqual(doc.stage.characters.count, 2)
        XCTAssertEqual(doc.stage.characters.map(\.name), ["Banny 1", "Banny 2"])
        XCTAssertNotEqual(doc.stage.characters[0].x, doc.stage.characters[1].x)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("starter-\(UUID().uuidString).bs")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ShowPackage.write(doc, to: dir)
        let reread = try ShowPackage.read(from: dir)
        XCTAssertEqual(reread.document, doc)
    }

    func testStarterClampsCount() {
        XCTAssertEqual(ShowDocument.starter(characterCount: 0).stage.characters.count, 1)
        XCTAssertEqual(ShowDocument.starter(characterCount: 99).stage.characters.count, 4)
    }
}
