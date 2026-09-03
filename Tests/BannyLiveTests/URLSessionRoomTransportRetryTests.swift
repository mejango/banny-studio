import XCTest
@testable import BannyLive

final class URLSessionRoomTransportRetryTests: XCTestCase {
    override func tearDown() {
        RetryRoomURLProtocol.handler = nil
        super.tearDown()
    }

    func testPollRetriesTransientServiceFailureWithDeterministicBackoff() async throws {
        let context = try retryContextData()
        let script = RetryRoomScript([
            .response(status: 503),
            .response(status: 200, body: context),
        ])
        let sleeper = RecordingRoomRetryScheduler()
        let transport = try makeTransport(script: script, sleeper: sleeper)

        let item = try await transport.poll(after: 41)
        let delays = sleeper.recordedDelays()

        XCTAssertEqual(item?.cursor, 42)
        XCTAssertEqual(script.requestCount, 2)
        XCTAssertEqual(delays, [10])
    }

    func testDecisionSubmitRetriesConnectionLossAndServiceFailureWithSameBody() async throws {
        let script = RetryRoomScript([
            .failure(.networkConnectionLost),
            .response(status: 502),
            .response(status: 202),
        ])
        let sleeper = RecordingRoomRetryScheduler()
        let transport = try makeTransport(script: script, sleeper: sleeper)
        let decision = AgentDecisionEnvelope(
            requestID: "request-1",
            intentID: "intent-1",
            say: "Still here.",
            actions: [.jump])

        try await transport.submit(decision)

        let requests = script.recordedRequests
        let delays = sleeper.recordedDelays()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.method == "POST" })
        XCTAssertEqual(Set(requests.map(\.url)), [
            "https://rooms.example/v1/rooms/room-1/decisions/request-1",
        ])
        XCTAssertEqual(Set(requests.map(\.body)), [try AgentProtocolCodec.encode(decision)])
        XCTAssertTrue(requests.allSatisfy {
            $0.authorization == "Bearer participant-secret"
        })
        XCTAssertEqual(delays, [10, 20])
    }

    func testEverySupportedTransientConnectionErrorIsRetried() async throws {
        let retryableCodes: [URLError.Code] = [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable,
            .cannotLoadFromNetwork,
            .backgroundSessionWasDisconnected,
        ]
        for code in retryableCodes {
            let script = RetryRoomScript([
                .failure(code),
                .response(status: 204),
            ])
            let scheduler = RecordingRoomRetryScheduler()
            let transport = try makeTransport(script: script, sleeper: scheduler)

            let item = try await transport.poll(after: 9)
            XCTAssertNil(item, "\(code)")
            XCTAssertEqual(script.requestCount, 2, "\(code)")
            XCTAssertEqual(scheduler.recordedDelays(), [10], "\(code)")
        }
    }

    func testCancellationTLSAndAuthenticationNetworkErrorsAreTerminal() async throws {
        let terminalCodes: [URLError.Code] = [
            .cancelled,
            .secureConnectionFailed,
            .serverCertificateUntrusted,
            .userAuthenticationRequired,
            .badURL,
        ]
        for code in terminalCodes {
            let script = RetryRoomScript([
                .failure(code),
                .response(status: 204),
            ])
            let scheduler = RecordingRoomRetryScheduler()
            let transport = try makeTransport(script: script, sleeper: scheduler)

            do {
                _ = try await transport.poll(after: nil)
                XCTFail("\(code) must be terminal")
            } catch {
                // The URL error must escape without another room request.
            }
            XCTAssertEqual(script.requestCount, 1, "\(code)")
            XCTAssertEqual(scheduler.recordedDelays(), [], "\(code)")
        }
    }

    func testPollRetriesSingleTimeoutInsteadOfEndingParticipantBridge() async throws {
        let script = RetryRoomScript([
            .failure(.timedOut),
            .response(status: 204),
        ])
        let sleeper = RecordingRoomRetryScheduler()
        let transport = try makeTransport(script: script, sleeper: sleeper)

        let item = try await transport.poll(after: nil)
        let delays = sleeper.recordedDelays()
        XCTAssertNil(item)
        XCTAssertEqual(script.requestCount, 2)
        XCTAssertEqual(delays, [10])
    }

    func testRetryBudgetStopsAfterThreeAttemptsAndSurfacesLastStatus() async throws {
        let script = RetryRoomScript([
            .response(status: 504),
            .response(status: 504),
            .response(status: 504),
            .response(status: 200, body: try retryContextData()),
        ])
        let sleeper = RecordingRoomRetryScheduler()
        let transport = try makeTransport(script: script, sleeper: sleeper)

        do {
            _ = try await transport.poll(after: nil)
            XCTFail("the bounded retry budget must be terminal")
        } catch let error as URLSessionRoomTransportError {
            XCTAssertEqual(error, .httpStatus(504))
        }
        let delays = sleeper.recordedDelays()
        XCTAssertEqual(script.requestCount, 3)
        XCTAssertEqual(delays, [10, 20])
    }

    func testUnauthorizedResponseStaysTerminalForCLI() async throws {
        let script = RetryRoomScript([.response(status: 401)])
        let sleeper = RecordingRoomRetryScheduler()
        let transport = try makeTransport(script: script, sleeper: sleeper)

        do {
            _ = try await transport.poll(after: nil)
            XCTFail("revoked participant credentials must not be retried")
        } catch let error as URLSessionRoomTransportError {
            XCTAssertEqual(error, .httpStatus(401))
        }
        let delays = sleeper.recordedDelays()
        XCTAssertEqual(script.requestCount, 1)
        XCTAssertEqual(delays, [])
    }

    func testFourHundredAndRedirectResponsesAreNeverRetried() async throws {
        for status in [400, 404, 409, 422, 429, 302] {
            let script = RetryRoomScript([.response(
                status: status,
                headers: status == 302
                    ? ["Location": "https://evil.example/stolen"]
                    : [:])])
            let sleeper = RecordingRoomRetryScheduler()
            let transport = try makeTransport(script: script, sleeper: sleeper)

            do {
                try await transport.submit(AgentDecisionEnvelope(
                    requestID: "request-1",
                    intentID: "intent-1"))
                XCTFail("HTTP \(status) must be terminal")
            } catch let error as URLSessionRoomTransportError {
                XCTAssertEqual(error, .httpStatus(status))
            }
            let delays = sleeper.recordedDelays()
            XCTAssertEqual(script.requestCount, 1)
            XCTAssertEqual(delays, [])
        }
    }

    func testChangedFinalResponseURLIsNeverRetried() async throws {
        let script = RetryRoomScript([
            .response(
                status: 200,
                responseURL: try XCTUnwrap(URL(string: "https://evil.example/stolen"))),
            .response(status: 202),
        ])
        let scheduler = RecordingRoomRetryScheduler()
        let transport = try makeTransport(script: script, sleeper: scheduler)

        do {
            try await transport.submit(AgentDecisionEnvelope(
                requestID: "request-1",
                intentID: "intent-1"))
            XCTFail("a changed authenticated response URL must be terminal")
        } catch let error as URLSessionRoomTransportError {
            XCTAssertEqual(error, .redirected)
        }
        XCTAssertEqual(script.requestCount, 1)
        XCTAssertEqual(scheduler.recordedDelays(), [])
    }

    func testMalformedAndOversizedSuccessResponsesAreNeverRetried() async throws {
        do {
            let script = RetryRoomScript([.response(status: 200, body: Data("{}".utf8))])
            let sleeper = RecordingRoomRetryScheduler()
            let transport = try makeTransport(script: script, sleeper: sleeper)
            do {
                _ = try await transport.poll(after: nil)
                XCTFail("malformed context must be terminal")
            } catch let error as URLSessionRoomTransportError {
                XCTAssertEqual(error, .malformedContext)
            }
            let delays = sleeper.recordedDelays()
            XCTAssertEqual(script.requestCount, 1)
            XCTAssertEqual(delays, [])
        }

        do {
            let script = RetryRoomScript([
                .response(status: 200, body: Data(repeating: 7, count: 5)),
            ])
            let sleeper = RecordingRoomRetryScheduler()
            let transport = try makeTransport(
                script: script,
                configuration: retryConfiguration(maximumContextBytes: 4),
                sleeper: sleeper)
            do {
                _ = try await transport.poll(after: nil)
                XCTFail("oversized context must be terminal")
            } catch let error as URLSessionRoomTransportError {
                XCTAssertEqual(error, .responseTooLarge(actual: 5, limit: 4))
            }
            let delays = sleeper.recordedDelays()
            XCTAssertEqual(script.requestCount, 1)
            XCTAssertEqual(delays, [])
        }
    }

    func testCancellationDuringBackoffPreventsAnotherAttempt() async throws {
        let script = RetryRoomScript([
            .response(status: 503),
            .response(status: 204),
        ])
        let sleeper = RecordingRoomRetryScheduler(cancelOnSleep: true)
        let transport = try makeTransport(script: script, sleeper: sleeper)

        do {
            _ = try await transport.poll(after: nil)
            XCTFail("cancellation must escape the retry loop")
        } catch is CancellationError {
            // Expected.
        }
        let delays = sleeper.recordedDelays()
        XCTAssertEqual(script.requestCount, 1)
        XCTAssertEqual(delays, [10])
    }

    func testLeaveRemainsSingleAttemptBecauseItHasNoDeduplicationContract() async throws {
        let script = RetryRoomScript([
            .response(status: 503),
            .response(status: 204),
        ])
        let sleeper = RecordingRoomRetryScheduler()
        let transport = try makeTransport(script: script, sleeper: sleeper)

        do {
            try await transport.leave()
            XCTFail("leave failure must surface")
        } catch let error as URLSessionRoomTransportError {
            XCTAssertEqual(error, .httpStatus(503))
        }
        let delays = sleeper.recordedDelays()
        XCTAssertEqual(script.requestCount, 1)
        XCTAssertEqual(delays, [])
    }

    func testRetryAttemptsShareOneOperationDeadline() async throws {
        let script = RetryRoomScript([
            .response(status: 503),
            .response(status: 204),
        ])
        let scheduler = RecordingRoomRetryScheduler()
        let transport = try makeTransport(
            script: script,
            configuration: retryConfiguration(pollTimeout: 0.75),
            sleeper: scheduler)

        _ = try await transport.poll(after: nil)

        let timeouts = script.recordedRequests.map(\.timeout)
        XCTAssertEqual(timeouts.count, 2)
        XCTAssertEqual(timeouts[0], 0.24, accuracy: 0.001)
        XCTAssertEqual(timeouts[1], 0.36, accuracy: 0.001)
        XCTAssertEqual(scheduler.recordedDelays(), [10])
    }

    func testRetryIsSuppressedWhenBackoffWouldCrossOperationDeadline() async throws {
        let script = RetryRoomScript([
            .response(status: 503),
            .response(status: 204),
        ])
        let scheduler = RecordingRoomRetryScheduler()
        var configuration = retryConfiguration(pollTimeout: 0.05)
        configuration.pollRetryPolicy = .init(
            maximumAttempts: 2,
            initialBackoffMS: 100,
            maximumBackoffMS: 100)
        let transport = try makeTransport(
            script: script,
            configuration: configuration,
            sleeper: scheduler)

        do {
            _ = try await transport.poll(after: nil)
            XCTFail("the retry must not sleep beyond the operation deadline")
        } catch let error as URLSessionRoomTransportError {
            XCTAssertEqual(error, .httpStatus(503))
        }
        XCTAssertEqual(script.requestCount, 1)
        XCTAssertEqual(scheduler.recordedDelays(), [])
    }

    func testRoomLoopPassesOnlyContextDeadlineRemainderToSubmission() async throws {
        let context = retryContext(timeoutMS: 3_000)
        let transport = DeadlineRecordingRoomTransport(
            item: RoomPolledContext(cursor: 42, context: context))
        let clock = RecordingRoomRetryScheduler()
        let decision = AgentDecisionEnvelope(
            requestID: context.requestID,
            intentID: "intent-1")
        let loop = RoomPollingLoop(
            transport: transport,
            agent: TimedRetryDecisionProvider(
                clock: clock,
                elapsedMS: 2_500,
                result: .success(decision)),
            clock: clock)

        _ = try await loop.step(after: 41)

        let submissions = await transport.deadlineSubmissions()
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions[0].decision, decision)
        XCTAssertEqual(submissions[0].timeout, 0.5, accuracy: 0.001)
        let legacyCount = await transport.legacySubmissionCount()
        XCTAssertEqual(legacyCount, 0)
    }

    func testRoomLoopDoesNotSubmitAfterContextDeadline() async throws {
        let context = retryContext(timeoutMS: 3_000)
        let transport = DeadlineRecordingRoomTransport(
            item: RoomPolledContext(cursor: 42, context: context))
        let clock = RecordingRoomRetryScheduler()
        let decision = AgentDecisionEnvelope(
            requestID: context.requestID,
            intentID: "intent-1")
        let loop = RoomPollingLoop(
            transport: transport,
            agent: TimedRetryDecisionProvider(
                clock: clock,
                elapsedMS: 3_000,
                result: .success(decision)),
            clock: clock)

        do {
            _ = try await loop.step(after: 41)
            XCTFail("an expired context must not be submitted")
        } catch let error as RoomPollingLoopError {
            XCTAssertEqual(
                error,
                .decisionDeadlineExpired(requestID: context.requestID))
        }
        let submissionCount = await transport.totalSubmissionCount()
        XCTAssertEqual(submissionCount, 0)
    }

    func testCancellationAfterAgentResultPreventsDecisionSubmission() async throws {
        try await assertAgentCancellationDoesNotSubmit(result: .success(
            AgentDecisionEnvelope(requestID: "request-1", intentID: "intent-1")))
    }

    func testCancelledAgentErrorPreventsNoOpSubmission() async throws {
        try await assertAgentCancellationDoesNotSubmit(result: .failure(.failed))
    }

    func testInvalidRetryBudgetsAreRejected() throws {
        let roomURL = try XCTUnwrap(
            URL(string: "https://rooms.example/v1/rooms/room-1"))
        for policy in [
            URLSessionRoomTransportRetryPolicy(maximumAttempts: 0),
            URLSessionRoomTransportRetryPolicy(maximumAttempts: 6),
            URLSessionRoomTransportRetryPolicy(
                maximumAttempts: 2,
                initialBackoffMS: 20,
                maximumBackoffMS: 10),
            URLSessionRoomTransportRetryPolicy(
                maximumAttempts: 2,
                initialBackoffMS: 0,
                maximumBackoffMS:
                    URLSessionRoomTransportRetryPolicy.hardMaximumBackoffMS + 1),
        ] {
            XCTAssertThrowsError(try URLSessionRoomTransport(
                roomURL: roomURL,
                bearerToken: "participant-secret",
                configuration: .init(
                    pollRetryPolicy: policy,
                    submissionRetryPolicy: policy))) { error in
                    XCTAssertEqual(
                        error as? URLSessionRoomTransportError,
                        .invalidConfiguration)
                }
        }

        for configuration in [
            URLSessionRoomTransportConfiguration(pollTimeout: 45.001),
            URLSessionRoomTransportConfiguration(mutationTimeout: 45.001),
        ] {
            XCTAssertThrowsError(try URLSessionRoomTransport(
                roomURL: roomURL,
                bearerToken: "participant-secret",
                configuration: configuration)) { error in
                    XCTAssertEqual(
                        error as? URLSessionRoomTransportError,
                        .invalidConfiguration)
                }
        }
    }

    private func assertAgentCancellationDoesNotSubmit(
        result: Result<AgentDecisionEnvelope, RetryDecisionProviderError>
    ) async throws {
        let context = retryContext(timeoutMS: 3_000)
        let transport = DeadlineRecordingRoomTransport(
            item: RoomPolledContext(cursor: 42, context: context))
        let clock = RecordingRoomRetryScheduler()
        let loop = RoomPollingLoop(
            transport: transport,
            agent: TimedRetryDecisionProvider(
                clock: clock,
                elapsedMS: 10,
                cancelBeforeResult: true,
                result: result),
            clock: clock)
        let task = Task { try await loop.step(after: 41) }

        do {
            _ = try await task.value
            XCTFail("task cancellation must prevent a late room submission")
        } catch is CancellationError {
            // Expected.
        }
        let submissionCount = await transport.totalSubmissionCount()
        XCTAssertEqual(submissionCount, 0)
    }

    private func makeTransport(
        script: RetryRoomScript,
        configuration: URLSessionRoomTransportConfiguration? = nil,
        sleeper: RecordingRoomRetryScheduler
    ) throws -> URLSessionRoomTransport {
        RetryRoomURLProtocol.handler = { try script.handle($0) }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RetryRoomURLProtocol.self]
        return try URLSessionRoomTransport(
            roomURL: XCTUnwrap(
                URL(string: "https://rooms.example/v1/rooms/room-1")),
            bearerToken: "participant-secret",
            configuration: configuration ?? retryConfiguration(),
            session: URLSession(configuration: sessionConfiguration),
            retrySleeper: sleeper,
            retryClock: sleeper)
    }

    private func retryConfiguration(
        maximumContextBytes: Int = 64 * 1_024,
        pollTimeout: TimeInterval = 2
    ) -> URLSessionRoomTransportConfiguration {
        .init(
            maximumContextBytes: maximumContextBytes,
            pollTimeout: pollTimeout,
            mutationTimeout: 2,
            pollRetryPolicy: .init(
                maximumAttempts: 3,
                initialBackoffMS: 10,
                maximumBackoffMS: 20),
            submissionRetryPolicy: .init(
                maximumAttempts: 3,
                initialBackoffMS: 10,
                maximumBackoffMS: 20))
    }

    private func retryContextData() throws -> Data {
        try AgentProtocolCodec.encode(retryContext())
    }

    private func retryContext(timeoutMS: Int = 3_000) -> AgentContextEnvelope {
        let selfState = AgentParticipantContext(
            participantID: "participant-1",
            displayName: "Banny",
            pose: AgentPose(x: 0.3, depth: 0, face: .right),
            status: "active")
        return AgentContextEnvelope(
            requestID: "request-1",
            roomID: "room-1",
            participantID: selfState.participantID,
            basisSeq: 42,
            timeoutMS: timeoutMS,
            context: AgentContext(
                sceneTimeMS: 1_200,
                room: AgentRoomContext(state: "live", title: "Sunset Bar"),
                selfState: selfState))
    }
}

private final class RecordingRoomRetryScheduler:
    RoomPollingSleeper, RoomTransportClock, @unchecked Sendable
{
    private let lock = NSLock()
    private var delays: [UInt64] = []
    private var now: UInt64 = 0
    private let cancelOnSleep: Bool

    init(cancelOnSleep: Bool = false) {
        self.cancelOnSleep = cancelOnSleep
    }

    func sleep(milliseconds: UInt64) async throws {
        try Task.checkCancellation()
        lock.withLock {
            delays.append(milliseconds)
            if !cancelOnSleep {
                let (increment, incrementOverflow) = milliseconds
                    .multipliedReportingOverflow(by: 1_000_000)
                let (advanced, advanceOverflow) = now.addingReportingOverflow(increment)
                now = incrementOverflow || advanceOverflow ? UInt64.max : advanced
            }
        }
        if cancelOnSleep { throw CancellationError() }
    }

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func advance(milliseconds: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        now += milliseconds * 1_000_000
    }

    func recordedDelays() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }
}

private enum RetryDecisionProviderError: Error, Sendable {
    case failed
}

private struct TimedRetryDecisionProvider: AgentDecisionProvider {
    let clock: RecordingRoomRetryScheduler
    let elapsedMS: UInt64
    var cancelBeforeResult = false
    let result: Result<AgentDecisionEnvelope, RetryDecisionProviderError>

    func decide(_ context: AgentContextEnvelope) async throws -> AgentDecisionEnvelope {
        clock.advance(milliseconds: elapsedMS)
        if cancelBeforeResult {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        return try result.get()
    }
}

private actor DeadlineRecordingRoomTransport: DeadlineAwareRoomTransport {
    struct Submission: Sendable {
        let decision: AgentDecisionEnvelope
        let timeout: TimeInterval
    }

    private let item: RoomPolledContext?
    private var legacySubmissions: [AgentDecisionEnvelope] = []
    private var submissions: [Submission] = []

    init(item: RoomPolledContext?) {
        self.item = item
    }

    func poll(after cursor: Int64?) async throws -> RoomPolledContext? {
        item
    }

    func submit(_ decision: AgentDecisionEnvelope) async throws {
        legacySubmissions.append(decision)
    }

    func submit(
        _ decision: AgentDecisionEnvelope,
        timeout: TimeInterval
    ) async throws {
        submissions.append(Submission(decision: decision, timeout: timeout))
    }

    func leave() async throws {}

    func deadlineSubmissions() -> [Submission] { submissions }
    func legacySubmissionCount() -> Int { legacySubmissions.count }
    func totalSubmissionCount() -> Int { legacySubmissions.count + submissions.count }
}

private final class RetryRoomScript: @unchecked Sendable {
    enum Outcome: Sendable {
        case response(
            status: Int,
            body: Data = Data(),
            headers: [String: String] = [:],
            responseURL: URL? = nil)
        case failure(URLError.Code)
    }

    struct RecordedRequest: Sendable {
        let method: String
        let url: String
        let body: Data
        let timeout: TimeInterval
        let authorization: String?
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var requests: [RecordedRequest] = []

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var recordedRequests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let body = try retryRequestBody(request)
        let outcome: Outcome
        lock.lock()
        requests.append(RecordedRequest(
            method: request.httpMethod ?? "",
            url: request.url?.absoluteString ?? "",
            body: body,
            timeout: request.timeoutInterval,
            authorization: request.value(forHTTPHeaderField: "Authorization")))
        if outcomes.isEmpty {
            outcome = .failure(.badServerResponse)
        } else {
            outcome = outcomes.removeFirst()
        }
        lock.unlock()

        switch outcome {
        case .failure(let code):
            throw URLError(code)
        case .response(let status, let data, let headers, let responseURL):
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(responseURL ?? request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: headers))
            return (response, data)
        }
    }
}

private func retryRequestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else {
            throw stream.streamError ?? URLError(.cannotDecodeContentData)
        }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

private final class RetryRoomURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
