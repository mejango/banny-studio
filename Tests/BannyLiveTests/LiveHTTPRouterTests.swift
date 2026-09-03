import Foundation
import XCTest
@testable import BannyLive

final class LiveHTTPRouterTests: XCTestCase {
    func testRoutesCatalogAndRoomCollection() async throws {
        let service = RecordingLiveHTTPService()
        let router = LiveHTTPRouter(service: service)

        let catalogResponse = await router.response(to: .get("/v1/catalog"))
        let roomsResponse = await router.response(to: .get("/v1/rooms"))
        let operations = await service.snapshot()

        XCTAssertEqual(catalogResponse.statusCode, 200)
        XCTAssertEqual(roomsResponse.statusCode, 200)
        XCTAssertEqual(operations, [.catalog, .listRooms])
    }

    func testCreateRoomPassesBoundedJSONToService() async throws {
        let service = RecordingLiveHTTPService()
        let router = LiveHTTPRouter(
            service: service,
            limits: .init(createRoomBytes: 32))
        let body = Data(#"{"name":"Cafe"}"#.utf8)

        let response = await router.response(to: .jsonPost("/v1/rooms", body: body))
        let operations = await service.snapshot()

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(operations, [.createRoom(json: body)])

        let tooLarge = await router.response(to: .jsonPost(
            "/v1/rooms", body: Data(repeating: 1, count: 33)))
        let operationCount = await service.snapshot().count
        XCTAssertEqual(tooLarge.statusCode, 413)
        XCTAssertEqual(operationCount, 1)
    }

    func testJoinRejectsAgentEndpointBeforeCallingService() async throws {
        let service = RecordingLiveHTTPService()
        let router = LiveHTTPRouter(service: service)
        let body = Data(
            #"{"name":"bot","bridge":{"agent_endpoint":"http://127.0.0.1:9000"}}"#.utf8)

        let response = await router.response(to: .jsonPost(
            "/v1/rooms/room-1/join", body: body))
        let operations = await service.snapshot()

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self)
            .contains("agent_endpoint_not_allowed"))
        XCTAssertEqual(operations, [])
    }

    func testDefaultJoinBodyLimitIsThirtyTwoKiB() async {
        let service = RecordingLiveHTTPService()
        let router = LiveHTTPRouter(service: service)
        let response = await router.response(to: .jsonPost(
            "/v1/rooms/room-1/join",
            body: Data(repeating: 0x61, count: 32 * 1_024 + 1)))
        let operations = await service.snapshot()

        XCTAssertEqual(response.statusCode, 413)
        XCTAssertTrue(operations.isEmpty)
    }

    func testJoinForwardsOptionalInviteBearerButNeverInventsIdentity() async throws {
        let service = RecordingLiveHTTPService()
        let router = LiveHTTPRouter(service: service)
        let body = Data(#"{"identity":"alice","invite_token":"secret"}"#.utf8)
        var request = LiveHTTPRequest.jsonPost("/v1/rooms/room-1/join", body: body)
        request.headers["authorization"] = "Bearer invite-capability"

        let response = await router.response(to: request)
        let operations = await service.snapshot()

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(operations, [
            .join(
                roomID: "room-1",
                json: body,
                authorization: LiveHTTPBearerCredential(token: "invite-capability")),
        ])
    }

    func testDecisionRoutesRequireBearerAndParseCursor() async throws {
        let service = RecordingLiveHTTPService()
        let router = LiveHTTPRouter(service: service)

        let missing = await router.response(to: .get(
            "/v1/rooms/room-1/decisions/next?after=42"))
        XCTAssertEqual(missing.statusCode, 401)
        XCTAssertEqual(missing.headers["WWW-Authenticate"], "Bearer")

        var request = LiveHTTPRequest.get(
            "/v1/rooms/room-1/decisions/next?after=42")
        request.headers["authorization"] = "Bearer participant-secret"
        let response = await router.response(to: request)
        let operations = await service.snapshot()

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(operations, [
            .nextDecision(
                roomID: "room-1",
                after: 42,
                authorization: LiveHTTPBearerCredential(token: "participant-secret")),
        ])
    }

    func testHostRemovalRouteUsesDeleteAndBearer() async throws {
        let service = RecordingLiveHTTPService()
        let router = LiveHTTPRouter(service: service)
        var request = LiveHTTPRequest(
            method: "DELETE",
            target: "/v1/rooms/r/participants/p")
        request.headers["authorization"] = "Bearer host-token"

        let response = await router.response(to: request)
        let operations = await service.snapshot()

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(operations, [
            .removeParticipant(
                roomID: "r",
                participantID: "p",
                authorization: LiveHTTPBearerCredential(token: "host-token")),
        ])
    }

    func testGetSubmitLeaveAndEndUseFrozenRoomRoutes() async throws {
        let service = RecordingLiveHTTPService()
        let router = LiveHTTPRouter(service: service)

        _ = await router.response(to: .get("/v1/rooms/room-1"))

        let decisionBody = Data(
            #"{"protocol":"banny.agent.v1","request_id":"request-1","intent_id":"intent-1","actions":[]}"#.utf8)
        var decision = LiveHTTPRequest.jsonPost(
            "/v1/rooms/room-1/decisions/request-1",
            body: decisionBody)
        decision.headers["authorization"] = "Bearer participant-token"
        _ = await router.response(to: decision)

        var leave = LiveHTTPRequest(
            method: "POST",
            target: "/v1/rooms/room-1/leave")
        leave.headers["authorization"] = "Bearer participant-token"
        _ = await router.response(to: leave)

        var end = LiveHTTPRequest(
            method: "POST",
            target: "/v1/rooms/room-1/end")
        end.headers["authorization"] = "Bearer host-token"
        _ = await router.response(to: end)

        let operations = await service.snapshot()
        XCTAssertEqual(operations, [
            .getRoom(roomID: "room-1"),
            .submitDecision(
                roomID: "room-1",
                requestID: "request-1",
                json: decisionBody,
                authorization: LiveHTTPBearerCredential(token: "participant-token")),
            .leave(
                roomID: "room-1",
                json: nil,
                authorization: LiveHTTPBearerCredential(token: "participant-token")),
            .endRoom(
                roomID: "room-1",
                authorization: LiveHTTPBearerCredential(token: "host-token")),
        ])
    }

    func testMissingFrameRendererIsAnExplicitNotImplementedHook() async {
        let router = LiveHTTPRouter(service: RecordingLiveHTTPService())
        let response = await router.response(to: .get(
            "/v1/rooms/room-1/frame.jpg"))

        XCTAssertEqual(response.statusCode, 501)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self)
            .contains("frame_renderer_unavailable"))
    }

    func testInjectedFrameRendererReturnsJPEG() async {
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let router = LiveHTTPRouter(
            service: RecordingLiveHTTPService(),
            frameRenderer: { roomID in
                XCTAssertEqual(roomID, "room-1")
                return jpeg
            })

        let response = await router.response(to: .get(
            "/v1/rooms/room-1/frame.jpg"))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["Content-Type"], "image/jpeg")
        XCTAssertEqual(response.body, jpeg)
    }

    func testMusicSupportsOneHTTPByteRange() async {
        let music = Data([0, 1, 2, 3, 4, 5])
        let service = RecordingLiveHTTPService(result: LiveHTTPServiceResult(
            headers: ["Content-Type": "audio/mpeg"],
            body: music))
        let router = LiveHTTPRouter(service: service)
        var request = LiveHTTPRequest.get("/v1/rooms/room-1/music")
        request.headers["range"] = "bytes=2-4"

        let response = await router.response(to: request)

        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.headers["Content-Range"], "bytes 2-4/6")
        XCTAssertEqual(response.headers["Accept-Ranges"], "bytes")
        XCTAssertEqual(response.body, Data([2, 3, 4]))
    }

    func testStaticAssetsSupportSPAFallbackAndSecurityHeaders() async {
        let index = LiveHTTPStaticAsset(
            data: Data("<main>Banny Live</main>".utf8),
            contentType: "text/html; charset=utf-8")
        let assets = LiveHTTPInMemoryStaticAssets(assets: ["index.html": index])
        let router = LiveHTTPRouter(
            service: RecordingLiveHTTPService(), staticAssets: assets)

        let response = await router.response(to: .get("/rooms/room-1"))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, index.data)
        XCTAssertEqual(response.headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(response.headers["Cross-Origin-Resource-Policy"], "same-origin")
        XCTAssertNotNil(response.headers["Content-Security-Policy"])
        XCTAssertNil(response.headers["Access-Control-Allow-Origin"])
    }

    func testBundledWebAssetsResolveSwiftPMFlattenedResources() async throws {
        let assets = LiveHTTPBundledWebAssets()

        let index = try await assets.asset(at: "index.html")
        let script = try await assets.asset(at: "app.js")
        let style = try await assets.asset(at: "app.css")

        XCTAssertEqual(index?.contentType, "text/html; charset=utf-8")
        XCTAssertEqual(script?.contentType, "text/javascript; charset=utf-8")
        XCTAssertEqual(style?.contentType, "text/css; charset=utf-8")
        let scriptWire = String(decoding: try XCTUnwrap(script).data, as: UTF8.self)
        for marker in [
            "character_prompt", "join-scene",
            "avatar-dresser", "avatar-body-picker", "avatar-eyes-picker",
            "avatar-mouth-picker", "wardrobe-slots", "avatar-preview-canvas",
            "avatar-advanced", "loadArtworkCatalog", "updateCompositePreview",
            "createAppearanceChoice", "/banny-assets/catalog.json",
            "/banny-assets/png/",
        ] {
            XCTAssertTrue(scriptWire.contains(marker), "missing direct-join marker: \(marker)")
        }
        let uiWire = String(decoding: try XCTUnwrap(index).data, as: UTF8.self)
            + scriptWire
        let normalizedUIWire = uiWire.lowercased()
        for forbidden in ["/banny-live-bridge.py", "local ai", "bridge kit"] {
            XCTAssertFalse(
                normalizedUIWire.contains(forbidden),
                "direct join UI still exposes legacy marker: \(forbidden)")
        }
        XCTAssertFalse(scriptWire.contains("speechSynthesis"))
        XCTAssertTrue(uiWire.contains("Banny Live"))
    }

    func testMountedAssetsServeAuthoritativeCatalogAndPNGWithCacheMetadata() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "banny-live-mounted-assets-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("BannyAssets", isDirectory: true)
        let pngDirectory = root.appendingPathComponent("png", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pngDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let catalogData = Data(#"{"bodies":{"original":{"file":"body-original.png"}}}"#.utf8)
        let pngData = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        try catalogData.write(to: root.appendingPathComponent("catalog.json"))
        try pngData.write(to: pngDirectory.appendingPathComponent("body-original.png"))

        let poisonedCatalog = LiveHTTPStaticAsset(
            data: Data("wrong provider".utf8),
            contentType: "text/plain; charset=utf-8")
        let web = LiveHTTPInMemoryStaticAssets(assets: [
            "banny-assets/catalog.json": poisonedCatalog,
        ])
        let mounted = LiveHTTPMountedStaticAssets(
            mount: "banny-assets",
            assets: LiveHTTPDirectoryStaticAssets(rootDirectory: root))
        let assets = LiveHTTPCompositeStaticAssets(providers: [web, mounted])
        let router = LiveHTTPRouter(
            service: RecordingLiveHTTPService(), staticAssets: assets)

        let catalog = await router.response(to: .get("/banny-assets/catalog.json"))
        let png = await router.response(to: .get(
            "/banny-assets/png/body-original.png"))

        XCTAssertEqual(catalog.statusCode, 200)
        XCTAssertEqual(catalog.body, catalogData)
        XCTAssertEqual(
            catalog.headers["Content-Type"],
            "application/json; charset=utf-8")
        XCTAssertEqual(catalog.headers["Cache-Control"], "public, max-age=3600")
        XCTAssertEqual(png.statusCode, 200)
        XCTAssertEqual(png.body, pngData)
        XCTAssertEqual(png.headers["Content-Type"], "image/png")
        XCTAssertEqual(png.headers["Cache-Control"], "public, max-age=3600")
    }

    func testMountedAssetsRejectTraversalAndSymlinkEscapeWithoutBreakingSPAFallback() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "banny-live-mounted-assets-security-\(UUID().uuidString)",
            isDirectory: true)
        let root = parent.appendingPathComponent("BannyAssets", isDirectory: true)
        let pngDirectory = root.appendingPathComponent("png", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pngDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let outside = parent.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: pngDirectory.appendingPathComponent("escape.png"),
            withDestinationURL: outside)

        let index = LiveHTTPStaticAsset(
            data: Data("<main>Banny Live</main>".utf8),
            contentType: "text/html; charset=utf-8")
        let leakedFallback = LiveHTTPStaticAsset(
            data: Data("must not escape the mount".utf8),
            contentType: "text/plain; charset=utf-8")
        let web = LiveHTTPInMemoryStaticAssets(assets: [
            "index.html": index,
            "banny-assets/missing": leakedFallback,
        ])
        let mounted = LiveHTTPMountedStaticAssets(
            mount: "banny-assets",
            assets: LiveHTTPDirectoryStaticAssets(rootDirectory: root))
        let assets = LiveHTTPCompositeStaticAssets(providers: [web, mounted])
        let router = LiveHTTPRouter(
            service: RecordingLiveHTTPService(), staticAssets: assets)

        let directTraversal = try await mounted.asset(
            at: "banny-assets/../outside.png")
        let encodedTraversal = await router.response(to: .get(
            "/banny-assets/%2e%2e/outside.png"))
        let symlinkEscape = await router.response(to: .get(
            "/banny-assets/png/escape.png"))
        let missingMountedAsset = await router.response(to: .get(
            "/banny-assets/missing"))
        let applicationRoute = await router.response(to: .get(
            "/rooms/room-1"))

        XCTAssertNil(directTraversal)
        XCTAssertEqual(encodedTraversal.statusCode, 400)
        XCTAssertEqual(symlinkEscape.statusCode, 404)
        XCTAssertEqual(missingMountedAsset.statusCode, 404)
        XCTAssertFalse(missingMountedAsset.body == index.data)
        XCTAssertFalse(missingMountedAsset.body == leakedFallback.data)
        XCTAssertEqual(applicationRoute.statusCode, 200)
        XCTAssertEqual(applicationRoute.body, index.data)
    }

    func testMethodNotAllowedIncludesAllowHeader() async {
        let router = LiveHTTPRouter(service: RecordingLiveHTTPService())
        let response = await router.response(to: LiveHTTPRequest(
            method: "DELETE", target: "/v1/rooms"))

        XCTAssertEqual(response.statusCode, 405)
        XCTAssertEqual(response.headers["Allow"], "GET, POST")
    }
}

private actor RecordingLiveHTTPService: LiveHTTPService {
    private var operations: [LiveHTTPOperation] = []
    private let result: LiveHTTPServiceResult

    init(result: LiveHTTPServiceResult = LiveHTTPServiceResult(
        statusCode: 200,
        headers: ["Content-Type": "application/json; charset=utf-8"],
        body: Data("{}".utf8)
    )) {
        self.result = result
    }

    func perform(_ operation: LiveHTTPOperation) async throws -> LiveHTTPServiceResult {
        operations.append(operation)
        return result
    }

    func snapshot() -> [LiveHTTPOperation] {
        operations
    }
}

private extension LiveHTTPRequest {
    static func get(_ target: String) -> LiveHTTPRequest {
        LiveHTTPRequest(method: "GET", target: target)
    }

    static func jsonPost(_ target: String, body: Data) -> LiveHTTPRequest {
        LiveHTTPRequest(
            method: "POST",
            target: target,
            headers: ["Content-Type": "application/json"],
            body: body)
    }
}
