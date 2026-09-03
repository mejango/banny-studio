import XCTest
@testable import BannyLive

final class LocalAgentClientTests: XCTestCase {
    override func tearDown() {
        LocalAgentMockURLProtocol.handler = nil
        LocalAgentMockURLProtocol.shouldStall = false
        LocalAgentMockURLProtocol.onStart = nil
        super.tearDown()
    }

    func testNumericLoopbackPolicyAcceptsIPv4RangeAndIPv6Loopback() throws {
        XCTAssertNoThrow(try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://127.99.2.3:9000"))))
        XCTAssertNoThrow(try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://[::1]:9000"))))
        XCTAssertNoThrow(try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://[0:0:0:0:0:0:0:1]:9000"))))
    }

    func testNumericLoopbackPolicyRejectsNamesAndLookalikes() throws {
        for rawURL in [
            "http://localhost:9000",
            "http://localhost.evil.test:9000",
            "http://126.255.255.255:9000",
            "http://128.0.0.1:9000",
            "http://0.0.0.0:9000",
            "file:///tmp/agent.sock",
        ] {
            XCTAssertThrowsError(try LocalAgentClient(endpoint: XCTUnwrap(URL(string: rawURL))), rawURL)
        }
    }

    func testRemoteEndpointRequiresExplicitOptIn() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://agent.example"))
        XCTAssertThrowsError(try LocalAgentClient(endpoint: endpoint))
        XCTAssertNoThrow(try LocalAgentClient(
            endpoint: endpoint,
            configuration: .init(allowRemoteEndpoint: true)))
        let plaintext = try XCTUnwrap(URL(string: "http://agent.example"))
        XCTAssertThrowsError(try LocalAgentClient(
            endpoint: plaintext,
            configuration: .init(allowRemoteEndpoint: true))) { error in
                XCTAssertEqual(
                    error as? LocalAgentClientError,
                    .insecureRemoteEndpointDenied(host: "agent.example"))
            }
    }

    func testLocalAgentBearerRejectsHeaderInjection() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:9000"))
        XCTAssertThrowsError(try LocalAgentClient(
            endpoint: endpoint,
            bearerToken: "safe\r\nX-Evil: yes")) { error in
                XCTAssertEqual(error as? LocalAgentClientError, .invalidBearerToken)
            }
    }

    func testDecisionPostsStrictContextAndReturnsCorrelatedIntent() async throws {
        let context = try makeContext()
        LocalAgentMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/decide")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                           "application/json; charset=utf-8")
            XCTAssertEqual(request.timeoutInterval, 2.5, accuracy: 0.001,
                           "the bridge must reserve submission slack inside timeout_ms")
            let body = try requestBodyData(request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["protocol"] as? String, "banny.agent.v1")
            XCTAssertEqual(object["request_id"] as? String, "request-1")
            XCTAssertNil(object["agent_endpoint"])
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("local-secret"))

            let responseBody = Data(#"""
            {
              "protocol":"banny.agent.v1",
              "request_id":"request-1",
              "intent_id":"intent-1",
              "say":"Hello from the local agent.",
              "actions":[{"op":"move","direction":"left","duration_ms":300}],
              "request_after_ms":500
            }
            """#.utf8)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (response, responseBody)
        }
        let client = try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            bearerToken: "local-secret",
            session: mockSession())

        let decision = try await client.decide(context)

        XCTAssertEqual(decision.requestID, "request-1")
        XCTAssertEqual(decision.intentID, "intent-1")
        XCTAssertEqual(decision.say, "Hello from the local agent.")
        XCTAssertEqual(decision.actions.count, 1)
    }

    func testDecisionRejectsUnknownFieldsBeforeIntentCanEscape() async throws {
        let context = try makeContext()
        LocalAgentMockURLProtocol.handler = { request in
            let body = Data(#"""
            {
              "protocol":"banny.agent.v1",
              "request_id":"request-1",
              "intent_id":"intent-1",
              "actions":[],
              "tool_call":{"url":"https://evil.example"}
            }
            """#.utf8)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (response, body)
        }
        let client = try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            session: mockSession())

        do {
            _ = try await client.decide(context)
            XCTFail("unknown fields must reject the complete decision")
        } catch let error as LocalAgentClientError {
            XCTAssertEqual(error, .malformedDecision)
        }
    }

    func testDecisionRejectsMismatchedRequestID() async throws {
        let context = try makeContext()
        LocalAgentMockURLProtocol.handler = { request in
            let body = Data(#"""
            {
              "protocol":"banny.agent.v1",
              "request_id":"another-request",
              "intent_id":"intent-1",
              "actions":[]
            }
            """#.utf8)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (response, body)
        }
        let client = try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            session: mockSession())

        do {
            _ = try await client.decide(context)
            XCTFail("uncorrelated intent must not escape")
        } catch let error as LocalAgentClientError {
            XCTAssertEqual(error, .requestIDMismatch(received: "another-request"))
        }
    }

    func testDecisionRejectsOversizedResponseBeforeDecode() async throws {
        let context = try makeContext()
        LocalAgentMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "129"]))
            return (response, Data(repeating: 32, count: 129))
        }
        let client = try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            configuration: .init(maximumResponseBytes: 128),
            session: mockSession())

        do {
            _ = try await client.decide(context)
            XCTFail("oversized response must not be decoded")
        } catch let error as LocalAgentClientError {
            XCTAssertEqual(error, .responseTooLarge(actual: 129, limit: 128))
        }
    }

    func testDecisionStreamingCapAppliesWithoutContentLength() async throws {
        let context = try makeContext()
        LocalAgentMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (response, Data(repeating: 32, count: 129))
        }
        let client = try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            configuration: .init(maximumResponseBytes: 128),
            session: mockSession())

        do {
            _ = try await client.decide(context)
            XCTFail("streaming response must stop beyond the cap")
        } catch let error as LocalAgentClientError {
            XCTAssertEqual(error, .responseTooLarge(actual: 129, limit: 128))
        }
    }

    func testContextRequestHasAHard64KiBLimit() async throws {
        let original = try makeContext()
        let context = AgentContextEnvelope(
            requestID: original.requestID,
            roomID: original.roomID,
            participantID: original.participantID,
            basisSeq: original.basisSeq,
            context: AgentContext(
                sceneTimeMS: original.context.sceneTimeMS,
                room: AgentRoomContext(
                    state: "live",
                    title: "Large room",
                    premise: String(repeating: "x", count: 70_000)),
                selfState: original.context.selfState,
                constraints: original.context.constraints))
        let client = try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            session: mockSession())

        do {
            _ = try await client.decide(context)
            XCTFail("oversized context must not be sent")
        } catch LocalAgentClientError.requestTooLarge(let actual, let limit) {
            XCTAssertGreaterThan(actual, limit)
            XCTAssertEqual(limit, 64 * 1_024)
        }
    }

    func testDecisionHasAnExplicitDeadlineEvenWhenURLProtocolStalls() async throws {
        let context = try makeContext()
        LocalAgentMockURLProtocol.shouldStall = true
        let client = try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            configuration: .init(maximumTimeoutMS: 100),
            session: mockSession())

        do {
            _ = try await client.decide(context)
            XCTFail("stalled local agent must time out")
        } catch let error as LocalAgentClientError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testOnlyOneLocalDecisionMayBeOutstanding() async throws {
        let context = try makeContext()
        let started = expectation(description: "first request started")
        LocalAgentMockURLProtocol.shouldStall = true
        LocalAgentMockURLProtocol.onStart = { started.fulfill() }
        let client = try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            configuration: .init(maximumTimeoutMS: 1_000),
            session: mockSession())
        let first = Task { try await client.decide(context) }
        await fulfillment(of: [started], timeout: 1)

        do {
            _ = try await client.decide(context)
            XCTFail("second decision must not start while one is pending")
        } catch let error as LocalAgentClientError {
            XCTAssertEqual(error, .decisionAlreadyInFlight)
        }
        first.cancel()
        _ = try? await first.value
    }

    func testDecisionRejectsConflictingActionGroupsAtomically() async throws {
        let context = try makeContext()
        LocalAgentMockURLProtocol.handler = { request in
            let body = Data(#"""
            {
              "protocol":"banny.agent.v1",
              "request_id":"request-1",
              "intent_id":"intent-1",
              "actions":[
                {"op":"move","direction":"left","duration_ms":300},
                {"op":"move","direction":"right","duration_ms":300}
              ]
            }
            """#.utf8)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (response, body)
        }
        let client = try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            session: mockSession())

        do {
            _ = try await client.decide(context)
            XCTFail("a conflict must reject the complete decision")
        } catch let error as LocalAgentClientError {
            XCTAssertEqual(error, .invalidDecision("multiple actions control \"move\""))
        }
    }

    func testLocalAgentRedirectCannotEscapeLoopback() async throws {
        let context = try makeContext()
        let count = LockedCount()
        LocalAgentMockURLProtocol.handler = { request in
            count.increment()
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://evil.example/decide"]))
            return (response, Data())
        }
        let client = try LocalAgentClient(
            endpoint: XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            bearerToken: "local-secret",
            session: mockSession())

        do {
            _ = try await client.decide(context)
            XCTFail("redirect must not be accepted")
        } catch let error as LocalAgentClientError {
            XCTAssertEqual(error, .httpStatus(302))
        }
        XCTAssertEqual(count.snapshot(), 1, "redirect target must never be requested")
    }

    func testRoomTransportUsesFrozenPathsBearerAndCursor() async throws {
        LocalAgentMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/rooms/room-1/decisions/next")
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems,
                [URLQueryItem(name: "after", value: "42")])
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer participant-secret")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil))
            return (response, Data())
        }
        let transport = try URLSessionRoomTransport(
            roomURL: XCTUnwrap(URL(string: "https://rooms.example/v1/rooms/room-1")),
            bearerToken: "participant-secret",
            session: mockSession())

        let item = try await transport.poll(after: 42)

        XCTAssertNil(item)
    }

    func testRoomTransportRequiresHTTPSOffLoopbackByDefault() throws {
        let remoteHTTP = try XCTUnwrap(URL(string: "http://room.example/v1/rooms/room-a"))
        XCTAssertThrowsError(try URLSessionRoomTransport(
            roomURL: remoteHTTP,
            bearerToken: "session-token")) { error in
                XCTAssertEqual(
                    error as? URLSessionRoomTransportError,
                    .insecureRemoteRoomURL)
            }
        XCTAssertNoThrow(try URLSessionRoomTransport(
            roomURL: remoteHTTP,
            bearerToken: "session-token",
            configuration: .init(allowInsecureRemoteHTTP: true)))
        XCTAssertNoThrow(try URLSessionRoomTransport(
            roomURL: XCTUnwrap(URL(string: "https://room.example/v1/rooms/room-a")),
            bearerToken: "session-token"))
    }

    func testRoomTransportDecodesContextAndUsesBasisSequenceAsCursor() async throws {
        let context = try makeContext()
        LocalAgentMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (response, try AgentProtocolCodec.encode(context))
        }
        let transport = try URLSessionRoomTransport(
            roomURL: XCTUnwrap(URL(string: "https://rooms.example/v1/rooms/room-1")),
            bearerToken: "participant-secret",
            session: mockSession())

        let polled = try await transport.poll(after: nil)
        let item = try XCTUnwrap(polled)

        XCTAssertEqual(item.cursor, 42)
        XCTAssertEqual(item.context, context)
    }

    func testRoomTransportSubmitsDecisionToEscapedRequestPath() async throws {
        let decision = AgentDecisionEnvelope(
            requestID: "request/with/slash",
            intentID: "intent-1",
            actions: [.jump])
        LocalAgentMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(try XCTUnwrap(request.url?.absoluteString)
                .contains("/decisions/request%2Fwith%2Fslash"))
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer participant-secret")
            let decoded = try JSONDecoder().decode(
                AgentDecisionEnvelope.self,
                from: requestBodyData(request))
            XCTAssertEqual(decoded, decision)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 202,
                httpVersion: nil,
                headerFields: nil))
            return (response, Data())
        }
        let transport = try URLSessionRoomTransport(
            roomURL: XCTUnwrap(URL(string: "https://rooms.example/v1/rooms/room-1")),
            bearerToken: "participant-secret",
            session: mockSession())

        try await transport.submit(decision)
    }

    func testRoomTransportLeaveIsBoundedAndDoesNotFollowRedirects() async throws {
        let count = LockedCount()
        LocalAgentMockURLProtocol.handler = { request in
            count.increment()
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://evil.example/stolen"]))
            return (response, Data())
        }
        let transport = try URLSessionRoomTransport(
            roomURL: XCTUnwrap(URL(string: "https://rooms.example/v1/rooms/room-1")),
            bearerToken: "participant-secret",
            session: mockSession())

        do {
            try await transport.leave()
            XCTFail("redirect must not be accepted")
        } catch let error as URLSessionRoomTransportError {
            XCTAssertEqual(error, .httpStatus(302))
        }
        XCTAssertEqual(count.snapshot(), 1, "redirect target must never be requested")
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalAgentMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeContext() throws -> AgentContextEnvelope {
        let data = Data(#"""
        {
          "protocol":"banny.agent.v1",
          "request_id":"request-1",
          "room_id":"room-1",
          "participant_id":"participant-1",
          "basis_seq":42,
          "timeout_ms":3000,
          "context":{
            "scene_time_ms":1200,
            "room":{"state":"live","title":"Sunset Bar","premise":"Talk at closing time."},
            "self_state":{
              "participant_id":"participant-1",
              "display_name":"Banny",
              "status":"active",
              "pose":{"x":0.3,"depth":0,"face":"right","spin":0,"zoom":1},
              "speaking":false
            },
            "cast":[],
            "recent_events":[],
            "constraints":{
              "allowed_actions":["move","depth","tilt","expression","jump","flip","rotate","zoom","reset","reaction"],
              "allowed_reaction_ids":["laugh"],
              "max_actions":4,
              "max_speech_chars":280,
              "max_action_ms":3000
            }
          }
        }
        """#.utf8)
        return try JSONDecoder().decode(AgentContextEnvelope.self, from: data)
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else {
        throw URLError(.cannotDecodeContentData)
    }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

private final class LocalAgentMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var shouldStall = false
    nonisolated(unsafe) static var onStart: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.onStart?()
        if Self.shouldStall { return }
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
