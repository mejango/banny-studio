import Foundation
import Testing
@testable import BannyCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bannyshow-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func packageRoundTrip() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let doc = ShowDocument(
        scenes: [Scene(id: "s1", name: "Scene 1", state: SceneState(
            characters: [Character(body: .alien, events: [.key(t: 1, code: .keyJ, down: true)])],
            background: .image(file: "s1.png", crop: .tile)))],
        show: [ShowSegment(sceneID: "s1", name: "seg", from: 0, to: 5)],
        settings: Settings(activeScene: 0, lightSize: 50))

    let pkg = dir.appendingPathComponent("Test.bannyshow")
    try ShowPackage.write(doc,
                          audio: ["clipA": (Data([0xFF, 0xFB, 0x00]), "mp3")],
                          backgrounds: ["s1": (Data([0x89, 0x50]), "png")],
                          to: pkg)

    let contents = try ShowPackage.read(from: pkg)
    #expect(contents.document == doc)
    #expect(contents.audioURLs.keys.sorted() == ["clipA"])
    #expect(contents.backgroundURLs.keys.sorted() == ["s1"])
    #expect(try Data(contentsOf: contents.audioURLs["clipA"]!) == Data([0xFF, 0xFB, 0x00]))
}

@Test func readMissingShowJSONThrows() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ShowPackage.PackageError.missingShowJSON) {
        _ = try ShowPackage.read(from: dir.appendingPathComponent("Nope.bannyshow"))
    }
}

@Test(.enabled(if: ep1Exists)) func ep1ImportsToPackageEndToEnd() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let staging = URL(fileURLWithPath: "/Users/jango/Documents/banny/show/ep1/beat1/staging/1.json")
    let result = try V1Importer.importStudio(json: Data(contentsOf: staging))
    let pkg = dir.appendingPathComponent("ep1.bannyshow")
    try ShowPackage.write(result.document, audio: result.audioFiles,
                          backgrounds: result.backgroundFiles, to: pkg)

    let contents = try ShowPackage.read(from: pkg)
    #expect(contents.document == result.document)
    #expect(contents.audioURLs.count == result.audioFiles.count)
    #expect(contents.audioURLs.count >= 10) // ep1 has many voice clips
    #expect(contents.backgroundURLs.count == result.backgroundFiles.count)

    // Every clip referenced by the document has its media in the package.
    let clipIDs = contents.document.scenes.flatMap(\.state.characters).flatMap(\.clips).map(\.id)
        + contents.document.scenes.flatMap(\.state.audioTracks).flatMap(\.clips).map(\.id)
    for id in clipIDs {
        #expect(contents.audioURLs[id] != nil, "missing audio for clip \(id)")
    }
}
