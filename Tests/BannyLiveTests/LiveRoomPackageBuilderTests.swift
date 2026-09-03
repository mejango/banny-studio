import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import BannyCore
import BannyMedia
import BannyRender
@testable import BannyLive

final class LiveRoomPackageBuilderTests: XCTestCase {
    func testCreateRequestStrictlyRejectsUnknownRootAndUploadFields() throws {
        let encoded = try LiveHTTPJSON.encoder.encode(makeRequest())
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        root["surprise"] = true
        try assertRequestDecodeRejects(root, field: "surprise")

        root.removeValue(forKey: "surprise")
        var background = try XCTUnwrap(root["background"] as? [String: Any])
        background["remote_url"] = "https://example.invalid/set.png"
        root["background"] = background
        try assertRequestDecodeRejects(root, field: "remote_url")
    }

    func testOccupancyAndAllowlistMetadataAreValidatedBeforeWriting() async {
        let cases: [(LiveRoomCreateRequest, LiveRoomPackageBuilderError)] = [
            (makeRequest(maxOccupancy: 0), .invalidOccupancy),
            (makeRequest(maxOccupancy: 11), .invalidOccupancy),
            (makeRequest(allowlist: ["   \n"]), .invalidAllowlistIdentity),
            (makeRequest(allowlist: ["alice", "alice"]), .duplicateAllowlistIdentity),
            (makeRequest(allowlist: (0...10).map { "guest-\($0)" }), .allowlistTooLarge),
        ]

        for (index, fixture) in cases.enumerated() {
            let storage = temporaryStorage("metadata-\(index)")
            defer { try? FileManager.default.removeItem(at: storage) }
            await assertCreationFails(
                fixture.0,
                roomID: "metadata-\(index)",
                storage: storage,
                expected: fixture.1)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: storage.path),
                "metadata rejection should happen before storage is created")
        }
    }

    func testValidStillAndMP3CreateCanonicalEditableV4PackageWithoutAdmissionSecrets() async throws {
        let storage = temporaryStorage("canonical")
        defer { try? FileManager.default.removeItem(at: storage) }
        let request = makeRequest(
            title: "Robots after dark",
            premise: "private-premise-sentinel",
            maxOccupancy: 3,
            allowlist: ["private-allowlist-sentinel"])

        let seed = try await LiveRoomPackageBuilder.create(
            request: request,
            roomID: "canonical-room",
            storageURL: storage)

        XCTAssertEqual(seed.packageURL.pathExtension, "bs")
        XCTAssertEqual(
            seed.packageURL,
            storage.appendingPathComponent("canonical-room/recording.bs", isDirectory: true))
        XCTAssertEqual(try Data(contentsOf: seed.backgroundURL), Self.onePixelPNG)
        XCTAssertEqual(try Data(contentsOf: seed.musicURL), Self.silentMP3)

        let showURL = seed.packageURL.appendingPathComponent("show.json")
        let showText = try String(contentsOf: showURL, encoding: .utf8)
        let decoded = try ShowJSONCodec.decodeDocument(showText)
        XCTAssertEqual(decoded.version, 4)
        XCTAssertEqual(decoded, seed.document)
        XCTAssertEqual(showText, try ShowJSONCodec.encode(document: decoded))
        XCTAssertEqual(decoded.assets, [
            Asset(
                id: "room-background",
                name: "Room background",
                kind: .image,
                file: "room-background.png"),
        ])
        XCTAssertEqual(decoded.stage.characters.count, 0)
        XCTAssertEqual(decoded.stage.backgroundTracks.count, 1)
        XCTAssertEqual(decoded.stage.backgroundTracks[0].cues.count, 1)
        XCTAssertEqual(
            decoded.stage.backgroundTracks[0].cues[0].dur,
            LiveRoomPackageBuilder.recordingHorizonSeconds)
        XCTAssertEqual(decoded.stage.audioTracks.count, 1)
        XCTAssertEqual(decoded.stage.audioTracks[0].clips.map(\.id), ["room-music"])

        let lintErrors = ShowLint.check(
            document: decoded,
            audioIDs: Set(["room-music"]),
            assetFileIDs: Set(["room-background"]),
            catalog: nil,
            profile: .editableShow)
            .filter { $0.severity == .error }
        XCTAssertTrue(lintErrors.isEmpty, "\(lintErrors)")

        for forbidden in [
            "private-allowlist-sentinel", "private-premise-sentinel",
            "allowlist", "max_occupancy", "host_token", "invite", "secret",
        ] {
            XCTAssertFalse(showText.contains(forbidden), "show.json leaked \(forbidden)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: seed.packageURL.deletingLastPathComponent()
                    .appendingPathComponent("input").path))
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(
                atPath: seed.packageURL.path)),
            Set(["assets", "audio", "show.json"]))
    }

    func testAnimateTinyStillSafelyProducesRepeatingCameraDrift() async throws {
        let storage = temporaryStorage("animated-still")
        defer { try? FileManager.default.removeItem(at: storage) }
        let request = makeRequest(animateStill: true)

        let seed = try await LiveRoomPackageBuilder.create(
            request: request,
            roomID: "animated-still",
            storageURL: storage)
        let cues = try XCTUnwrap(seed.document.stage.backgroundTracks.first).cues
        let asset = try XCTUnwrap(seed.document.assets.first)

        XCTAssertFalse(seed.backgroundWasShimmered)
        XCTAssertEqual(seed.backgroundURL.pathExtension, "png")
        XCTAssertEqual(asset.file, "room-background.png")
        XCTAssertGreaterThan(cues.count, 2)
        XCTAssertTrue(cues.allSatisfy { $0.camFrom != nil && $0.camTo != nil })
        XCTAssertEqual(cues.first?.start, 0)
        XCTAssertEqual(
            (cues.last?.start ?? 0) + (cues.last?.dur ?? 0),
            LiveRoomPackageBuilder.recordingHorizonSeconds,
            accuracy: 0.000_001)
        for index in 0..<(cues.count - 1) {
            XCTAssertEqual(cues[index].start + cues[index].dur, cues[index + 1].start)
            XCTAssertEqual(cues[index].camTo, cues[index + 1].camFrom)
        }
    }

    func testAnimateStillRejectsVideoAndCleansEveryStagedArtifact() async {
        let storage = temporaryStorage("video-rejection")
        defer { try? FileManager.default.removeItem(at: storage) }
        var request = makeRequest(animateStill: true)
        request.background = LiveRoomMediaUpload(
            filename: "tiny.mp4",
            contentType: "video/mp4",
            base64: Self.tinyMP4.base64EncodedString())

        await assertCreationFails(
            request,
            roomID: "video-rejection",
            storage: storage,
            expected: .stillAnimationRequiresStillImage)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: storage.appendingPathComponent("video-rejection").path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: storage.path)) ?? []
        XCTAssertEqual(leftovers, [], "failed creation left staged files: \(leftovers)")
    }

    func testAudioContainerRenamedToMP3IsRejectedWithoutResidue() async {
        let storage = temporaryStorage("renamed-audio")
        defer { try? FileManager.default.removeItem(at: storage) }
        var request = makeRequest()
        request.music = LiveRoomMediaUpload(
            filename: "not-really.mp3",
            contentType: "audio/mpeg",
            base64: Self.tinyWAV.base64EncodedString())

        await assertCreationFails(
            request,
            roomID: "renamed-audio",
            storage: storage,
            expected: .invalidMusic)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: storage.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testMPEGLayerIIRenamedToMP3IsRejectedWithoutResidue() async {
        let storage = temporaryStorage("layer-two-audio")
        defer { try? FileManager.default.removeItem(at: storage) }
        var request = makeRequest()
        request.music = LiveRoomMediaUpload(
            filename: "layer-two.mp3",
            contentType: "audio/mpeg",
            base64: Self.mpegLayerII.base64EncodedString())

        await assertCreationFails(
            request,
            roomID: "layer-two-audio",
            storage: storage,
            expected: .invalidMusic)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: storage.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testAnimatedImageOverFrameLimitIsRejectedWithoutFrameWalkOrResidue() async throws {
        let storage = temporaryStorage("too-many-image-frames")
        defer { try? FileManager.default.removeItem(at: storage) }
        var request = makeRequest()
        request.background = LiveRoomMediaUpload(
            filename: "too-many.gif",
            contentType: "image/gif",
            base64: try Self.gif(frameCount:
                LiveRoomPackageBuilder.maximumAnimatedImageFrames + 1)
                .base64EncodedString())

        await assertCreationFails(
            request,
            roomID: "too-many-image-frames",
            storage: storage,
            expected: .invalidBackground)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: storage.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testAnimatedImageDisguisedAsVideoCannotBypassBoundedProbe() async throws {
        let storage = temporaryStorage("disguised-image-frames")
        defer { try? FileManager.default.removeItem(at: storage) }
        var request = makeRequest()
        request.background = LiveRoomMediaUpload(
            filename: "disguised.mp4",
            contentType: "video/mp4",
            base64: try Self.gif(frameCount:
                LiveRoomPackageBuilder.maximumAnimatedImageFrames + 1)
                .base64EncodedString())

        await assertCreationFails(
            request,
            roomID: "disguised-image-frames",
            storage: storage,
            expected: .invalidBackground)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: storage.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testGIFClaimedAsPNGIsRejectedWithoutResidue() async throws {
        let storage = temporaryStorage("gif-claimed-as-png")
        defer { try? FileManager.default.removeItem(at: storage) }
        var request = makeRequest()
        request.background = LiveRoomMediaUpload(
            filename: "not-a-png.png",
            contentType: "image/png",
            base64: try Self.gif(frameCount: 2).base64EncodedString())

        await assertCreationFails(
            request,
            roomID: "gif-claimed-as-png",
            storage: storage,
            expected: .invalidBackground)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: storage.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testOversizedLaterHEICFrameIsRejectedWithoutPixelDecode() async throws {
        let storage = temporaryStorage("later-frame-dimensions")
        defer { try? FileManager.default.removeItem(at: storage) }
        let imageData = try Self.heicSequence(sizes: [
            (width: 1, height: 1),
            (width: 5_000, height: 4_000),
        ])
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(imageData as CFData, options))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let first = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any])
        let second = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 1, options) as? [CFString: Any])
        XCTAssertEqual(
            (first[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            1)
        XCTAssertEqual(
            (second[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            5_000)

        var request = makeRequest()
        request.background = LiveRoomMediaUpload(
            filename: "variable.heic",
            contentType: "image/heic",
            base64: imageData.base64EncodedString())
        await assertCreationFails(
            request,
            roomID: "later-frame-dimensions",
            storage: storage,
            expected: .invalidBackground)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: storage.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testAnimatedImageOverAggregatePixelBudgetIsRejected() async throws {
        let storage = temporaryStorage("aggregate-image-pixels")
        defer { try? FileManager.default.removeItem(at: storage) }
        let width = 1_024
        let height = 1_024
        let frameCount = 65
        XCTAssertLessThanOrEqual(
            width * height,
            LiveRoomPackageBuilder.maximumBackgroundPixels)
        XCTAssertLessThanOrEqual(
            frameCount,
            LiveRoomPackageBuilder.maximumAnimatedImageFrames)
        XCTAssertGreaterThan(
            width * height * frameCount,
            LiveRoomPackageBuilder.maximumAnimatedImageAggregatePixels)

        let imageData = try Self.gif(
            frameCount: frameCount,
            width: width,
            height: height)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(imageData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), frameCount)
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            width)
        XCTAssertEqual(
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            height)

        var request = makeRequest()
        request.background = LiveRoomMediaUpload(
            filename: "aggregate.gif",
            contentType: "image/gif",
            base64: imageData.base64EncodedString())

        await assertCreationFails(
            request,
            roomID: "aggregate-image-pixels",
            storage: storage,
            expected: .invalidBackground)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: storage.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    private func assertRequestDecodeRejects(
        _ object: [String: Any],
        field: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try LiveHTTPJSON.decoder.decode(LiveRoomCreateRequest.self, from: data),
            file: file,
            line: line
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("Unknown field \(field)"),
                "unexpected decode error: \(error)",
                file: file,
                line: line)
        }
    }

    private func assertCreationFails(
        _ request: LiveRoomCreateRequest,
        roomID: String,
        storage: URL,
        expected: LiveRoomPackageBuilderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await LiveRoomPackageBuilder.create(
                request: request,
                roomID: roomID,
                storageURL: storage)
            XCTFail("expected creation to fail with \(expected)", file: file, line: line)
        } catch let error as LiveRoomPackageBuilderError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected creation error: \(error)", file: file, line: line)
        }
    }

    private func makeRequest(
        title: String = "Fixture room",
        premise: String? = nil,
        maxOccupancy: Int = 2,
        allowlist: [String] = [],
        animateStill: Bool = false
    ) -> LiveRoomCreateRequest {
        LiveRoomCreateRequest(
            title: title,
            premise: premise,
            background: LiveRoomMediaUpload(
                filename: "one.png",
                contentType: "image/png",
                base64: Self.onePixelPNG.base64EncodedString()),
            music: LiveRoomMediaUpload(
                filename: "silence.mp3",
                contentType: "audio/mpeg",
                base64: Self.silentMP3.base64EncodedString()),
            maxOccupancy: maxOccupancy,
            allowlist: allowlist,
            animateStill: animateStill)
    }

    private func temporaryStorage(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "banny-live-package-builder-\(label)-\(UUID().uuidString)",
            isDirectory: true)
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/"
        + "x8AAusB9Wl2gF0AAAAASUVORK5CYII=")!

    /// One 16-bit mono PCM sample in a complete WAV container.
    private static let tinyWAV = Data([
        0x52, 0x49, 0x46, 0x46, 0x26, 0x00, 0x00, 0x00,
        0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20,
        0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x40, 0x1f, 0x00, 0x00, 0x80, 0x3e, 0x00, 0x00,
        0x02, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    /// Four complete MPEG-1 Layer II frames. The previous sync-word sniff
    /// accepted this valid MPEG audio stream even though it is not MP3.
    private static let mpegLayerII: Data = {
        let frame = Data(base64Encoded:
        "//1IxGM0NEIzRtxkAAAAqqqqqr77777777777777775+/fu7u7rY21sWx8222tj"
        + "bbbbWxttfv37u7u62NtbFsfNttrY22221sbbX79+7u7utjbWxbHzbba2NttttbG"
        + "21+/fu7u7rY21sWx8222tjbbbbWxttfv37u7u62NtbFsfNttrY22221sbbX79+7u"
        + "7utjbWxbHzbba2NttttbG21+/fu7u7rY21sWx8222tjbbbbWxttfv37u7u62NtbF"
        + "sfNttrY22221sbbX79+7u7utjbWxbHzbba2NttttbG21+/fu7u7rY21sWx8222t"
        + "jbbbbWxttfv37u7u62NtbFsfNttrY22221sbbX79+7u7utjbWxbHzbba2NttttbG"
        + "20A")!
        var stream = Data()
        for _ in 0..<4 { stream.append(frame) }
        return stream
    }()

    private static func gif(
        frameCount: Int,
        width: Int = 1,
        height: Int = 1
    ) throws -> Data {
        let image = try makeImage(width: width, height: height)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.gif.identifier as CFString,
            frameCount,
            nil))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
        ] as CFDictionary
        for _ in 0..<frameCount {
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func heicSequence(
        sizes: [(width: Int, height: Int)]
    ) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.heic.identifier as CFString,
            sizes.count,
            nil))
        for size in sizes {
            CGImageDestinationAddImage(
                destination,
                try makeImage(width: size.width, height: size.height),
                nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func makeImage(width: Int, height: Int) throws -> CGImage {
        if width == 1, height == 1 {
            let source = try XCTUnwrap(
                CGImageSourceCreateWithData(onePixelPNG as CFData, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// 120 ms of mono silence, encoded as a complete valid MP3 fixture.
    private static let silentMP3 = Data(base64Encoded:
        "SUQzBAAAAAAAIlRTU0UAAAAOAAADTGF2ZjYxLjcuMTAwAAAAAAAAAAAAAAD/80DE"
        + "AAAAA0gAAAAATEFNRTMuMTAwVVVVVVVVVVVVVUxBTUUzLjEwMFVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVf/zQsRbAAADSAAAAABVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUUzLjEwMFVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVf/zQMSkAAADSAAAAABVVVVVVVVVVVVVVVVVVVVVVVVVTE"
        + "FNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//NCxKMAAANIAAAAAFVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVf/zQMSkAAADS"
        + "AAAAABVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVV//NAxKQAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVX/80LEowAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVX/80DEpAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVQ==")!

    /// One black 16×16 H.264 frame in an ISO-BMFF container.
    private static let tinyMP4 = Data(base64Encoded:
        "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMNbW9vdgAAAGxtdmhk"
        + "AAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAA"
        + "AAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        + "AAAAAgAAAjh0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAA"
        + "AAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAA"
        + "ABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAAAAABAAAAAAGw"
        + "bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAQABVxAAAAAAALWhkbHIAAAAA"
        + "AAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABW21pbmYAAAAUdm1o"
        + "ZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAA"
        + "AQAAARtzdGJsAAAAt3N0c2QAAAAAAAAAAQAAAKdhdmMxAAAAAAAAAAEAAAAAAAAA"
        + "AAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFUxhdmM2MS4xOS4xMDEgbGlieDI2"
        + "NAAAAAAAAAAAAAAAGP//AAAALWF2Y0MBQsAK/+EAFWdCwAraewEQAAADABAAAAMA"
        + "IPEiagEABWjOAZcgAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAEyAAAAAA"
        + "AAAAGHN0dHMAAAAAAAAAAQAAAAEAAEAAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAB"
        + "AAAAAQAAABRzdHN6AAAAAAAAAmQAAAABAAAAFHN0Y28AAAAAAAAAAQAAAz0AAABh"
        + "dWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAA"
        + "AAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYxLjcuMTAwAAAA"
        + "CGZyZWUAAAJsbWRhdAAAAlMGBf//T9xF6b3m2Ui3lizYINkj7u94MjY0IC0gY29y"
        + "ZSAxNjQgcjMxMDggMzFlMTlmOSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBD"
        + "b3B5bGVmdCAyMDAzLTIwMjMgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0"
        + "Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5h"
        + "bHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMiBt"
        + "aXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4"
        + "ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9x"
        + "cF9vZmZzZXQ9MCB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRf"
        + "dGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2Nv"
        + "bXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MCBr"
        + "ZXlpbnQ9MjUwIGtleWludF9taW49MSBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9"
        + "MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTUxLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFw"
        + "bWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAAACWWIhDomKAAV"
        + "wA==")!
}
