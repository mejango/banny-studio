import XCTest
@testable import BannyLive

final class RoomTransportTests: XCTestCase {
    func testStepPollsDecidesAndSubmitsThroughInjectedSeams() async throws {
        let context = bridgeTestContext()
        let transport = StubRoomTransport(
            item: RoomPolledContext(cursor: 7, context: context))
        let decision = AgentDecisionEnvelope(
            requestID: context.requestID,
            intentID: "intent-1",
            actions: [.jump])
        let loop = RoomPollingLoop(
            transport: transport,
            agent: StubDecisionProvider(result: .success(decision)))

        let result = try await loop.step(after: 6)

        XCTAssertEqual(
            result,
            .submitted(after: 7, requestID: context.requestID, intentID: "intent-1"))
        let submitted = await transport.submittedDecisions()
        XCTAssertEqual(submitted, [decision])
        let cursors = await transport.polledCursors()
        XCTAssertEqual(cursors, [6])
    }

    func testLocalAgentFailureSubmitsCorrelatedNoOpThenSkipsCursor() async throws {
        let context = bridgeTestContext()
        let transport = StubRoomTransport(
            item: RoomPolledContext(cursor: 7, context: context))
        let loop = RoomPollingLoop(
            transport: transport,
            agent: StubDecisionProvider(result: .failure(.agentFailed)))

        let result = try await loop.step(after: 6)

        guard case .skipped(let cursor, let requestID, _) = result else {
            return XCTFail("expected skipped decision")
        }
        XCTAssertEqual(cursor, 7)
        XCTAssertEqual(requestID, context.requestID)
        let submitted = await transport.submittedDecisions()
        let noOp = try XCTUnwrap(submitted.only)
        XCTAssertEqual(noOp.protocolVersion, BannyAgentProtocol.version)
        XCTAssertEqual(noOp.requestID, context.requestID)
        XCTAssertTrue(noOp.intentID.hasPrefix("bridge-skip-"))
        XCTAssertLessThanOrEqual(noOp.intentID.unicodeScalars.count, 128)
        XCTAssertNil(noOp.say)
        XCTAssertTrue(noOp.actions.isEmpty)
        XCTAssertNil(noOp.requestAfterMS)
    }

    func testRoomSubmissionFailureIsSurfacedRatherThanReportedAsAgentSkip() async throws {
        let context = bridgeTestContext()
        let transport = StubRoomTransport(
            item: RoomPolledContext(cursor: 7, context: context),
            failSubmission: true)
        let decision = AgentDecisionEnvelope(
            requestID: context.requestID,
            intentID: "intent-1")
        let loop = RoomPollingLoop(
            transport: transport,
            agent: StubDecisionProvider(result: .success(decision)))

        do {
            _ = try await loop.step(after: 6)
            XCTFail("room transport failure must surface")
        } catch let error as StubBridgeError {
            XCTAssertEqual(error, .submissionFailed)
        }
    }

    func testNoOpSubmissionFailureAlsoSurfaces() async throws {
        let context = bridgeTestContext()
        let transport = StubRoomTransport(
            item: RoomPolledContext(cursor: 7, context: context),
            failSubmission: true)
        let loop = RoomPollingLoop(
            transport: transport,
            agent: StubDecisionProvider(result: .failure(.agentFailed)))

        do {
            _ = try await loop.step(after: 6)
            XCTFail("failure to consume the outstanding request must surface")
        } catch let error as StubBridgeError {
            XCTAssertEqual(error, .submissionFailed)
        }
    }

    func testStepRejectsNonAdvancingCursorBeforeCallingAgent() async throws {
        let context = bridgeTestContext()
        let transport = StubRoomTransport(
            item: RoomPolledContext(cursor: 7, context: context))
        let loop = RoomPollingLoop(
            transport: transport,
            agent: StubDecisionProvider(result: .failure(.agentFailed)))

        do {
            _ = try await loop.step(after: 7)
            XCTFail("replayed cursor must not be processed")
        } catch let error as RoomPollingLoopError {
            XCTAssertEqual(error, .nonAdvancingCursor(previous: 7, received: 7))
        }
    }
}

private enum StubBridgeError: Error, Equatable, Sendable {
    case agentFailed
    case submissionFailed
}

private struct StubDecisionProvider: AgentDecisionProvider {
    let result: Result<AgentDecisionEnvelope, StubBridgeError>

    func decide(_ context: AgentContextEnvelope) async throws -> AgentDecisionEnvelope {
        try result.get()
    }
}

private actor StubRoomTransport: RoomTransport {
    private let item: RoomPolledContext?
    private let failSubmission: Bool
    private var cursors: [Int64?] = []
    private var submissions: [AgentDecisionEnvelope] = []

    init(item: RoomPolledContext?, failSubmission: Bool = false) {
        self.item = item
        self.failSubmission = failSubmission
    }

    func poll(after cursor: Int64?) async throws -> RoomPolledContext? {
        cursors.append(cursor)
        return item
    }

    func submit(_ decision: AgentDecisionEnvelope) async throws {
        if failSubmission { throw StubBridgeError.submissionFailed }
        submissions.append(decision)
    }

    func leave() async throws {}

    func submittedDecisions() -> [AgentDecisionEnvelope] { submissions }
    func polledCursors() -> [Int64?] { cursors }
}

private func bridgeTestContext() -> AgentContextEnvelope {
    let selfState = AgentParticipantContext(
        participantID: "participant-1",
        displayName: "Banny",
        pose: AgentPose(x: 0.3, depth: 0, face: .right),
        status: "active")
    return AgentContextEnvelope(
        requestID: "request-1",
        roomID: "room-1",
        participantID: selfState.participantID,
        basisSeq: 7,
        context: AgentContext(
            sceneTimeMS: 1_200,
            room: AgentRoomContext(state: "live", title: "Sunset Bar"),
            selfState: selfState,
            constraints: AgentConstraints(allowedReactionIDs: ["laugh"])))
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
