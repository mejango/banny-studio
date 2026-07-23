import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import BannyCLI
import BannyCore
import BannyMedia

final class CLITests: XCTestCase {
    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertSuccess(
        _ arguments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let status = try await runCLI(arguments: arguments)
        XCTAssertEqual(status, 0, file: file, line: line)
    }

    func testStrictLifecyclePatchHashAndArchives() async throws {
        let root = try temporaryDirectory("banny-cli-lifecycle")
        let project = root.appendingPathComponent("show.bs")
        try await assertSuccess([
            "banny", "new", project.path, "--characters", "2",
        ])

        let showURL = project.appendingPathComponent("show.json")
        let initial = try Data(contentsOf: showURL)
        let initialHash = sha256Hex(initial)
        let patchURL = root.appendingPathComponent("patch.json")
        try Data(#"""
        [
          {"op":"test","path":"/version","value":4},
          {"op":"replace","path":"/stage/characters/0/name","value":"Director"},
          {"op":"add","path":"/stage/markers/-","value":{
            "id":"intro","name":"Intro","start":0,
            "kind":"section","duration":1,"color":"blue"
          }}
        ]
        """#.utf8).write(to: patchURL)

        try await assertSuccess([
            "banny", "apply", project.path, patchURL.path,
            "--dry-run", "--if-hash", initialHash,
        ])
        XCTAssertEqual(try Data(contentsOf: showURL), initial)
        try await assertSuccess([
            "banny", "apply", project.path, patchURL.path,
            "--if-hash", initialHash,
        ])
        let document = try ShowJSONCodec.decodeDocument(
            String(contentsOf: showURL, encoding: .utf8))
        XCTAssertEqual(document.stage.characters[0].name, "Director")
        XCTAssertEqual(document.stage.markers.map(\.id), ["intro"])
        try await assertSuccess(["banny", "validate", project.path])
        try await assertSuccess(["banny", "info", project.path, "--json"])

        let beforeRejectedPatch = try Data(contentsOf: showURL)
        let invalidPatch = root.appendingPathComponent("invalid-patch.json")
        try Data(#"[{"op":"add","path":"/stage/characters/0/speeed","value":900}]"#.utf8)
            .write(to: invalidPatch)
        do {
            _ = try await runCLI(arguments: [
                "banny", "apply", project.path, invalidPatch.path,
            ])
            XCTFail("unknown field patch should fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("speeed"))
        }
        XCTAssertEqual(try Data(contentsOf: showURL), beforeRejectedPatch)
        do {
            _ = try await runCLI(arguments: [
                "banny", "apply", project.path, patchURL.path, "--dry-rnu",
            ])
            XCTFail("misspelled patch options must fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("--dry-rnu"))
        }
        XCTAssertEqual(try Data(contentsOf: showURL), beforeRejectedPatch)

        let archive = root.appendingPathComponent("share.bs")
        try await assertSuccess([
            "banny", "pack", project.path, archive.path,
        ])
        let unpacked = root.appendingPathComponent("unpacked.bs")
        try await assertSuccess([
            "banny", "unpack", archive.path, unpacked.path,
        ])
        try await assertSuccess(["banny", "validate", unpacked.path])

        struct ExpectedFailure: Error {}
        var extractedRoot: URL?
        do {
            try withReadPackage(at: archive.path) { packageRoot, _ in
                extractedRoot = packageRoot
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: packageRoot.path))
                throw ExpectedFailure()
            }
            XCTFail("the sentinel error should escape")
        } catch is ExpectedFailure {
            // Expected: cleanup must still happen when a consumer throws.
        }
        XCTAssertNotNil(extractedRoot)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try XCTUnwrap(extractedRoot).path),
            "temporary archive extraction leaked after the read operation")
    }

    func testJSONPatchImplementsAllRFCOperations() throws {
        let source = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"items":["a","b"],"copy":{"x":1},"flag":true}"#.utf8))
        let operations = try JSONPatchEngine.decode(Data(#"""
        [
          {"op":"test","path":"/flag","value":true},
          {"op":"add","path":"/items/1","value":"x"},
          {"op":"replace","path":"/copy/x","value":2},
          {"op":"copy","from":"/copy","path":"/copy2"},
          {"op":"move","from":"/items/0","path":"/items/2"},
          {"op":"remove","path":"/flag"}
        ]
        """#.utf8))
        let result = try JSONPatchEngine.apply(operations, to: source)
        let data = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["flag"])
        XCTAssertEqual(object["items"] as? [String], ["x", "b", "a"])
        XCTAssertEqual((object["copy"] as? [String: Int])?["x"], 2)
        XCTAssertEqual((object["copy2"] as? [String: Int])?["x"], 2)
    }

    func testSchemaAndCapabilitiesRemainMachineReadable() async throws {
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(showSchemaJSON.utf8))
                as? [String: Any])
        XCTAssertEqual(schema["$schema"] as? String,
                       "https://json-schema.org/draft/2020-12/schema")
        XCTAssertEqual(
            ((schema["properties"] as? [String: Any])?["version"]
                as? [String: Int])?["const"],
            4)
        try await assertSuccess(["banny", "capabilities", "--json"])
        try await assertSuccess(["banny", "schema", "--compact"])
        try await assertSuccess(["banny", "catalog", "--json"])
        try await assertSuccess([
            "banny", "voices", "--language", "en", "--json",
        ])
        do {
            _ = try await runCLI(arguments: ["banny", "voices", "--langauge", "en"])
            XCTFail("unknown options must fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("--langauge"))
        }
        do {
            _ = try await runCLI(arguments: [
                "banny", "capabilities", "--json", "--json",
            ])
            XCTFail("duplicate options must fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("more than once"))
        }
    }

    func testMediaPreviewStylizeShipAndOverwriteSafety() async throws {
        let root = try temporaryDirectory("banny-cli-media")
        let source = root.appendingPathComponent("source.png")
        try writeTestPNG(to: source)
        let probe = try await MediaProbe.inspect(source)
        XCTAssertEqual(probe.kind, .image)
        XCTAssertEqual(probe.width, 32)
        XCTAssertEqual(probe.height, 18)

        let project = root.appendingPathComponent("show.bs")
        try await assertSuccess([
            "banny", "new", project.path, "--characters", "1",
        ])
        try await assertSuccess([
            "banny", "media", "probe", source.path, "--json",
        ])
        try await assertSuccess([
            "banny", "media", "import", project.path, source.path,
            "--id", "set", "--background", "--duration", "1", "--json",
        ])
        try await assertSuccess(["banny", "validate", project.path])

        let preview = root.appendingPathComponent("preview.png")
        try await assertSuccess([
            "banny", "preview", project.path, preview.path, "--t", "0.1",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
        let styled = root.appendingPathComponent("styled.png")
        try await assertSuccess([
            "banny", "stylize", preview.path, styled.path, "48",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: styled.path))

        let movie = root.appendingPathComponent("show.mp4")
        try await assertSuccess([
            "banny", "ship", project.path, movie.path,
            "--480", "--range", "0", "0.1", "--json",
        ])
        XCTAssertGreaterThan(
            ((try FileManager.default.attributesOfItem(atPath: movie.path)[.size])
                as? NSNumber)?.intValue ?? 0,
            1_000)
        do {
            _ = try await runCLI(arguments: [
                "banny", "ship", project.path, movie.path, "--480",
            ])
            XCTFail("shipping must not overwrite without explicit permission")
        } catch {
            XCTAssertTrue(String(describing: error).contains("--overwrite"))
        }
    }

    func testLegacyImportProducesCanonicalV4Project() async throws {
        let root = try temporaryDirectory("banny-cli-import")
        let legacy = root.appendingPathComponent("legacy.json")
        try Data(#"""
        {
          "studio": {
            "active": 0,
            "scenes": [{
              "id": "scene-one",
              "name": "Scene One",
              "state": {
                "bannys": [{"body":"orange","name":"Legacy Banny","x":0.5}]
              }
            }],
            "show": []
          },
          "bg": {},
          "audio": {}
        }
        """#.utf8).write(to: legacy)
        let output = root.appendingPathComponent("legacy.bannyshow")
        try await assertSuccess([
            "banny", "import", legacy.path, output.path,
        ])
        let document = try ShowJSONCodec.decodeDocument(
            String(
                contentsOf: output.appendingPathComponent("show.json"),
                encoding: .utf8))
        XCTAssertEqual(document.version, 4)
        XCTAssertEqual(document.stage.characters.map(\.name), ["Legacy Banny"])
        XCTAssertEqual(document.stage.backgroundTracks.count, 1)
        try await assertSuccess(["banny", "validate", output.path])
    }

    func testExplicitMigrationUpgradesLegacyStudioPackages() async throws {
        struct LegacyV2: Encodable {
            let version = 2
            let scenes: [Scene]
            let show: [ShowSegment]
            let settings = Settings()
        }

        let root = try temporaryDirectory("banny-cli-migrate")
        let project = root.appendingPathComponent("legacy.bs")
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true)
        let legacy = LegacyV2(
            scenes: [
                Scene(
                    id: "opening",
                    name: "Opening",
                    state: SceneState(characters: [
                        Character(body: .orange, name: "Legacy Banny"),
                    ])),
            ],
            show: [
                ShowSegment(
                    sceneID: "opening",
                    name: "Opening",
                    from: 0,
                    to: 1),
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let showURL = project.appendingPathComponent("show.json")
        let legacyData = try encoder.encode(legacy)
        try legacyData.write(to: showURL, options: .atomic)

        try await assertSuccess([
            "banny", "migrate", project.path, "--dry-run", "--json",
        ])
        XCTAssertEqual(try Data(contentsOf: showURL), legacyData)

        try await assertSuccess([
            "banny", "migrate", project.path, "--json",
        ])
        let document = try ShowJSONCodec.decodeDocument(
            String(contentsOf: showURL, encoding: .utf8))
        XCTAssertEqual(document.version, 4)
        XCTAssertEqual(document.stage.characters.map(\.name), ["Legacy Banny"])
        XCTAssertEqual(document.stage.backgroundTracks.count, 1)
        XCTAssertEqual(document.show.map(\.name), ["Opening"])
        try await assertSuccess(["banny", "validate", project.path])
    }

    func testTTSAndLipSyncRoundTripWhenVoicesAreInstalled() async throws {
        let voices = SpeechVoiceDescriptor.installed()
        guard let voice = voices.first else {
            throw XCTSkip("No speech synthesis voices are installed")
        }
        let root = try temporaryDirectory("banny-cli-speech")
        let project = root.appendingPathComponent("show.bs")
        try await assertSuccess([
            "banny", "new", project.path, "--characters", "1",
        ])
        try await assertSuccess([
            "banny", "tts", project.path,
            "--character", "1",
            "--text", "Banny is ready.",
            "--at", "0.25",
            "--voice", voice.id,
            "--preset", "robot",
            "--flavor", "0.4",
            "--json",
        ])
        var contents = try ShowPackage.read(from: project)
        let clip = try XCTUnwrap(contents.document.stage.characters[0].clips.first)
        XCTAssertEqual(clip.kind, .speech)
        XCTAssertFalse(clip.mouthCues.isEmpty)
        XCTAssertNotNil(contents.audioURLs[clip.id])

        try await assertSuccess([
            "banny", "lipsync", project.path,
            "--character", "1", "--clip", clip.id, "--clear",
        ])
        contents = try ShowPackage.read(from: project)
        XCTAssertTrue(contents.document.stage.characters[0].clips[0].mouthCues.isEmpty)
        try await assertSuccess([
            "banny", "lipsync", project.path,
            "--character", "1", "--clip", clip.id,
        ])
        contents = try ShowPackage.read(from: project)
        XCTAssertFalse(contents.document.stage.characters[0].clips[0].mouthCues.isEmpty)
        try await assertSuccess(["banny", "validate", project.path])
    }

    private func writeTestPNG(to url: URL) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 32,
            height: 18,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
