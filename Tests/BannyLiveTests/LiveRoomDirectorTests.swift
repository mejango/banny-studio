import Foundation
import XCTest
import BannyCore
@testable import BannyLive

final class LiveRoomDirectorTests: XCTestCase {
    func testCharacterPromptIsNormalizedValidatedImmutableAndPrivate() async throws {
        let fixture = try makeRoom(id: "director-prompt", maximum: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let appearance = Character(
            body: .orange,
            size: 1,
            baseOutfit: [4: "cowboy-hat"])
        let receipt = try await fixture.room.join(
            identity: "one",
            displayName: "One",
            character: appearance,
            characterPrompt: "  A café philosopher\r\nwho guards THE-PRIVATE-PROMPT.  ",
            nowMS: 0)

        let privateCast = await fixture.room.autonomousParticipants()
        XCTAssertEqual(privateCast, [LiveAutonomousParticipant(
            participantID: receipt.participantID,
            seat: 0,
            characterPrompt: "A café philosopher\nwho guards THE-PRIVATE-PROMPT.")])

        let publicSnapshot = try await fixture.room.snapshot(nowMS: 1)
        let publicJSON = String(
            data: try LiveHTTPJSON.encoder.encode(publicSnapshot),
            encoding: .utf8)!
        let showJSON = try String(
            contentsOf: fixture.package.appendingPathComponent("show.json"),
            encoding: .utf8)
        XCTAssertFalse(publicJSON.contains("THE-PRIVATE-PROMPT"))
        XCTAssertFalse(showJSON.contains("THE-PRIVATE-PROMPT"))

        try await fixture.room.leave(participantID: receipt.participantID, nowMS: 2)
        do {
            _ = try await fixture.room.join(
                identity: "one",
                displayName: "One renamed",
                character: appearance,
                characterPrompt: "A café philosopher\nwho guards THE-PRIVATE-PROMPT.",
                nowMS: 3)
            XCTFail("A reconnect changed its immutable display name")
        } catch let error as LiveRoomError {
            XCTAssertEqual(error, .characterSeedImmutable)
        }

        let reconnect = try await fixture.room.join(
            identity: "one",
            displayName: "One",
            character: appearance,
            characterPrompt: "A café philosopher\nwho guards THE-PRIVATE-PROMPT.",
            nowMS: 4)
        XCTAssertTrue(reconnect.reconnected)

        try await fixture.room.leave(participantID: receipt.participantID, nowMS: 5)
        do {
            _ = try await fixture.room.join(
                identity: "one",
                displayName: "One",
                character: appearance,
                characterPrompt: "A different persona",
                nowMS: 6)
            XCTFail("A reconnect changed its immutable prompt")
        } catch let error as LiveRoomError {
            XCTAssertEqual(error, .characterSeedImmutable)
        }

        do {
            _ = try await fixture.room.join(
                identity: "one",
                displayName: "One",
                character: Character(body: .pink, baseOutfit: [4: "cowboy-hat"]),
                characterPrompt: "A café philosopher\nwho guards THE-PRIVATE-PROMPT.",
                nowMS: 7)
            XCTFail("A reconnect changed its immutable appearance")
        } catch let error as LiveRoomError {
            XCTAssertEqual(error, .characterSeedImmutable)
        }

        let invalidPrompts = [
            "",
            " \r\n ",
            "contains\ta tab",
            String(repeating: "x", count: 2_001),
        ]
        for (index, prompt) in invalidPrompts.enumerated() {
            do {
                _ = try await fixture.room.join(
                    identity: "invalid-\(index)",
                    displayName: "Invalid",
                    character: Character(body: .orange),
                    characterPrompt: prompt,
                    nowMS: Int64(8 + index))
                XCTFail("Invalid prompt \(index) was admitted")
            } catch let error as LiveRoomError {
                XCTAssertEqual(error, .invalidCharacterPrompt)
            }
        }
    }

    func testStepIsDeterministicRoundRobinAndRecordsSpeechAndActions() async throws {
        let fixture = try makeRoom(id: "director-round-robin", maximum: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await fixture.room.join(
            identity: "one", displayName: "One",
            character: Character(body: .orange), characterPrompt: "warm host", nowMS: 0)
        let second = try await fixture.room.join(
            identity: "two", displayName: "Two",
            character: Character(body: .pink), characterPrompt: "quiet guest", nowMS: 0)
        let clock = DirectorClock(1)
        let provider = DirectorProvider(behavior: .speakAndMove)
        let director = LiveRoomDirector(
            room: fixture.room,
            provider: provider,
            clock: clock)

        let firstStep = try await director.step()
        let secondStep = try await director.step()
        guard case .submitted(let firstID, _, let firstFallback) = firstStep,
              case .submitted(let secondID, _, let secondFallback) = secondStep else {
            return XCTFail("Expected two submitted turns")
        }
        XCTAssertEqual(firstID, first.participantID)
        XCTAssertEqual(secondID, second.participantID)
        XCTAssertFalse(firstFallback)
        XCTAssertFalse(secondFallback)

        let calls = await provider.recordedCalls()
        XCTAssertEqual(calls.map(\.prompt), ["warm host", "quiet guest"])
        XCTAssertEqual(calls.map(\.participantID), [first.participantID, second.participantID])

        let document = await fixture.room.document()
        XCTAssertEqual(document.stage.characters[0].subs.map(\.text), ["A deterministic line."])
        // The first caption is still active at the same clock time, so the
        // director keeps the second character's movement and suppresses speech.
        XCTAssertTrue(document.stage.characters[1].subs.isEmpty)
        XCTAssertEqual(document.stage.characters[0].events.count, 4)
        XCTAssertEqual(
            document.stage.characters[0].events.compactMap(Self.keyCode),
            [.keyM, .arrowRight, .arrowRight, .keyM])
        XCTAssertEqual(document.stage.characters[1].events.count, 2)
        XCTAssertEqual(
            document.stage.characters[1].events.compactMap(Self.keyCode),
            [.arrowRight, .arrowRight])
        let persisted = try ShowJSONCodec.decodeDocument(String(
            contentsOf: fixture.package.appendingPathComponent("show.json"),
            encoding: .utf8))
        XCTAssertEqual(persisted, document)
    }

    func testProviderFailureUsesBuiltInThenCorrelatedNoOpFallback() async throws {
        let fixture = try makeRoom(id: "director-fallback", maximum: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receipt = try await fixture.room.join(
            identity: "one", displayName: "One",
            character: Character(body: .alien), characterPrompt: "rowdy listener", nowMS: 0)
        let clock = DirectorClock(1)

        let builtInDirector = LiveRoomDirector(
            room: fixture.room,
            provider: DirectorProvider(behavior: .throwing),
            clock: clock)
        let builtInStep = try await builtInDirector.step()
        guard case .submitted(let participantID, _, let usedFallback) = builtInStep else {
            return XCTFail("Built-in fallback did not submit")
        }
        XCTAssertEqual(participantID, receipt.participantID)
        XCTAssertTrue(usedFallback)

        // Advance past the built-in cadence, then make both configured
        // providers fail. The director must still consume the outstanding
        // request with its correlated no-op instead of retrying stale context.
        clock.set(3_001)
        let noOpDirector = LiveRoomDirector(
            room: fixture.room,
            provider: DirectorProvider(behavior: .throwing),
            fallback: DirectorProvider(behavior: .throwing),
            clock: clock)
        let before = try await fixture.room.snapshot(nowMS: 3_001)
        let noOpStep = try await noOpDirector.step()
        guard case .submitted(let noOpID, let noOpSeq, let noOpFallback) = noOpStep else {
            return XCTFail("Correlated no-op fallback did not submit")
        }
        XCTAssertEqual(noOpID, receipt.participantID)
        XCTAssertTrue(noOpFallback)
        XCTAssertGreaterThan(noOpSeq, before.seq)
    }

    func testAnotherSpeakingCharacterSuppressesOnlySpeech() async throws {
        let fixture = try makeRoom(id: "director-speaker-lock", maximum: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await fixture.room.join(
            identity: "one", displayName: "One",
            character: Character(body: .orange), nowMS: 0)
        let second = try await fixture.room.join(
            identity: "two", displayName: "Two",
            character: Character(body: .pink), nowMS: 0)

        let context = try await fixture.room.nextDecision(
            participantID: first.participantID, nowMS: 1)
        _ = try await fixture.room.submit(
            AgentDecisionEnvelope(
                requestID: context.requestID,
                intentID: "first-speaks",
                say: "This caption is still visible.",
                requestAfterMS: 1_000),
            participantID: first.participantID,
            nowMS: 1)

        let director = LiveRoomDirector(
            room: fixture.room,
            provider: DirectorProvider(behavior: .speakAndMove),
            clock: DirectorClock(2))
        let result = try await director.step()
        guard case .submitted(let participantID, _, _) = result else {
            return XCTFail("Second participant did not act")
        }
        XCTAssertEqual(participantID, second.participantID)

        let document = await fixture.room.document()
        XCTAssertEqual(document.stage.characters[0].subs.count, 1)
        XCTAssertTrue(document.stage.characters[1].subs.isEmpty)
        XCTAssertEqual(document.stage.characters[1].events.count, 2)
    }

    func testStopCancelsAnInFlightTurnAndEndedRoomRejectsFurtherSteps() async throws {
        let fixture = try makeRoom(id: "director-stop", maximum: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.room.join(
            identity: "one", displayName: "One",
            character: Character(body: .orange), nowMS: 0)
        let provider = DirectorProvider(behavior: .blocking)
        let director = LiveRoomDirector(
            room: fixture.room,
            provider: provider,
            clock: DirectorClock(1))

        await director.start()
        await director.start() // idempotent
        for _ in 0..<1_000 where !(await provider.hasStarted()) {
            await Task.yield()
        }
        let providerStarted = await provider.hasStarted()
        XCTAssertTrue(providerStarted)
        await director.stop()

        let stoppedDocument = await fixture.room.document()
        XCTAssertTrue(stoppedDocument.stage.characters[0].subs.isEmpty)
        XCTAssertTrue(stoppedDocument.stage.characters[0].events.isEmpty)

        _ = try await fixture.room.end(nowMS: 2)
        let endedDocument = await fixture.room.document()
        do {
            _ = try await director.step()
            XCTFail("An ended room accepted another autonomous step")
        } catch let error as LiveRoomError {
            XCTAssertEqual(error, .roomEnded)
        }
        let afterEndedStep = await fixture.room.document()
        XCTAssertEqual(afterEndedStep, endedDocument)
    }
}

private extension LiveRoomDirectorTests {
    struct RoomFixture {
        let root: URL
        let package: URL
        let room: LiveRoom
    }

    func makeRoom(id: String, maximum: Int) throws -> RoomFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "banny-director-tests-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("recording.bs", isDirectory: true)
        let room = try LiveRoom(
            id: id,
            title: "Director test",
            maxOccupancy: maximum,
            draftDocument: ShowDocument(stage: SceneState(
                characters: [],
                reactionLibrary: SunsetBarPerformancePreset.reactionLibrary)),
            packageURL: package)
        return RoomFixture(root: root, package: package, room: room)
    }

    static func keyCode(_ event: PerfEvent) -> EventCode? {
        guard case .key(_, let code, _) = event else { return nil }
        return code
    }
}

private final class DirectorClock: LiveRoomDirectorClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ value: Int64) { self.value = value }

    func nowMS() -> Int64 {
        lock.withLock { value }
    }

    func set(_ value: Int64) {
        lock.withLock { self.value = value }
    }
}

private actor DirectorProvider: LiveDirectorDecisionProvider {
    enum Behavior: Sendable {
        case speakAndMove
        case throwing
        case blocking
    }

    struct Call: Equatable, Sendable {
        let prompt: String
        let participantID: String
    }

    private let behavior: Behavior
    private var calls: [Call] = []
    private var started = false

    init(behavior: Behavior) { self.behavior = behavior }

    func decide(
        characterPrompt: String,
        context: AgentContextEnvelope
    ) async throws -> AgentDecisionEnvelope {
        started = true
        calls.append(Call(
            prompt: characterPrompt,
            participantID: context.participantID))
        switch behavior {
        case .speakAndMove:
            return AgentDecisionEnvelope(
                requestID: context.requestID,
                intentID: "scripted-\(context.requestID)",
                say: "A deterministic line.",
                actions: [.move(direction: .right, durationMS: 80)],
                requestAfterMS: 1_000)
        case .throwing:
            throw DirectorProviderError.deliberate
        case .blocking:
            try await Task.sleep(for: .seconds(60))
            throw DirectorProviderError.deliberate
        }
    }

    func recordedCalls() -> [Call] { calls }
    func hasStarted() -> Bool { started }
}

private enum DirectorProviderError: Error {
    case deliberate
}
