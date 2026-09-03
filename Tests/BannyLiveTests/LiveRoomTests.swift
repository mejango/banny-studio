import Foundation
import XCTest
import BannyCore
@testable import BannyLive

final class LiveRoomTests: XCTestCase {
    func testJoinIsAllowlistedAtomicAndSanitizesSubmittedTimeline() async throws {
        let packageURL = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let room = try LiveRoom(
            id: "room-a",
            title: "Allowlisted room",
            maxOccupancy: 1,
            allowlist: ["alice@example.test"],
            draftDocument: draft(),
            packageURL: packageURL,
            startedAtMS: 1_000)
        let submitted = Character(
            body: .pink,
            baseOutfit: [3: "chain"],
            subs: [Subtitle(text: "injected", start: 0, dur: 10)],
            clips: [AudioClip(
                id: "untrusted-voice",
                name: "Must be discarded",
                start: 0,
                dur: 1,
                srcDur: 1,
                kind: .speech)],
            voicePitch: 12,
            voiceSpeed: 2,
            speechVoice: SpeechVoiceProfile(voiceIdentifier: "untrusted.voice"),
            events: [.key(t: 0, code: .keyJ, down: true)],
            name: "untrusted name",
            muted: false,
            solo: true)

        do {
            _ = try await room.join(
                identity: "mallory@example.test",
                displayName: "Mallory",
                character: submitted,
                nowMS: 1_100)
            XCTFail("an uninvited identity must not mutate the room")
        } catch {
            XCTAssertEqual(error as? LiveRoomError, .identityNotInvited)
        }
        let documentAfterDeniedJoin = await room.document()
        XCTAssertTrue(documentAfterDeniedJoin.stage.characters.isEmpty)

        let receipt = try await room.join(
            identity: "alice@example.test",
            displayName: "Alice",
            character: submitted,
            nowMS: 1_200)
        XCTAssertEqual(receipt.participantID, "room-a-p1")
        XCTAssertEqual(receipt.seat, 0)
        XCTAssertFalse(receipt.reconnected)

        let document = await room.document()
        XCTAssertEqual(document.stage.characters.count, 1)
        XCTAssertEqual(document.stage.characters[0].body, .pink)
        XCTAssertEqual(document.stage.characters[0].baseOutfit, [3: "chain"])
        XCTAssertEqual(document.stage.characters[0].name, "Alice")
        XCTAssertTrue(document.stage.characters[0].events.isEmpty)
        XCTAssertTrue(document.stage.characters[0].subs.isEmpty)
        XCTAssertTrue(document.stage.characters[0].clips.isEmpty)
        XCTAssertEqual(document.stage.characters[0].voicePitch, 0)
        XCTAssertEqual(document.stage.characters[0].voiceSpeed, 1)
        XCTAssertNil(document.stage.characters[0].speechVoice.voiceIdentifier)
        XCTAssertTrue(document.stage.characters[0].muted)
        XCTAssertFalse(document.stage.characters[0].solo)
        XCTAssertEqual(document.stage.characters[0].presence.first?.visible, false)
        XCTAssertEqual(document.stage.characters[0].presence.last?.visible, true)

        let persisted = try ShowJSONCodec.decodeDocument(String(
            decoding: Data(contentsOf: packageURL.appendingPathComponent("show.json")),
            as: UTF8.self))
        XCTAssertEqual(persisted, document)
    }

    func testSubmitMapsActionsSpeechDeduplicatesAndAdvancesNoopCursor() async throws {
        let packageURL = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let definition = ReactionDefinition(
            id: "wave",
            name: "Wave",
            dur: 0.6,
            events: [.key(t: 0, code: .slash, down: true),
                     .key(t: 0.1, code: .slash, down: false)])
        let room = try LiveRoom(
            id: "room-b",
            title: "Actions",
            maxOccupancy: 2,
            draftDocument: draft(reactions: [definition]),
            packageURL: packageURL,
            startedAtMS: 0)
        let joined = try await room.join(
            identity: "alice",
            displayName: "Alice",
            character: Character(body: .orange),
            nowMS: 0)
        let context = try await room.nextDecision(
            participantID: joined.participantID,
            nowMS: 1_000)
        let revisionAfterJoin = await room.currentVisualRevision()
        XCTAssertEqual(context.participantID, joined.participantID)
        XCTAssertEqual(context.context.constraints.allowedReactionIDs, ["wave"])

        let decision = AgentDecisionEnvelope(
            requestID: context.requestID,
            intentID: "intent-1",
            say: "Hello from Alice",
            actions: [
                .move(direction: .left, durationMS: 120),
                .reaction(reactionID: "wave", durationMS: nil, intensity: nil),
            ])
        let accepted = try await room.submit(
            decision, participantID: joined.participantID, nowMS: 1_100)
        let revisionAfterAction = await room.currentVisualRevision()
        XCTAssertEqual(accepted.disposition, .accepted)
        XCTAssertGreaterThan(revisionAfterAction, revisionAfterJoin)

        let documentAfterFirst = await room.document()
        let character = documentAfterFirst.stage.characters[0]
        XCTAssertEqual(character.subs.map(\.text), ["Hello from Alice"])
        XCTAssertTrue(character.clips.isEmpty)
        XCTAssertTrue(character.muted)
        XCTAssertTrue(character.events.contains(.key(t: 1.1, code: .arrowLeft, down: true)))
        XCTAssertTrue(character.events.contains { event in
            guard case .key(let time, .arrowLeft, false) = event else { return false }
            return abs(time - 1.22) < 0.000_001
        })
        XCTAssertTrue(character.events.contains(.key(t: 1.1, code: .keyM, down: true)))
        XCTAssertEqual(character.reactions.count, 1)
        XCTAssertEqual(character.reactions[0].reactionID, "wave")
        XCTAssertEqual(character.reactions[0].dur, 0.6)

        let duplicate = try await room.submit(
            decision, participantID: joined.participantID, nowMS: 1_200)
        let revisionAfterDuplicate = await room.currentVisualRevision()
        XCTAssertEqual(duplicate.disposition, .duplicate)
        XCTAssertEqual(revisionAfterDuplicate, revisionAfterAction)
        let documentAfterDuplicate = await room.document()
        XCTAssertEqual(documentAfterDuplicate, documentAfterFirst)

        // Omitted request_after_ms uses the one-second room cadence.
        do {
            _ = try await room.nextDecision(
                participantID: joined.participantID,
                nowMS: 2_099)
            XCTFail("a new decision should not be issued before the default cadence")
        } catch {
            XCTAssertEqual(
                error as? LiveRoomError,
                .decisionNotDue(untilSceneTimeMS: 2_100))
        }
        let second = try await room.nextDecision(
            participantID: joined.participantID,
            nowMS: 2_100)
        do {
            _ = try await room.submit(
                AgentDecisionEnvelope(
                    requestID: second.requestID,
                    intentID: decision.intentID,
                    actions: [.jump]),
                participantID: joined.participantID,
                nowMS: 2_100)
            XCTFail("an intent id cannot be reused for a different request")
        } catch {
            XCTAssertEqual(error as? LiveRoomError, .intentIDReused)
        }
        let beforeNoop = second.basisSeq
        let revisionBeforeNoop = await room.currentVisualRevision()
        let documentBeforeNoop = await room.document()
        let showURL = packageURL.appendingPathComponent("show.json")
        let sentinelModificationDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes(
            [.modificationDate: sentinelModificationDate],
            ofItemAtPath: showURL.path)
        let noop = try await room.submit(
            AgentDecisionEnvelope(requestID: second.requestID, intentID: "intent-noop"),
            participantID: joined.participantID,
            nowMS: 2_100)
        XCTAssertGreaterThan(noop.seq, beforeNoop)
        let revisionAfterNoop = await room.currentVisualRevision()
        XCTAssertEqual(revisionAfterNoop, revisionBeforeNoop)
        let documentAfterNoop = await room.document()
        XCTAssertEqual(documentAfterNoop, documentBeforeNoop)
        let attributesAfterNoop = try FileManager.default.attributesOfItem(
            atPath: showURL.path)
        XCTAssertEqual(
            attributesAfterNoop[.modificationDate] as? Date,
            sentinelModificationDate,
            "an idle commit must not replace an unchanged show.json")
    }

    func testExpiredDecisionCannotMutateRecordingAndFreshContextIsAvailable() async throws {
        let packageURL = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let room = try LiveRoom(
            id: "room-expiry",
            title: "Expiry",
            maxOccupancy: 1,
            draftDocument: draft(),
            packageURL: packageURL,
            startedAtMS: 0)
        let participant = try await room.join(
            identity: "alice", displayName: "Alice",
            character: Character(body: .orange), nowMS: 0)
        let request = try await room.nextDecision(
            participantID: participant.participantID,
            nowMS: 100,
            timeoutMS: 100)
        let before = await room.document()

        do {
            _ = try await room.submit(
                AgentDecisionEnvelope(
                    requestID: request.requestID,
                    intentID: "too-late",
                    say: "This must not appear.",
                    actions: [.jump]),
                participantID: participant.participantID,
                nowMS: 201)
            XCTFail("an expired decision must be rejected")
        } catch {
            XCTAssertEqual(error as? LiveRoomError, .decisionExpired)
        }
        let after = await room.document()
        XCTAssertEqual(after, before)

        let replacement = try await room.nextDecision(
            participantID: participant.participantID,
            nowMS: 201,
            timeoutMS: 100)
        XCTAssertNotEqual(replacement.requestID, request.requestID)
        XCTAssertGreaterThan(replacement.basisSeq, request.basisSeq)
        XCTAssertEqual(replacement.context.recentEvents.last?.kind, "decision_timeout")
    }

    func testNewDecisionPreemptsOldFutureKeyUpAndLeaveReleasesCapacity() async throws {
        let packageURL = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let room = try LiveRoom(
            id: "room-c",
            title: "Preemption",
            maxOccupancy: 1,
            draftDocument: draft(),
            packageURL: packageURL,
            startedAtMS: 0)
        let alice = try await room.join(
            identity: "alice", displayName: "Alice",
            character: Character(body: .orange), nowMS: 0)

        let first = try await room.nextDecision(
            participantID: alice.participantID, nowMS: 100)
        _ = try await room.submit(
            AgentDecisionEnvelope(
                requestID: first.requestID,
                intentID: "walk-left",
                actions: [.move(direction: .left, durationMS: 3_000)],
                requestAfterMS: 250),
            participantID: alice.participantID,
            nowMS: 100)

        let second = try await room.nextDecision(
            participantID: alice.participantID, nowMS: 350)
        _ = try await room.submit(
            AgentDecisionEnvelope(
                requestID: second.requestID,
                intentID: "walk-right",
                actions: [.move(direction: .right, durationMS: 500)]),
            participantID: alice.participantID,
            nowMS: 350)

        var document = await room.document()
        let movement = document.stage.characters[0].events.filter { event in
            guard case .key(_, let code, _) = event else { return false }
            return code.group == .move
        }
        XCTAssertTrue(movement.contains(.key(t: 0.35, code: .arrowLeft, down: false)))
        XCTAssertTrue(movement.contains(.key(t: 0.35, code: .arrowRight, down: true)))
        XCTAssertFalse(movement.contains(.key(t: 3.1, code: .arrowLeft, down: false)))

        try await room.leave(participantID: alice.participantID, nowMS: 400)
        document = await room.document()
        XCTAssertFalse(document.stage.characters[0].events.contains { $0.t > 0.4 })

        // Concurrent occupancy is released, while recording tracks remain.
        let bob = try await room.join(
            identity: "bob", displayName: "Bob",
            character: Character(body: .alien), nowMS: 500)
        XCTAssertEqual(bob.participantID, "room-c-p2")
        let snapshot = try await room.snapshot(nowMS: 500)
        XCTAssertEqual(snapshot.occupancy, 1)
        XCTAssertEqual(snapshot.participants.count, 2)

        do {
            _ = try await room.join(
                identity: "alice", displayName: "Alice",
                character: Character(body: .orange), nowMS: 500)
            XCTFail("a reconnect must still respect concurrent occupancy")
        } catch {
            XCTAssertEqual(error as? LiveRoomError, .roomFull)
        }
        try await room.leave(participantID: bob.participantID, nowMS: 600)
        let charlie = try await room.join(
            identity: "charlie", displayName: "Charlie",
            character: Character(body: .pink), nowMS: 600)
        let churnedDocument = await room.document()
        let churnedX = churnedDocument.stage.characters[2].x
        XCTAssertTrue((0...1).contains(churnedX))
        try await room.leave(participantID: charlie.participantID, nowMS: 650)
        let reconnected = try await room.join(
            identity: "alice", displayName: "Alice",
            character: Character(body: .orange), nowMS: 650)
        XCTAssertTrue(reconnected.reconnected)
        XCTAssertEqual(reconnected.participantID, alice.participantID)
    }

    func testReactionAndDirectActionCannotOwnSameEventGroup() async throws {
        let packageURL = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let reaction = ReactionDefinition(
            id: "step",
            name: "Step",
            dur: 0.5,
            events: [.key(t: 0, code: .arrowRight, down: true)])
        let room = try LiveRoom(
            id: "room-d",
            title: "Conflicts",
            maxOccupancy: 1,
            draftDocument: draft(reactions: [reaction]),
            packageURL: packageURL)
        let joined = try await room.join(
            identity: "alice", displayName: "Alice",
            character: Character(body: .orange), nowMS: 0)
        let context = try await room.nextDecision(
            participantID: joined.participantID, nowMS: 100)

        do {
            _ = try await room.submit(
                AgentDecisionEnvelope(
                    requestID: context.requestID,
                    intentID: "conflict",
                    actions: [
                        .move(direction: .left, durationMS: 100),
                        .reaction(reactionID: "step", durationMS: nil, intensity: nil),
                    ]),
                participantID: joined.participantID,
                nowMS: 100)
            XCTFail("overlapping reaction/direct channels must be rejected atomically")
        } catch {
            XCTAssertEqual(error as? LiveRoomError, .reactionConflict("move"))
        }
        let documentAfterConflict = await room.document()
        XCTAssertTrue(documentAfterConflict.stage.characters[0].events.isEmpty)
    }

    func testInactivityLeaseRefreshesAndAdmissionExpiresCrashedBridgeAtomically() async throws {
        let packageURL = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let room = try LiveRoom(
            id: "room-lease",
            title: "Lease",
            maxOccupancy: 1,
            draftDocument: draft(),
            packageURL: packageURL,
            startedAtMS: 0)
        let alice = try await room.join(
            identity: "alice", displayName: "Alice",
            character: Character(body: .orange), nowMS: 0)
        let request = try await room.nextDecision(
            participantID: alice.participantID,
            nowMS: 40_000,
            timeoutMS: 10_000)
        _ = try await room.submit(
            AgentDecisionEnvelope(requestID: request.requestID, intentID: "heartbeat"),
            participantID: alice.participantID,
            nowMS: 45_001)

        // Exactly 45 seconds idle remains active; expiry uses a strict > lease.
        do {
            _ = try await room.join(
                identity: "bob", displayName: "Bob",
                character: Character(body: .alien), nowMS: 90_001)
            XCTFail("an unexpired participant must continue to hold capacity")
        } catch {
            XCTAssertEqual(error as? LiveRoomError, .roomFull)
        }

        // The next admission sweeps inside the actor, persists one teardown,
        // and can claim the newly released concurrent capacity.
        let bob = try await room.join(
            identity: "bob", displayName: "Bob",
            character: Character(body: .alien), nowMS: 90_002)
        XCTAssertEqual(bob.participantID, "room-lease-p2")
        let snapshot = try await room.snapshot(nowMS: 90_002)
        XCTAssertEqual(snapshot.occupancy, 1)
        XCTAssertEqual(
            snapshot.participants.first(where: { $0.participantID == alice.participantID })?.status,
            .disconnected)
        XCTAssertTrue(snapshot.recentEvents.contains {
            $0.kind == "session_expired" && $0.participantID == alice.participantID
        })

        let document = await room.document()
        XCTAssertEqual(document.stage.characters[0].presence.last?.visible, false)
        let disappearanceTime = try XCTUnwrap(
            document.stage.characters[0].presence.last?.t)
        XCTAssertEqual(disappearanceTime, 90.002, accuracy: 0.000_001)
        let additionallyExpired = try await room.expireInactive(nowMS: 90_002)
        XCTAssertEqual(additionallyExpired, [])
    }

    func testEndIsIdempotentAndFreezesAuthoritativeSnapshotAndTime() async throws {
        let packageURL = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        let room = try LiveRoom(
            id: "room-end",
            title: "Ending",
            maxOccupancy: 1,
            draftDocument: draft(),
            packageURL: packageURL,
            startedAtMS: 1_000)
        _ = try await room.join(
            identity: "alice", displayName: "Alice",
            character: Character(body: .pink), nowMS: 1_000)

        let first = try await room.end(nowMS: 2_250)
        XCTAssertEqual(first.roomID, "room-end")
        XCTAssertEqual(first.endedAtSceneTimeMS, 1_250)
        XCTAssertEqual(first.snapshot.sceneTimeMS, 1_250)
        XCTAssertEqual(first.snapshot.state, .ended)
        XCTAssertEqual(first.snapshot.occupancy, 0)
        XCTAssertEqual(first.snapshot.recentEvents.filter { $0.kind == "room_state" }.count, 1)

        let showURL = packageURL.appendingPathComponent("show.json")
        let sentinelModificationDate = Date(timeIntervalSince1970: 2_000)
        try FileManager.default.setAttributes(
            [.modificationDate: sentinelModificationDate],
            ofItemAtPath: showURL.path)
        let second = try await room.end(nowMS: 3_000)
        XCTAssertEqual(second, first)
        let reorderedEarlierEnd = try await room.end(nowMS: 1_500)
        XCTAssertEqual(reorderedEarlierEnd, first)
        let attributesAfterSecondEnd = try FileManager.default.attributesOfItem(
            atPath: showURL.path)
        XCTAssertEqual(
            attributesAfterSecondEnd[.modificationDate] as? Date,
            sentinelModificationDate,
            "an idempotent end must not rewrite the frozen package")

        let laterSnapshot = try await room.snapshot(nowMS: 4_000)
        XCTAssertEqual(laterSnapshot, first.snapshot)
        let reorderedEarlierSnapshot = try await room.snapshot(nowMS: 1_500)
        XCTAssertEqual(reorderedEarlierSnapshot, first.snapshot)
        let terminalFrame = try await room.frameSample(nowMS: 1_500)
        XCTAssertEqual(terminalFrame.sceneTimeMS, first.endedAtSceneTimeMS)
        let endedDocument = await room.document()
        XCTAssertEqual(terminalFrame.document, endedDocument)
        XCTAssertEqual(endedDocument.stage.characters[0].presence.last?.visible, false)
        XCTAssertEqual(endedDocument.stage.characters[0].presence.last?.t, 1.25)
    }

    private func draft(reactions: [ReactionDefinition] = []) -> ShowDocument {
        ShowDocument(stage: SceneState(
            reactionLibrary: reactions,
            backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")],
            rowOrder: ["scenes"]))
    }

    private func temporaryPackage() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("banny-live-tests-\(UUID().uuidString)", isDirectory: true)
        let packageURL = root.appendingPathComponent("recording.bs", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        return packageURL
    }
}
