import Foundation
import XCTest
@preconcurrency import Network
@testable import BannyLive

final class LiveHTTPServerTests: XCTestCase {
    func testAutomaticHostPolicyBlocksLoopbackDNSRebindingAuthorities() {
        let policy = LiveHTTPHostPolicy(bindHost: "127.0.0.1", policy: .automatic)

        XCTAssertTrue(policy.allows("127.0.0.1"))
        XCTAssertTrue(policy.allows("127.0.0.1:8080"))
        XCTAssertTrue(policy.allows("127.0.0.1:65535"))
        XCTAssertFalse(policy.allows("localhost:8080"))
        XCTAssertFalse(policy.allows("rooms.attacker.example:8080"))
        XCTAssertFalse(policy.allows("127.0.0.1.attacker.example"))
        XCTAssertFalse(policy.allows("127.0.0.1@attacker.example"))
        XCTAssertFalse(policy.allows("127.0.0.1:0"))
    }

    func testConfiguredHostPolicySupportsReverseProxyOrExplicitDisable() {
        let allowed = LiveHTTPHostPolicy(
            bindHost: "127.0.0.1",
            policy: .allowed(["rooms.example.com", "::1"]))
        XCTAssertTrue(allowed.allows("ROOMS.EXAMPLE.COM:443"))
        XCTAssertTrue(allowed.allows("rooms.example.com.:443"))
        XCTAssertTrue(allowed.allows("[::1]:8443"))
        XCTAssertFalse(allowed.allows("127.0.0.1:8080"))
        XCTAssertFalse(allowed.allows("rooms.example.com.evil"))
        XCTAssertFalse(allowed.allows("bad..example"))

        let disabled = LiveHTTPHostPolicy(
            bindHost: "127.0.0.1", policy: .disabled)
        XCTAssertTrue(disabled.allows("proxy-owned-host.example"))

        let remoteAutomatic = LiveHTTPHostPolicy(
            bindHost: "0.0.0.0", policy: .automatic)
        XCTAssertFalse(remoteAutomatic.allows("proxy-owned-host.example"))
    }

    func testNonLoopbackConfigurationRequiresExplicitHostPolicy() throws {
        XCTAssertNoThrow(try LiveHTTPServer.Configuration().validate())

        for bind in ["0.0.0.0", "::", "192.0.2.20", "room-host.internal"] {
            XCTAssertThrowsError(try LiveHTTPServer.Configuration(
                bindHost: bind,
                hostHeaderPolicy: .automatic).validate()) { error in
                    XCTAssertEqual(
                        error as? LiveHTTPServerError,
                        .hostHeaderPolicyRequired(bind))
                }
        }

        XCTAssertNoThrow(try LiveHTTPServer.Configuration(
            bindHost: "0.0.0.0",
            hostHeaderPolicy: .allowed(["rooms.example.com"])).validate())
        XCTAssertNoThrow(try LiveHTTPServer.Configuration(
            bindHost: "::",
            hostHeaderPolicy: .allowed(["rooms.example.com", "2001:db8::1"])).validate())
        XCTAssertNoThrow(try LiveHTTPServer.Configuration(
            bindHost: "0.0.0.0",
            hostHeaderPolicy: .disabled).validate())
    }

    func testAllowedHostConfigurationRejectsEmptyOrAmbiguousAuthorities() {
        XCTAssertThrowsError(try LiveHTTPServer.Configuration(
            hostHeaderPolicy: .allowed([])).validate()) { error in
                XCTAssertEqual(error as? LiveHTTPServerError, .emptyAllowedHosts)
            }

        for host in [
            "https://rooms.example.com",
            "*.example.com",
            "rooms.example.com:443",
            "bad..example",
            "-bad.example",
            "bad-.example",
            "rooms.example/path",
        ] {
            XCTAssertThrowsError(try LiveHTTPServer.Configuration(
                hostHeaderPolicy: .allowed([host])).validate(), host) { error in
                    XCTAssertEqual(
                        error as? LiveHTTPServerError,
                        .invalidAllowedHost(host))
                }
        }
    }

    func testProcessBodyBudgetReservesDeclaredBytesAndReleasesCapacity() {
        let budget = LiveHTTPBodyBudget(limit: 100)
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertTrue(budget.reserve(60, for: first))
        XCTAssertFalse(budget.reserve(41, for: second))
        XCTAssertEqual(budget.reservedByteCount, 60)
        XCTAssertTrue(budget.reserve(40, for: second))
        XCTAssertEqual(budget.reservedByteCount, 100)

        budget.release(first)
        XCTAssertEqual(budget.reservedByteCount, 40)
        XCTAssertTrue(budget.reserve(60, for: third))
        XCTAssertEqual(budget.reservedByteCount, 100)

        budget.release(second)
        budget.release(third)
        XCTAssertEqual(budget.reservedByteCount, 0)
    }

    func testListenerBindsLoopbackAndServesStaticHTTP11Response() async throws {
        let ready = expectation(description: "listener ready")
        let startup = LockedServerStartup()
        let page = Data("<!doctype html><title>Live</title>".utf8)
        let server = LiveHTTPServer(
            service: EmptyLiveHTTPService(),
            configuration: .init(port: 0),
            staticAssets: LiveHTTPInMemoryStaticAssets(assets: [
                "index.html": LiveHTTPStaticAsset(
                    data: page,
                    contentType: "text/html; charset=utf-8"),
            ]))
        server.onReady = { value in
            if startup.resolve(.ready(value)) {
                ready.fulfill()
            }
        }
        server.onFailure = { message in
            if startup.resolve(.failed(message)) {
                ready.fulfill()
            }
        }
        defer { server.stop() }

        try server.start()
        await fulfillment(of: [ready], timeout: 3)
        let actualPort: UInt16
        switch try XCTUnwrap(startup.get()) {
        case .ready(let port):
            actualPort = port
        case .failed(let message):
            let normalized = message.lowercased()
            if normalized.contains("not permitted") || normalized.contains("permission denied") {
                throw XCTSkip("The test sandbox does not permit opening a loopback listener.")
            }
            XCTFail("The HTTP listener failed to start: \(message)")
            return
        }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(actualPort)/"))

        let (data, rawResponse) = try await URLSession.shared.data(from: url)
        let response = try XCTUnwrap(rawResponse as? HTTPURLResponse)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, page)
        XCTAssertEqual(response.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertEqual(server.localURL?.host, "127.0.0.1")

        var reboundRequest = URLRequest(url: url)
        reboundRequest.setValue("rooms.attacker.example", forHTTPHeaderField: "Host")
        let (reboundBody, rawReboundResponse) = try await URLSession.shared.data(
            for: reboundRequest)
        let reboundResponse = try XCTUnwrap(rawReboundResponse as? HTTPURLResponse)
        XCTAssertEqual(reboundResponse.statusCode, 400)
        XCTAssertTrue(String(decoding: reboundBody, as: UTF8.self).contains("invalid_host"))

        let headersOnlyAttack = Data(
            "POST /v1/rooms HTTP/1.1\r\nHost: rooms.attacker.example\r\nContent-Type: application/json\r\nContent-Length: 104857600\r\n\r\n".utf8)
        let earlyRejection = try await RawHTTPClient.send(
            headersOnlyAttack, port: actualPort)
        let earlyWire = String(decoding: earlyRejection, as: UTF8.self)
        XCTAssertTrue(earlyWire.hasPrefix("HTTP/1.1 400"))
        XCTAssertTrue(earlyWire.contains("invalid_host"),
            "An invalid authority must be rejected without waiting for its declared body.")

        let capacityRequest = Data(
            "POST /v1/rooms HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 1\r\n\r\n".utf8)
        let capacityResponse: Data
        do {
            let reservation = UUID()
            XCTAssertTrue(LiveHTTPBodyBudget.shared.reserve(
                LiveHTTPBodyBudget.shared.limit,
                for: reservation))
            defer { LiveHTTPBodyBudget.shared.release(reservation) }
            capacityResponse = try await RawHTTPClient.send(
                capacityRequest, port: actualPort)
        }
        let capacityWire = String(decoding: capacityResponse, as: UTF8.self)
        XCTAssertTrue(capacityWire.hasPrefix("HTTP/1.1 503"))
        XCTAssertTrue(capacityWire.contains("body_capacity_exceeded"),
            "Exhausted process reservations must reject at header completion.")

        server.stop()
        XCTAssertNil(server.localPort)

        let restarted = expectation(description: "listener restarted")
        let secondStartup = LockedServerStartup()
        server.onReady = { value in
            if secondStartup.resolve(.ready(value)) {
                restarted.fulfill()
            }
        }
        server.onFailure = { message in
            if secondStartup.resolve(.failed(message)) {
                restarted.fulfill()
            }
        }
        try server.start()
        await fulfillment(of: [restarted], timeout: 3)
        switch try XCTUnwrap(secondStartup.get()) {
        case .ready(let restartedPort):
            XCTAssertEqual(server.localPort, restartedPort)
        case .failed(let message):
            XCTFail("The restarted HTTP listener failed: \(message)")
        }
    }
}

private enum RawHTTPClientError: Error {
    case connection(String)
    case timeout
}

private final class RawHTTPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "studio.banny.live.http.tests.raw-client")
    private let request: Data
    private var response = Data()
    private var completion: (@Sendable (Result<Data, Error>) -> Void)?
    private var finished = false

    private init(request: Data, port: UInt16) {
        self.request = request
        connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)
    }

    static func send(_ request: Data, port: UInt16) async throws -> Data {
        let client = RawHTTPClient(request: request, port: port)
        return try await withCheckedThrowingContinuation { continuation in
            client.start { result in
                continuation.resume(with: result)
            }
        }
    }

    private func start(
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        self.completion = completion
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connection.send(
                    content: request,
                    completion: .contentProcessed { [self] error in
                        if let error {
                            finish(.failure(.connection(error.localizedDescription)))
                        } else {
                            receive()
                        }
                    })
            case .failed(let error):
                finish(.failure(.connection(error.localizedDescription)))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [self] in
            finish(.failure(.timeout))
        }
    }

    private func receive() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [self] data, _, complete, error in
            if let data { response.append(data) }
            if let error {
                finish(.failure(.connection(error.localizedDescription)))
            } else if complete {
                finish(.success(response))
            } else {
                receive()
            }
        }
    }

    private func finish(_ result: Result<Data, RawHTTPClientError>) {
        guard !finished else { return }
        finished = true
        let callback = completion
        completion = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        callback?(result.mapError { $0 as Error })
    }
}

private actor EmptyLiveHTTPService: LiveHTTPService {
    func perform(_ operation: LiveHTTPOperation) async throws -> LiveHTTPServiceResult {
        LiveHTTPServiceResult(
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: Data("{}".utf8))
    }
}

private enum ServerStartup {
    case ready(UInt16)
    case failed(String)
}

private final class LockedServerStartup: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ServerStartup?

    @discardableResult
    func resolve(_ result: ServerStartup) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return false }
        value = result
        return true
    }

    func get() -> ServerStartup? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
