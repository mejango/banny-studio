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
        stage: SceneState(
            characters: [Character(
                body: .alien,
                events: [
                    .key(t: 1, code: .keyJ, down: true),
                    .motion(t: 2, speed: 480, rotationSpeed: 720, wobble: 9, size: 0.8),
                ],
                speed: 420,
                rotationSpeed: 540)],
            imageTracks: [ImageTrack(id: "img1", name: "Props", cues: [
                ImageCue(id: "cue1", assetID: "s1", start: 1, dur: 4,
                         from: ImagePlacement(x: 0.2, y: 0.3, scale: 0.25),
                         to: ImagePlacement(x: 0.8, y: 0.3, scale: 0.25),
                         speed: 8.5, rotationSpeed: 80),
            ])],
            backgroundTracks: [BackgroundTrack(id: "bg1", name: "Backgrounds", cues: [
                BackgroundCue(id: "bcue", assetID: "s1", start: 0, dur: 5, crop: .tile),
            ])]),
        assets: [Asset(id: "s1", name: "set piece", kind: .image, file: "s1.png")],
        show: [ShowSegment(name: "seg", from: 0, to: 5)],
        settings: Settings(activeScene: 0, lightSize: 50))

    let pkg = dir.appendingPathComponent("Test.bs")
    try ShowPackage.write(doc,
                          audio: ["clipA": (Data([0xFF, 0xFB, 0x00]), "mp3")],
                          assets: ["s1": (Data([0x89, 0x50]), "png")],
                          to: pkg)

    let contents = try ShowPackage.read(from: pkg)
    #expect(contents.document == doc)
    #expect(contents.audioURLs.keys.sorted() == ["clipA"])
    #expect(contents.assetURLs.keys.sorted() == ["s1"])
    #expect(try Data(contentsOf: contents.audioURLs["clipA"]!) == Data([0xFF, 0xFB, 0x00]))
}

@Test func readMissingShowJSONThrows() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ShowPackage.PackageError.missingShowJSON) {
        _ = try ShowPackage.read(from: dir.appendingPathComponent("Nope.bs"))
    }
}

@Test(.enabled(if: ep1Exists)) func ep1ImportsToPackageEndToEnd() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let staging = URL(fileURLWithPath: "/Users/jango/Documents/banny/show/ep1/beat1/staging/1.json")
    let result = try V1Importer.importStudio(json: Data(contentsOf: staging))
    let pkg = dir.appendingPathComponent("ep1.bs")
    try ShowPackage.write(result.document, audio: result.audioFiles,
                          assets: result.backgroundFiles, to: pkg)

    let contents = try ShowPackage.read(from: pkg)
    #expect(contents.document == result.document)
    #expect(contents.audioURLs.count == result.audioFiles.count)
    #expect(contents.audioURLs.count >= 10) // ep1 has many voice clips
    #expect(contents.assetURLs.count == result.backgroundFiles.count)

    // Every clip referenced by the document has its media in the package.
    let clipIDs = contents.document.stage.characters.flatMap(\.clips).map(\.id)
        + contents.document.stage.audioTracks.flatMap(\.clips).map(\.id)
    for id in clipIDs {
        #expect(contents.audioURLs[id] != nil, "missing audio for clip \(id)")
    }
    // Migration invariants: 4 character tracks on one timeline, bg cues + assets present.
    #expect(contents.document.stage.characters.count == 4)
    #expect(!contents.document.assets.isEmpty)
    #expect(!contents.document.stage.backgroundTracks.flatMap(\.cues).isEmpty)
}
