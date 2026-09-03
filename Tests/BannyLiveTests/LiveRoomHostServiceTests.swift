import Foundation
import XCTest
import BannyCore
import BannyRender
@testable import BannyLive

final class LiveRoomHostServiceTests: XCTestCase {
    private static let assetsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets", isDirectory: true)

    func testAutonomyAndLegacyParticipantControlAreMutuallyExclusive() throws {
        XCTAssertThrowsError(try makeHost(
            autonomyEnabled: true,
            legacyParticipantControlEnabled: true
        )) { error in
            guard let problem = error as? LiveHTTPProblem else {
                return XCTFail("Expected a host configuration problem, got \(error)")
            }
            XCTAssertEqual(problem.liveHTTPStatusCode, 400)
            XCTAssertEqual(problem.liveHTTPErrorCode, "invalid_host_configuration")
        }
    }

    func testCreateListAndGetExposePublicRoomButRedactCapabilities() async throws {
        let fixture = try makeHost()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }

        let created = try await createRoom(
            on: fixture.host,
            title: "Tiny Stage",
            maximumOccupancy: 2,
            allowlist: ["alice"])
        XCTAssertEqual(created.response.statusCode, 201)
        XCTAssertEqual(created.payload.room.title, "Tiny Stage")
        XCTAssertEqual(created.payload.room.maxOccupancy, 2)
        XCTAssertEqual(created.payload.room.occupancy, 0)
        XCTAssertEqual(created.payload.invitations.map(\.identity), ["alice"])
        XCTAssertFalse(created.payload.hostToken.isEmpty)

        let packageURL = try await fixture.host.packageURL(roomID: created.payload.room.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            packageURL.appendingPathComponent("show.json").path))

        let list = try await fixture.host.perform(.listRooms)
        let listed = try LiveHTTPJSON.decoder.decode(RoomListEnvelope.self, from: list.body)
        XCTAssertEqual(listed.rooms, [created.payload.room])

        let get = try await fixture.host.perform(.getRoom(roomID: created.payload.room.id))
        let fetched = try LiveHTTPJSON.decoder.decode(RoomEnvelope.self, from: get.body)
        XCTAssertEqual(fetched.room, created.payload.room)

        let publicWire = String(decoding: list.body + get.body, as: UTF8.self)
        XCTAssertFalse(publicWire.contains(created.payload.hostToken))
        XCTAssertFalse(publicWire.contains(created.payload.invitations[0].invite))
        XCTAssertFalse(publicWire.contains("host_token"))
        XCTAssertFalse(publicWire.contains("invitations"))
    }

    func testListSamplesTheClockOncePerRoomInsteadOfReusingAStaleTimestamp() async throws {
        let fixture = try makeHost()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        _ = try await createRoom(
            on: fixture.host,
            title: "Clock Room One",
            maximumOccupancy: 1)
        _ = try await createRoom(
            on: fixture.host,
            title: "Clock Room Two",
            maximumOccupancy: 1)

        let readsBeforeList = fixture.clock.readCount()
        let response = try await fixture.host.perform(.listRooms)
        let listed = try LiveHTTPJSON.decoder.decode(
            RoomListEnvelope.self, from: response.body)

        XCTAssertEqual(listed.rooms.count, 2)
        XCTAssertEqual(fixture.clock.readCount() - readsBeforeList, 2)
    }

    func testRoomLimitCountsExistingDirectoriesAndHostedRoomsButNotSymlinks() async throws {
        let fixture = try makeHost(limits: LiveRoomHostLimits(
            maximumRooms: 2,
            maximumStorageBytes: LiveRoomHostLimits.defaultMaximumStorageBytes))
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let existing = fixture.storage.appendingPathComponent(
            "archived-room", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existing, withIntermediateDirectories: false)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "banny-live-linked-room-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: fixture.storage.appendingPathComponent("linked-room"),
            withDestinationURL: outside)

        let created = try await createRoom(
            on: fixture.host,
            title: "Last Room Slot",
            maximumOccupancy: 1)
        XCTAssertEqual(created.response.statusCode, 201)

        let router = makeRouter(host: fixture.host)
        let rejected = await router.response(to: try roomCreateRequest(
            title: "Beyond Limit", maximumOccupancy: 1))
        XCTAssertEqual(rejected.statusCode, 429)
        XCTAssertTrue(wire(rejected).contains("room_limit_reached"))
    }

    func testStorageQuotaRejectsBeforeStagingAndDoesNotFollowSymlinkTargets() async throws {
        let reservation = LiveRoomStorageAccounting.creationReservationBytes(
            animateStill: false)
        let fixture = try makeHost(limits: LiveRoomHostLimits(
            maximumRooms: 10,
            maximumStorageBytes: reservation + (1 * 1_024 * 1_024)))
        defer { try? FileManager.default.removeItem(at: fixture.storage) }

        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "banny-live-large-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        let sparse = outside.appendingPathComponent("large.dat")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 1 * 1_024 * 1_024 * 1_024)
        try handle.close()
        try FileManager.default.createSymbolicLink(
            at: fixture.storage.appendingPathComponent("external-storage"),
            withDestinationURL: outside)

        let accepted = try await createRoom(
            on: fixture.host,
            title: "Symlink Safe",
            maximumOccupancy: 1)
        XCTAssertEqual(accepted.response.statusCode, 201)

        let rejectingFixture = try makeHost(limits: LiveRoomHostLimits(
            maximumRooms: 10,
            maximumStorageBytes: reservation - 1))
        defer { try? FileManager.default.removeItem(at: rejectingFixture.storage) }
        let router = makeRouter(host: rejectingFixture.host)
        let rejected = await router.response(to: try roomCreateRequest(
            title: "No Partial Room", maximumOccupancy: 1))
        XCTAssertEqual(rejected.statusCode, 507)
        XCTAssertTrue(wire(rejected).contains("storage_quota_exceeded"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: rejectingFixture.storage.path),
            [])
    }

    func testStaleHiddenStagingBytesCountWithoutBecomingRoomSlots() async throws {
        let reservation = LiveRoomStorageAccounting.creationReservationBytes(
            animateStill: false)
        let fixture = try makeHost(limits: LiveRoomHostLimits(
            maximumRooms: 1,
            maximumStorageBytes: reservation + (1 * 1_024 * 1_024)))
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let stale = fixture.storage.appendingPathComponent(
            ".abandoned.tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stale, withIntermediateDirectories: false)
        let staleFile = stale.appendingPathComponent("partial-upload")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: staleFile.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: staleFile)
        try handle.truncate(atOffset: 2 * 1_024 * 1_024)
        try handle.close()

        let rejected = await makeRouter(host: fixture.host).response(
            to: try roomCreateRequest(title: "Stale Bytes", maximumOccupancy: 1))
        XCTAssertEqual(rejected.statusCode, 507)
        XCTAssertTrue(wire(rejected).contains("storage_quota_exceeded"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path),
                      "quota admission must never delete stale data automatically")
    }

    func testSymlinkStorageRootFailsClosed() async throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(
            "banny-live-storage-target-\(UUID().uuidString)", isDirectory: true)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(
            "banny-live-storage-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: target)
        let host = try LiveRoomHostService(
            storageURL: link,
            assets: AssetCatalog(assetsRoot: Self.assetsRoot))
        let rejected = await makeRouter(host: host).response(
            to: try roomCreateRequest(title: "Linked Root", maximumOccupancy: 1))
        XCTAssertEqual(rejected.statusCode, 507)
        XCTAssertTrue(wire(rejected).contains("storage_quota_unavailable"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: target.path),
            [])
    }

    func testConcurrentCreationStorageReservationIsSerializedBeforeStaging() async throws {
        let gate = SuspensionGate()
        let reservation = LiveRoomStorageAccounting.creationReservationBytes(
            animateStill: false)
        let fixture = try makeHost(
            limits: LiveRoomHostLimits(
                maximumRooms: 10,
                maximumStorageBytes: reservation),
            creationAdmissionHook: { await gate.pause() })
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let router = makeRouter(host: fixture.host)
        let firstRequest = try roomCreateRequest(
            title: "Reserved First", maximumOccupancy: 1)
        let first = Task { await router.response(to: firstRequest) }

        await gate.waitUntilPaused()
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.storage.path),
            [],
            "admission must reserve quota before any staging write")
        let rejected = await router.response(to: try roomCreateRequest(
            title: "Reserved Second", maximumOccupancy: 1))
        XCTAssertEqual(rejected.statusCode, 507)
        XCTAssertTrue(wire(rejected).contains("storage_quota_exceeded"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.storage.path),
            [],
            "a quota rejection must not leave a staging directory")

        await gate.release()
        let firstResponse = await first.value
        XCTAssertEqual(firstResponse.statusCode, 201)
    }

    func testFailedBuilderReleasesRoomAndStorageReservations() async throws {
        let reservation = LiveRoomStorageAccounting.creationReservationBytes(
            animateStill: false)
        let fixture = try makeHost(limits: LiveRoomHostLimits(
            maximumRooms: 1,
            maximumStorageBytes: reservation))
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let router = makeRouter(host: fixture.host)
        let invalid = LiveRoomCreateRequest(
            title: "Invalid Media",
            background: LiveRoomMediaUpload(
                filename: "one.png",
                contentType: "image/png",
                base64: Self.onePixelPNG.base64EncodedString()),
            music: LiveRoomMediaUpload(
                filename: "broken.mp3",
                contentType: "audio/mpeg",
                base64: Data("not an mp3".utf8).base64EncodedString()),
            maxOccupancy: 1)
        let failed = await router.response(to: try .jsonPost(
            "/v1/rooms", value: invalid))
        XCTAssertEqual(failed.statusCode, 422)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.storage.path),
            [])

        let accepted = await router.response(to: try roomCreateRequest(
            title: "Valid After Failure", maximumOccupancy: 1))
        XCTAssertEqual(accepted.statusCode, 201)
    }

    func testStorageAccountingFailsClosedOnOverflow() {
        XCTAssertThrowsError(
            try LiveRoomStorageAccounting.checkedAdd(UInt64.max, 1)
        ) { error in
            XCTAssertEqual(
                error as? LiveRoomStorageAccountingError,
                .byteCountOverflow)
        }
    }

    func testColdFrameFanoutCoalescesAndCacheExpiresAt125Milliseconds() async throws {
        let fixture = try makeHost()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let created = try await createRoom(
            on: fixture.host,
            title: "Cached Frames",
            maximumOccupancy: 1)
        let roomID = created.payload.room.id

        let frames = try await withThrowingTaskGroup(
            of: Data.self,
            returning: [Data].self
        ) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await fixture.host.renderFrameJPEG(roomID: roomID)
                }
            }
            var values: [Data] = []
            for try await value in group { values.append(value) }
            return values
        }
        let first = try XCTUnwrap(frames.first)
        XCTAssertTrue(frames.allSatisfy { $0 == first })
        let coldStarts = try await fixture.host.frameRenderStartCount(roomID: roomID)
        XCTAssertEqual(coldStarts, 1)

        fixture.clock.advance(by: 124)
        let cached = try await fixture.host.renderFrameJPEG(roomID: roomID)
        let cachedStarts = try await fixture.host.frameRenderStartCount(roomID: roomID)
        XCTAssertEqual(cached, first)
        XCTAssertEqual(cachedStarts, 1)

        fixture.clock.advance(by: 1)
        let refreshed = try await fixture.host.renderFrameJPEG(roomID: roomID)
        let refreshedStarts = try await fixture.host.frameRenderStartCount(roomID: roomID)
        XCTAssertTrue(refreshed.starts(with: [0xff, 0xd8]))
        XCTAssertEqual(refreshedStarts, 2)
    }

    func testEndSealsOneFinalFrameAndReleasesHeavyRendererState() async throws {
        let renders = LockedCounter()
        let finalJPEG = Data([0xff, 0xd8, 0xff, 0xd9])
        let fixture = try makeHost(frameRenderHook: { _, _ in
            renders.increment()
            return finalJPEG
        })
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let created = try await createRoom(
            on: fixture.host,
            title: "Released Renderer",
            maximumOccupancy: 1)
        let roomID = created.payload.room.id

        let before = try await fixture.host.frameResourceState(roomID: roomID)
        XCTAssertTrue(before.rendererResident)
        XCTAssertFalse(before.finalFrameSealed)

        let ended = try await fixture.host.perform(.endRoom(
            roomID: roomID,
            authorization: LiveHTTPBearerCredential(token: created.payload.hostToken)))
        XCTAssertEqual(ended.statusCode, 200)
        let after = try await fixture.host.frameResourceState(roomID: roomID)
        XCTAssertFalse(after.rendererResident)
        XCTAssertTrue(after.finalFrameSealed)
        XCTAssertEqual(renders.value(), 1)

        let served = try await fixture.host.renderFrameJPEG(roomID: roomID)
        XCTAssertEqual(served, finalJPEG)
        XCTAssertEqual(renders.value(), 1, "sealed frames must not restart rendering")
    }

    func testFinalFrameFailureRetainsRendererForAuthenticatedEndRetry() async throws {
        let renderer = FailingOnceRenderHook()
        let fixture = try makeHost(frameRenderHook: { _, _ in
            try renderer.render()
        })
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let created = try await createRoom(
            on: fixture.host,
            title: "Retry Final Frame",
            maximumOccupancy: 1)
        let roomID = created.payload.room.id
        let credential = LiveHTTPBearerCredential(token: created.payload.hostToken)

        do {
            _ = try await fixture.host.perform(.endRoom(
                roomID: roomID, authorization: credential))
            XCTFail("The injected first final-frame failure should surface")
        } catch FrameHookTestError.injectedFailure {
            // The room is ended, but its host token and renderer remain for a
            // safe idempotent finalization retry.
        }
        let afterFailure = try await fixture.host.frameResourceState(roomID: roomID)
        XCTAssertTrue(afterFailure.rendererResident)
        XCTAssertFalse(afterFailure.finalFrameSealed)

        let retried = try await fixture.host.perform(.endRoom(
            roomID: roomID, authorization: credential))
        XCTAssertEqual(retried.statusCode, 200)
        let afterRetry = try await fixture.host.frameResourceState(roomID: roomID)
        XCTAssertFalse(afterRetry.rendererResident)
        XCTAssertTrue(afterRetry.finalFrameSealed)
        XCTAssertEqual(renderer.attemptCount(), 2)
    }

    func testDuplicateReceiptEvictionIsFIFO() async throws {
        let fixture = try makeHost()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let created = try await createRoom(
            on: fixture.host,
            title: "Receipt Queue",
            maximumOccupancy: 1)
        let roomID = created.payload.room.id
        let router = makeRouter(host: fixture.host)
        let joined = await router.response(to: try joinRequest(
            roomID: roomID,
            displayName: "Queue Bot"))
        let receipt = try LiveHTTPJSON.decoder.decode(
            JoinEnvelope.self, from: joined.body)

        var oldest: AgentDecisionEnvelope?
        var firstRetained: AgentDecisionEnvelope?
        for index in 0..<129 {
            if index > 0 { fixture.clock.advance(by: 250) }
            let contextResponse = await router.response(to: .authorizedGet(
                "/v1/rooms/\(roomID)/decisions/next",
                bearer: receipt.sessionToken))
            XCTAssertEqual(contextResponse.statusCode, 200, "poll \(index)")
            let context = try LiveHTTPJSON.decoder.decode(
                AgentContextEnvelope.self, from: contextResponse.body)
            let intentID = index == 0
                ? "z-oldest"
                : String(format: "a-%03d", index - 1)
            let decision = AgentDecisionEnvelope(
                requestID: context.requestID,
                intentID: intentID,
                actions: [],
                requestAfterMS: 250)
            if index == 0 { oldest = decision }
            if index == 1 { firstRetained = decision }
            let submitted = await router.response(to: try .authorizedJSONPost(
                "/v1/rooms/\(roomID)/decisions/\(context.requestID)",
                value: decision,
                bearer: receipt.sessionToken))
            XCTAssertEqual(submitted.statusCode, 200, "submit \(index)")
        }

        let evicted = try XCTUnwrap(oldest)
        let evictedRetry = await router.response(to: try .authorizedJSONPost(
            "/v1/rooms/\(roomID)/decisions/\(evicted.requestID)",
            value: evicted,
            bearer: receipt.sessionToken))
        XCTAssertEqual(evictedRetry.statusCode, 409)
        XCTAssertTrue(wire(evictedRetry).contains("no_outstanding_decision"))

        let retained = try XCTUnwrap(firstRetained)
        let retainedRetry = await router.response(to: try .authorizedJSONPost(
            "/v1/rooms/\(roomID)/decisions/\(retained.requestID)",
            value: retained,
            bearer: receipt.sessionToken))
        XCTAssertEqual(retainedRetry.statusCode, 200)
        let duplicate = try LiveHTTPJSON.decoder.decode(
            LiveRoomSubmitResult.self, from: retainedRetry.body)
        XCTAssertEqual(duplicate.disposition, .duplicate)
    }

    func testSubmitContinuationPreservesNewerOutstandingPollRequest() async throws {
        let gate = SuspensionGate()
        let fixture = try makeHost(submitContinuationHook: {
            await gate.pause()
        })
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let created = try await createRoom(
            on: fixture.host,
            title: "Submit Reentrancy",
            maximumOccupancy: 1)
        let roomID = created.payload.room.id
        let router = makeRouter(host: fixture.host)
        let joined = await router.response(to: try joinRequest(
            roomID: roomID,
            displayName: "Reentrant Bot"))
        let receipt = try LiveHTTPJSON.decoder.decode(
            JoinEnvelope.self, from: joined.body)

        let firstPoll = await router.response(to: .authorizedGet(
            "/v1/rooms/\(roomID)/decisions/next",
            bearer: receipt.sessionToken))
        let firstContext = try LiveHTTPJSON.decoder.decode(
            AgentContextEnvelope.self, from: firstPoll.body)
        let firstDecision = AgentDecisionEnvelope(
            requestID: firstContext.requestID,
            intentID: "first-intent",
            actions: [],
            requestAfterMS: 250)
        let firstSubmitRequest = try LiveHTTPRequest.authorizedJSONPost(
            "/v1/rooms/\(roomID)/decisions/\(firstContext.requestID)",
            value: firstDecision,
            bearer: receipt.sessionToken)
        let firstSubmit = Task {
            await router.response(to: firstSubmitRequest)
        }

        await gate.waitUntilPaused()
        fixture.clock.advance(by: 250)
        let secondPoll = await router.response(to: .authorizedGet(
            "/v1/rooms/\(roomID)/decisions/next",
            bearer: receipt.sessionToken))
        XCTAssertEqual(secondPoll.statusCode, 200)
        let secondContext = try LiveHTTPJSON.decoder.decode(
            AgentContextEnvelope.self, from: secondPoll.body)
        XCTAssertNotEqual(secondContext.requestID, firstContext.requestID)

        await gate.release()
        let firstSubmitResponse = await firstSubmit.value
        XCTAssertEqual(firstSubmitResponse.statusCode, 200)

        let secondDecision = AgentDecisionEnvelope(
            requestID: secondContext.requestID,
            intentID: "second-intent",
            actions: [],
            requestAfterMS: 250)
        let secondSubmit = await router.response(to: try .authorizedJSONPost(
            "/v1/rooms/\(roomID)/decisions/\(secondContext.requestID)",
            value: secondDecision,
            bearer: receipt.sessionToken))
        XCTAssertEqual(secondSubmit.statusCode, 200)
        let accepted = try LiveHTTPJSON.decoder.decode(
            LiveRoomSubmitResult.self, from: secondSubmit.body)
        XCTAssertEqual(accepted.disposition, .accepted)
    }

    func testAutonomousJoinDisablesParticipantControlAndKeepsPromptPrivate() async throws {
        let provider = RecordingDirectorDecisionProvider()
        let fixture = try makeHost(
            directorDecisionProvider: provider,
            autonomyEnabled: true,
            legacyParticipantControlEnabled: false)
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let created = try await createRoom(
            on: fixture.host,
            title: "Autonomous Privacy",
            maximumOccupancy: 1)
        let roomID = created.payload.room.id
        let router = makeRouter(host: fixture.host)
        let privatePrompt = "PRIVATE-PROMPT-7c87: play a cautious lighthouse keeper"

        let missingPrompt = await router.response(to: try .jsonPost(
            "/v1/rooms/\(roomID)/join",
            value: LegacyPromptlessJoin(
                displayName: "Promptless",
                avatar: LiveRoomJoinAvatar(body: .orange))))
        XCTAssertEqual(missingPrompt.statusCode, 400)
        XCTAssertTrue(wire(missingPrompt).contains("invalid_join"))

        let joined = await router.response(to: try joinRequest(
            roomID: roomID,
            displayName: "Beacon",
            characterPrompt: privatePrompt))
        XCTAssertEqual(joined.statusCode, 201)
        let receipt = try LiveHTTPJSON.decoder.decode(
            JoinEnvelope.self, from: joined.body)
        let observedPrompt = await provider.waitForFirstPrompt()
        XCTAssertEqual(observedPrompt, privatePrompt)

        let poll = await router.response(to: .authorizedGet(
            "/v1/rooms/\(roomID)/decisions/next",
            bearer: receipt.sessionToken))
        XCTAssertEqual(poll.statusCode, 403)
        XCTAssertTrue(wire(poll).contains("participant_control_disabled"))

        let blockedDecision = AgentDecisionEnvelope(
            requestID: "blocked-request",
            intentID: "blocked-intent",
            actions: [])
        let submit = await router.response(to: try .authorizedJSONPost(
            "/v1/rooms/\(roomID)/decisions/blocked-request",
            value: blockedDecision,
            bearer: receipt.sessionToken))
        XCTAssertEqual(submit.statusCode, 403)
        XCTAssertTrue(wire(submit).contains("participant_control_disabled"))

        let publicRoom = await router.response(to: .get("/v1/rooms/\(roomID)"))
        XCTAssertFalse(wire(joined).contains(privatePrompt))
        XCTAssertFalse(wire(publicRoom).contains(privatePrompt))

        let leave = await router.response(to: .authorizedPost(
            "/v1/rooms/\(roomID)/leave",
            bearer: receipt.sessionToken))
        XCTAssertEqual(leave.statusCode, 204,
            "Autonomy disables decision endpoints, not explicit session leave.")

        let ended = await router.response(to: .authorizedPost(
            "/v1/rooms/\(roomID)/end",
            bearer: created.payload.hostToken))
        XCTAssertEqual(ended.statusCode, 200)
        let packageURL = try await fixture.host.packageURL(roomID: roomID)
        let showJSON = try String(
            contentsOf: packageURL.appendingPathComponent("show.json"),
            encoding: .utf8)
        XCTAssertFalse(showJSON.contains(privatePrompt))
    }

    func testPublicJoinEnforcesCapacityAndExpiresInactiveSeatThroughRouter() async throws {
        let fixture = try makeHost()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let created = try await createRoom(
            on: fixture.host,
            title: "One Seat",
            maximumOccupancy: 1)
        let router = makeRouter(host: fixture.host)

        let first = await router.response(to: try joinRequest(
            roomID: created.payload.room.id,
            displayName: "First Bot"))
        XCTAssertEqual(first.statusCode, 201)
        let receipt = try LiveHTTPJSON.decoder.decode(JoinEnvelope.self, from: first.body)
        XCTAssertEqual(receipt.room.occupancy, 1)
        XCTAssertEqual(receipt.room.participants.map(\.displayName), ["First Bot"])
        XCTAssertFalse(receipt.sessionToken.isEmpty)

        let second = await router.response(to: try joinRequest(
            roomID: created.payload.room.id,
            displayName: "Second Bot"))
        XCTAssertEqual(second.statusCode, 409)
        XCTAssertTrue(wire(second).contains("room_full"))

        fixture.clock.advance(by: 45_001)
        let replacement = await router.response(to: try joinRequest(
            roomID: created.payload.room.id,
            displayName: "Replacement Bot"))
        XCTAssertEqual(replacement.statusCode, 201)
        let replacementReceipt = try LiveHTTPJSON.decoder.decode(
            JoinEnvelope.self, from: replacement.body)
        XCTAssertEqual(replacementReceipt.room.occupancy, 1)
        XCTAssertEqual(
            replacementReceipt.room.participants.map(\.displayName),
            ["Replacement Bot"])

        let expiredSession = await router.response(to: .authorizedGet(
            "/v1/rooms/\(created.payload.room.id)/decisions/next",
            bearer: receipt.sessionToken))
        XCTAssertEqual(expiredSession.statusCode, 409)
        XCTAssertTrue(wire(expiredSession).contains("participant_disconnected"))

        let snapshot = await router.response(to: .get(
            "/v1/rooms/\(created.payload.room.id)"))
        let room = try LiveHTTPJSON.decoder.decode(RoomEnvelope.self, from: snapshot.body).room
        XCTAssertEqual(room.occupancy, 1)
        XCTAssertEqual(room.participants.map(\.id), [replacementReceipt.participantID])
        XCTAssertFalse(wire(snapshot).contains(receipt.sessionToken))
    }

    func testAllowlistedParticipantAuthDecisionCursorAndLeave() async throws {
        let fixture = try makeHost()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let created = try await createRoom(
            on: fixture.host,
            title: "Invite Stage",
            maximumOccupancy: 2,
            allowlist: ["alice"])
        let roomID = created.payload.room.id
        let invitation = try XCTUnwrap(created.payload.invitations.first)
        let router = makeRouter(host: fixture.host)

        let missingInvite = await router.response(to: try joinRequest(
            roomID: roomID,
            displayName: "Alice",
            identity: "alice"))
        XCTAssertEqual(missingInvite.statusCode, 403)
        XCTAssertTrue(wire(missingInvite).contains("identity_not_invited"))

        let wrongInvite = await router.response(to: try joinRequest(
            roomID: roomID,
            displayName: "Alice",
            identity: "alice",
            invite: "wrong-capability"))
        XCTAssertEqual(wrongInvite.statusCode, 403)

        let joined = await router.response(to: try joinRequest(
            roomID: roomID,
            displayName: "Alice",
            identity: "alice",
            invite: invitation.invite))
        XCTAssertEqual(joined.statusCode, 201)
        let receipt = try LiveHTTPJSON.decoder.decode(JoinEnvelope.self, from: joined.body)
        XCTAssertEqual(receipt.room.occupancy, 1)

        let replay = await router.response(to: try joinRequest(
            roomID: roomID,
            displayName: "Impostor",
            identity: "alice",
            invite: invitation.invite))
        XCTAssertEqual(replay.statusCode, 409)
        XCTAssertTrue(wire(replay).contains("identity_already_active"))

        let unauthenticated = await router.response(to: .get(
            "/v1/rooms/\(roomID)/decisions/next"))
        XCTAssertEqual(unauthenticated.statusCode, 401)
        XCTAssertEqual(unauthenticated.headers["WWW-Authenticate"], "Bearer")

        let firstContextResponse = await router.response(to: .authorizedGet(
            "/v1/rooms/\(roomID)/decisions/next",
            bearer: receipt.sessionToken))
        XCTAssertEqual(firstContextResponse.statusCode, 200)
        let firstContext = try LiveHTTPJSON.decoder.decode(
            AgentContextEnvelope.self, from: firstContextResponse.body)
        XCTAssertEqual(firstContext.protocolVersion, BannyAgentProtocol.version)
        XCTAssertEqual(firstContext.participantID, receipt.participantID)

        let noOp = AgentDecisionEnvelope(
            requestID: firstContext.requestID,
            intentID: "intent-idle-1",
            actions: [],
            requestAfterMS: 250)
        let submit = await router.response(to: try .authorizedJSONPost(
            "/v1/rooms/\(roomID)/decisions/\(firstContext.requestID)",
            value: noOp,
            bearer: receipt.sessionToken))
        XCTAssertEqual(submit.statusCode, 200)
        let accepted = try LiveHTTPJSON.decoder.decode(
            LiveRoomSubmitResult.self, from: submit.body)
        XCTAssertEqual(accepted.disposition, .accepted)
        XCTAssertGreaterThan(accepted.seq, firstContext.basisSeq,
            "Even an idle decision advances the durable room event sequence.")

        let duplicate = await router.response(to: try .authorizedJSONPost(
            "/v1/rooms/\(roomID)/decisions/\(firstContext.requestID)",
            value: noOp,
            bearer: receipt.sessionToken))
        XCTAssertEqual(duplicate.statusCode, 200)
        let duplicateResult = try LiveHTTPJSON.decoder.decode(
            LiveRoomSubmitResult.self, from: duplicate.body)
        XCTAssertEqual(duplicateResult.disposition, .duplicate)
        XCTAssertEqual(duplicateResult.seq, accepted.seq)

        let notDue = await router.response(to: .authorizedGet(
            "/v1/rooms/\(roomID)/decisions/next?after=\(firstContext.basisSeq)",
            bearer: receipt.sessionToken))
        XCTAssertEqual(notDue.statusCode, 204)

        fixture.clock.advance(by: 250)
        let next = await router.response(to: .authorizedGet(
            "/v1/rooms/\(roomID)/decisions/next?after=\(firstContext.basisSeq)",
            bearer: receipt.sessionToken))
        XCTAssertEqual(next.statusCode, 200)
        let nextContext = try LiveHTTPJSON.decoder.decode(
            AgentContextEnvelope.self, from: next.body)
        XCTAssertEqual(nextContext.basisSeq, accepted.seq)
        XCTAssertGreaterThan(nextContext.basisSeq, firstContext.basisSeq,
            "The HTTP poll cursor must advance even when the scene decision is idle.")

        let badLeave = await router.response(to: .authorizedPost(
            "/v1/rooms/\(roomID)/leave", bearer: "not-a-session"))
        XCTAssertEqual(badLeave.statusCode, 401)
        let leave = await router.response(to: .authorizedPost(
            "/v1/rooms/\(roomID)/leave", bearer: receipt.sessionToken))
        XCTAssertEqual(leave.statusCode, 204)
        let leftSession = await router.response(to: .authorizedGet(
            "/v1/rooms/\(roomID)/decisions/next", bearer: receipt.sessionToken))
        XCTAssertEqual(leftSession.statusCode, 401)
        XCTAssertTrue(wire(leftSession).contains("invalid_session"))

        // The same display name, deliberately: a reconnect may not rename the
        // character it is resuming. `LiveRoomDirectorTests` states that
        // invariant directly ("A reconnect changed its immutable display
        // name"), and a recording's character tracks are immutable once a seat
        // is taken. This test asked for 201 while rejoining as "Alice Again",
        // so the two suites contradicted each other and this one lost.
        let rejoined = await router.response(to: try joinRequest(
            roomID: roomID,
            displayName: "Alice",
            identity: "alice",
            invite: invitation.invite))
        XCTAssertEqual(rejoined.statusCode, 201,
            "The invite capability remains valid so its identity can reconnect.")
        let reconnectReceipt = try LiveHTTPJSON.decoder.decode(
            JoinEnvelope.self, from: rejoined.body)
        XCTAssertEqual(reconnectReceipt.participantID, receipt.participantID)
        XCTAssertNotEqual(reconnectReceipt.sessionToken, receipt.sessionToken)
        let reconnectLeave = await router.response(to: .authorizedPost(
            "/v1/rooms/\(roomID)/leave",
            bearer: reconnectReceipt.sessionToken))
        XCTAssertEqual(reconnectLeave.statusCode, 204)
        let kick = await router.response(to: LiveHTTPRequest.authorizedDelete(
            "/v1/rooms/\(roomID)/participants/\(reconnectReceipt.participantID)",
            bearer: created.payload.hostToken))
        XCTAssertEqual(kick.statusCode, 200)

        let revokedSession = await router.response(to: .authorizedGet(
            "/v1/rooms/\(roomID)/decisions/next",
            bearer: reconnectReceipt.sessionToken))
        XCTAssertEqual(revokedSession.statusCode, 401)
        XCTAssertTrue(wire(revokedSession).contains("invalid_session"))

        let revokedInvite = await router.response(to: try joinRequest(
            roomID: roomID,
            displayName: "Alice Yet Again",
            identity: "alice",
            invite: invitation.invite))
        XCTAssertEqual(revokedInvite.statusCode, 403)
        XCTAssertTrue(wire(revokedInvite).contains("identity_not_invited"))

        let publicSnapshot = await router.response(to: .get("/v1/rooms/\(roomID)"))
        let publicRoom = try LiveHTTPJSON.decoder.decode(
            RoomEnvelope.self, from: publicSnapshot.body).room
        XCTAssertEqual(publicRoom.occupancy, 0)
        XCTAssertTrue(publicRoom.participants.isEmpty)
        let publicWire = wire(publicSnapshot)
        XCTAssertFalse(publicWire.contains(receipt.sessionToken))
        XCTAssertFalse(publicWire.contains(reconnectReceipt.sessionToken))
        XCTAssertFalse(publicWire.contains(invitation.invite))
        XCTAssertFalse(publicWire.contains(created.payload.hostToken))
    }

    func testHostKickFrameAndEndRequireHostCapabilityAndFinalizePackage() async throws {
        let fixture = try makeHost()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let created = try await createRoom(
            on: fixture.host,
            title: "Host Stage",
            maximumOccupancy: 2)
        let roomID = created.payload.room.id
        let router = makeRouter(host: fixture.host)

        let firstResponse = await router.response(to: try joinRequest(
            roomID: roomID, displayName: "One"))
        let secondResponse = await router.response(to: try joinRequest(
            roomID: roomID, displayName: "Two"))
        let first = try LiveHTTPJSON.decoder.decode(JoinEnvelope.self, from: firstResponse.body)
        let second = try LiveHTTPJSON.decoder.decode(JoinEnvelope.self, from: secondResponse.body)

        let rejectedKick = await router.response(to: LiveHTTPRequest.authorizedDelete(
            "/v1/rooms/\(roomID)/participants/\(first.participantID)",
            bearer: "not-the-host"))
        XCTAssertEqual(rejectedKick.statusCode, 403)

        let kicked = await router.response(to: LiveHTTPRequest.authorizedDelete(
            "/v1/rooms/\(roomID)/participants/\(first.participantID)",
            bearer: created.payload.hostToken))
        XCTAssertEqual(kicked.statusCode, 200)
        let kickedRoom = try LiveHTTPJSON.decoder.decode(RoomEnvelope.self, from: kicked.body).room
        XCTAssertEqual(kickedRoom.occupancy, 1)
        XCTAssertEqual(kickedRoom.participants.map(\.id), [second.participantID])

        let kickedSession = await router.response(to: .authorizedGet(
            "/v1/rooms/\(roomID)/decisions/next",
            bearer: first.sessionToken))
        XCTAssertEqual(kickedSession.statusCode, 401)
        XCTAssertTrue(wire(kickedSession).contains("invalid_session"))

        let frame = await router.response(to: .get("/v1/rooms/\(roomID)/frame.jpg"))
        XCTAssertEqual(frame.statusCode, 200)
        XCTAssertEqual(frame.headers["Content-Type"], "image/jpeg")
        XCTAssertTrue(frame.body.starts(with: [0xff, 0xd8]))

        let rejectedEnd = await router.response(to: .authorizedPost(
            "/v1/rooms/\(roomID)/end", bearer: "not-the-host"))
        XCTAssertEqual(rejectedEnd.statusCode, 403)
        let ended = await router.response(to: .authorizedPost(
            "/v1/rooms/\(roomID)/end", bearer: created.payload.hostToken))
        XCTAssertEqual(ended.statusCode, 200)
        let endedRoom = try LiveHTTPJSON.decoder.decode(RoomEnvelope.self, from: ended.body).room
        XCTAssertEqual(endedRoom.state, "ended")

        let packageURL = try await fixture.host.packageURL(roomID: roomID)
        let finalShowURL = packageURL.appendingPathComponent("show.json")
        let finalWire = try String(contentsOf: finalShowURL, encoding: .utf8)
        let finalDocument = try ShowJSONCodec.decodeDocument(finalWire)
        XCTAssertEqual(finalDocument.show.count, 1)
        XCTAssertEqual(finalDocument.show[0].name, "Room recording")
        XCTAssertEqual(finalDocument.stage.audioTracks.count, 1)
        XCTAssertEqual(
            finalDocument.stage.audioTracks.flatMap(\.clips).map(\.id),
            ["room-music"])
        XCTAssertTrue(finalDocument.stage.characters.allSatisfy {
            $0.muted && $0.clips.isEmpty
        })
        XCTAssertFalse(finalWire.contains(created.payload.hostToken))
        XCTAssertFalse(finalWire.contains(first.sessionToken))
        XCTAssertFalse(finalWire.contains(second.sessionToken))

        let endedSession = await router.response(to: .authorizedGet(
            "/v1/rooms/\(roomID)/decisions/next", bearer: second.sessionToken))
        XCTAssertEqual(endedSession.statusCode, 401)
        XCTAssertTrue(wire(endedSession).contains("invalid_session"))

        let joinAfterEnd = await router.response(to: try joinRequest(
            roomID: roomID, displayName: "Late Bot"))
        XCTAssertEqual(joinAfterEnd.statusCode, 409)
        XCTAssertTrue(wire(joinAfterEnd).contains("room_ended"))
    }

    func testKickCleansCapabilitiesWhenItRacesParticipantLeave() async throws {
        let fixture = try makeHost()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let created = try await createRoom(
            on: fixture.host,
            title: "Kick Race",
            maximumOccupancy: 1,
            allowlist: ["alice"])
        let roomID = created.payload.room.id
        let invitation = try XCTUnwrap(created.payload.invitations.first)
        let router = makeRouter(host: fixture.host)
        let joined = await router.response(to: try joinRequest(
            roomID: roomID,
            displayName: "Alice",
            identity: invitation.identity,
            invite: invitation.invite))
        let receipt = try LiveHTTPJSON.decoder.decode(
            JoinEnvelope.self, from: joined.body)

        async let leave = router.response(to: .authorizedPost(
            "/v1/rooms/\(roomID)/leave",
            bearer: receipt.sessionToken))
        async let kick = router.response(to: LiveHTTPRequest.authorizedDelete(
            "/v1/rooms/\(roomID)/participants/\(receipt.participantID)",
            bearer: created.payload.hostToken))
        let (leaveResponse, kickResponse) = await (leave, kick)

        XCTAssertTrue([204, 401, 409].contains(leaveResponse.statusCode))
        XCTAssertEqual(kickResponse.statusCode, 200)
        let kickedRoom = try LiveHTTPJSON.decoder.decode(
            RoomEnvelope.self, from: kickResponse.body).room
        XCTAssertEqual(kickedRoom.occupancy, 0)

        let oldSession = await router.response(to: .authorizedGet(
            "/v1/rooms/\(roomID)/decisions/next",
            bearer: receipt.sessionToken))
        XCTAssertEqual(oldSession.statusCode, 401)
        let rejectedRejoin = await router.response(to: try joinRequest(
            roomID: roomID,
            displayName: "Alice Returns",
            identity: invitation.identity,
            invite: invitation.invite))
        XCTAssertEqual(rejectedRejoin.statusCode, 403)
        XCTAssertTrue(wire(rejectedRejoin).contains("identity_not_invited"))
    }

    func testConcurrentEndRequestsShareFrozenResultAndFinalization() async throws {
        let fixture = try makeHost()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let created = try await createRoom(
            on: fixture.host,
            title: "Concurrent Ending",
            maximumOccupancy: 1)
        let roomID = created.payload.room.id
        let credential = LiveHTTPBearerCredential(token: created.payload.hostToken)

        let results = try await withThrowingTaskGroup(
            of: LiveHTTPServiceResult.self,
            returning: [LiveHTTPServiceResult].self
        ) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await fixture.host.perform(.endRoom(
                        roomID: roomID,
                        authorization: credential))
                }
            }
            var values: [LiveHTTPServiceResult] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 12)
        XCTAssertTrue(results.allSatisfy { $0.statusCode == 200 })
        let rooms = try results.map {
            try LiveHTTPJSON.decoder.decode(RoomEnvelope.self, from: $0.body).room
        }
        let frozen = try XCTUnwrap(rooms.first)
        XCTAssertEqual(frozen.state, "ended")
        XCTAssertTrue(rooms.allSatisfy { $0 == frozen })

        let packageURL = try await fixture.host.packageURL(roomID: roomID)
        let showURL = packageURL.appendingPathComponent("show.json")
        let beforeRetry = try Data(contentsOf: showURL)
        let retried = try await fixture.host.perform(.endRoom(
            roomID: roomID,
            authorization: credential))
        XCTAssertEqual(retried.statusCode, 200)
        XCTAssertEqual(retried.body, results[0].body)
        XCTAssertEqual(try Data(contentsOf: showURL), beforeRetry)
        let document = try ShowJSONCodec.decodeDocument(
            String(decoding: beforeRetry, as: UTF8.self))
        XCTAssertEqual(document.show.count, 1)
        XCTAssertEqual(document.show[0].name, "Room recording")
        let frameState = try await fixture.host.frameResourceState(roomID: roomID)
        let frameStarts = try await fixture.host.frameRenderStartCount(roomID: roomID)
        XCTAssertFalse(frameState.rendererResident)
        XCTAssertTrue(frameState.finalFrameSealed)
        XCTAssertEqual(frameStarts, 1, "concurrent end calls must share final-frame work")
    }

    private func makeHost(
        submitContinuationHook: (@Sendable () async -> Void)? = nil,
        directorDecisionProvider: (any LiveDirectorDecisionProvider)? = nil,
        autonomyEnabled: Bool = false,
        legacyParticipantControlEnabled: Bool = true,
        frameRenderHook: (@Sendable (ShowDocument, Double) async throws -> Data)? = nil,
        renderLimiter: LiveRoomRenderLimiter? = nil,
        limits: LiveRoomHostLimits = LiveRoomHostLimits(),
        creationAdmissionHook: (@Sendable () async -> Void)? = nil
    ) throws -> (
        host: LiveRoomHostService,
        storage: URL,
        clock: TestClock
    ) {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "banny-live-host-tests-\(UUID().uuidString)", isDirectory: true)
        let catalog = try AssetCatalog(assetsRoot: Self.assetsRoot)
        let clock = TestClock(value: 10_000)
        let provider: any LiveDirectorDecisionProvider =
            directorDecisionProvider ?? BuiltInLiveDirectorDecisionProvider()
        let host = try LiveRoomHostService(
            storageURL: storage,
            assets: catalog,
            clockMS: { clock.get() },
            submitContinuationHook: submitContinuationHook,
            directorDecisionProvider: provider,
            autonomyEnabled: autonomyEnabled,
            legacyParticipantControlEnabled: legacyParticipantControlEnabled,
            frameRenderHook: frameRenderHook,
            renderLimiter: renderLimiter ?? LiveRoomRenderLimiter(limit: 2),
            limits: limits,
            creationAdmissionHook: creationAdmissionHook)
        return (
            host,
            storage,
            clock)
    }

    private func makeRouter(host: LiveRoomHostService) -> LiveHTTPRouter {
        LiveHTTPRouter(
            service: host,
            frameRenderer: { roomID in
                try await host.renderFrameJPEG(roomID: roomID)
            })
    }

    private func joinRequest(
        roomID: String,
        displayName: String,
        characterPrompt: String = "Be playful, concise, and react to the room.",
        identity: String? = nil,
        invite: String? = nil
    ) throws -> LiveHTTPRequest {
        try .jsonPost(
            "/v1/rooms/\(roomID)/join",
            value: LiveRoomJoinRequest(
                displayName: displayName,
                characterPrompt: characterPrompt,
                identity: identity,
                invite: invite,
                avatar: LiveRoomJoinAvatar(body: .orange)))
    }

    private func wire(_ response: LiveHTTPResponse) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    private func createRoom(
        on host: LiveRoomHostService,
        title: String,
        maximumOccupancy: Int,
        allowlist: [String] = []
    ) async throws -> CreatedRoom {
        let request = LiveRoomCreateRequest(
            title: title,
            premise: "A tiny deterministic room fixture.",
            background: LiveRoomMediaUpload(
                filename: "one.png",
                contentType: "image/png",
                base64: Self.onePixelPNG.base64EncodedString()),
            music: LiveRoomMediaUpload(
                filename: "silence.mp3",
                contentType: "audio/mpeg",
                base64: Self.silentMP3.base64EncodedString()),
            maxOccupancy: maximumOccupancy,
            allowlist: allowlist,
            animateStill: false)
        let body = try LiveHTTPJSON.encoder.encode(request)
        let response = try await host.perform(.createRoom(json: body))
        let payload = try LiveHTTPJSON.decoder.decode(CreateEnvelope.self, from: response.body)
        return CreatedRoom(response: response, payload: payload)
    }

    private func roomCreateRequest(
        title: String,
        maximumOccupancy: Int,
        animateStill: Bool = false
    ) throws -> LiveHTTPRequest {
        try .jsonPost(
            "/v1/rooms",
            value: LiveRoomCreateRequest(
                title: title,
                premise: "A tiny deterministic room fixture.",
                background: LiveRoomMediaUpload(
                    filename: "one.png",
                    contentType: "image/png",
                    base64: Self.onePixelPNG.base64EncodedString()),
                music: LiveRoomMediaUpload(
                    filename: "silence.mp3",
                    contentType: "audio/mpeg",
                    base64: Self.silentMP3.base64EncodedString()),
                maxOccupancy: maximumOccupancy,
                animateStill: animateStill))
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/"
        + "x8AAusB9Wl2gF0AAAAASUVORK5CYII=")!

    /// 120 ms of mono silence. Keeping the complete valid MP3 inline makes
    /// room-host tests independent of ffmpeg and machine-specific fixtures.
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
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//NAxKQAAANI"
        + "AAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVX/80LEowAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVX/80DEpAAAA0gAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
        + "VVVVVVVVVVVVVVVVVVVVVVVVQ==")!
}

private struct LegacyPromptlessJoin: Encodable {
    let displayName: String
    let avatar: LiveRoomJoinAvatar

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case avatar
    }
}

private actor RecordingDirectorDecisionProvider: LiveDirectorDecisionProvider {
    private var firstPrompt: String?
    private var promptWaiters: [CheckedContinuation<String, Never>] = []

    func decide(
        characterPrompt: String,
        context: AgentContextEnvelope
    ) async throws -> AgentDecisionEnvelope {
        if firstPrompt == nil {
            firstPrompt = characterPrompt
            let waiters = promptWaiters
            promptWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume(returning: characterPrompt) }
        }
        return AgentDecisionEnvelope(
            requestID: context.requestID,
            intentID: "host-autonomy-test-\(UUID().uuidString.lowercased())",
            actions: [],
            requestAfterMS: 10_000)
    }

    func waitForFirstPrompt() async -> String {
        if let firstPrompt { return firstPrompt }
        return await withCheckedContinuation { continuation in
            promptWaiters.append(continuation)
        }
    }
}

private struct CreatedRoom {
    let response: LiveHTTPServiceResult
    let payload: CreateEnvelope
}

private struct CreateEnvelope: Decodable {
    let room: LiveRoomPublicSnapshot
    let hostToken: String
    let invitations: [LiveRoomInvitation]

    private enum CodingKeys: String, CodingKey {
        case room, invitations
        case hostToken = "host_token"
    }
}

private struct RoomListEnvelope: Decodable {
    let rooms: [LiveRoomPublicSnapshot]
}

private struct RoomEnvelope: Decodable {
    let room: LiveRoomPublicSnapshot
}

private struct JoinEnvelope: Decodable {
    let participantID: String
    let sessionToken: String
    let seat: Int
    let room: LiveRoomPublicSnapshot

    private enum CodingKeys: String, CodingKey {
        case participantID = "participant_id"
        case sessionToken = "session_token"
        case seat, room
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    private var reads = 0

    init(value: Int64) {
        self.value = value
    }

    func get() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return value
    }

    func readCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func advance(by milliseconds: Int64) {
        lock.lock()
        value += milliseconds
        lock.unlock()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private enum FrameHookTestError: Error {
    case injectedFailure
}

private final class FailingOnceRenderHook: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    func render() throws -> Data {
        lock.lock()
        attempts += 1
        let current = attempts
        lock.unlock()
        if current == 1 { throw FrameHookTestError.injectedFailure }
        return Data([0xff, 0xd8, 0xff, 0xd9])
    }

    func attemptCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }
}

private actor SuspensionGate {
    private var paused = false
    private var released = false
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        if released { return }
        paused = true
        let observers = pauseObservers
        pauseObservers.removeAll(keepingCapacity: false)
        for observer in observers { observer.resume() }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { continuation in
            pauseObservers.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

private extension LiveHTTPRequest {
    static func get(_ target: String) -> LiveHTTPRequest {
        LiveHTTPRequest(method: "GET", target: target)
    }

    static func jsonPost<T: Encodable>(
        _ target: String,
        value: T
    ) throws -> LiveHTTPRequest {
        LiveHTTPRequest(
            method: "POST",
            target: target,
            headers: ["Content-Type": "application/json"],
            body: try LiveHTTPJSON.encoder.encode(value))
    }

    static func authorizedJSONPost<T: Encodable>(
        _ target: String,
        value: T,
        bearer: String
    ) throws -> LiveHTTPRequest {
        var request = try jsonPost(target, value: value)
        request.headers["authorization"] = "Bearer \(bearer)"
        return request
    }

    static func authorizedGet(_ target: String, bearer: String) -> LiveHTTPRequest {
        var request = get(target)
        request.headers["authorization"] = "Bearer \(bearer)"
        return request
    }

    static func authorizedPost(_ target: String, bearer: String) -> LiveHTTPRequest {
        LiveHTTPRequest(
            method: "POST",
            target: target,
            headers: ["authorization": "Bearer \(bearer)"])
    }

    static func authorizedDelete(_ target: String, bearer: String) -> LiveHTTPRequest {
        LiveHTTPRequest(
            method: "DELETE",
            target: target,
            headers: ["authorization": "Bearer \(bearer)"])
    }
}
