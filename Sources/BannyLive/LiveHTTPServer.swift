import Dispatch
import Foundation
@preconcurrency import Network

public enum LiveHTTPServerError: Error, Equatable, Sendable {
    case alreadyRunning
    case invalidBindHost
    case hostHeaderPolicyRequired(String)
    case emptyAllowedHosts
    case invalidAllowedHost(String)
    case listenerFailed(String)
}

/// A dependency-free, HTTP/1.1 room server built on Network.framework.
///
/// The default endpoint is loopback-only. Binding another interface is an
/// explicit opt-in and should be paired with TLS at a reverse proxy before it
/// is exposed beyond a trusted machine.
public final class LiveHTTPServer: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public enum HostHeaderPolicy: Equatable, Sendable {
            /// Numeric loopback binds require that same literal host. This
            /// policy is rejected for every non-loopback bind so public/LAN
            /// listeners cannot accidentally accept arbitrary authorities.
            case automatic
            /// Accept only these host names or IP literals. Ports in request
            /// Host headers are ignored. Values are exact hosts, not wildcard
            /// patterns, URL strings, or host-and-port authorities.
            case allowed(Set<String>)
            /// Trust an upstream proxy to validate Host. This is unsafe for a
            /// directly browser-accessible loopback listener.
            case disabled
        }

        public var bindHost: String
        public var port: UInt16
        public var requestTimeoutSeconds: UInt32
        public var maximumHeaderBytes: Int
        public var maximumBodyBytes: Int
        public var maximumConnections: Int
        public var hostHeaderPolicy: HostHeaderPolicy

        public init(
            bindHost: String = "127.0.0.1",
            port: UInt16 = 8_080,
            requestTimeoutSeconds: UInt32 = 30,
            maximumHeaderBytes: Int = LiveHTTPRequestParser.defaultMaximumHeaderBytes,
            maximumBodyBytes: Int = LiveHTTPRequestParser.defaultMaximumBodyBytes,
            maximumConnections: Int = 128,
            hostHeaderPolicy: HostHeaderPolicy = .automatic
        ) {
            precondition(requestTimeoutSeconds > 0)
            precondition(maximumHeaderBytes > 0)
            precondition(maximumBodyBytes > 0)
            precondition(maximumConnections > 0)
            self.bindHost = bindHost
            self.port = port
            self.requestTimeoutSeconds = requestTimeoutSeconds
            self.maximumHeaderBytes = maximumHeaderBytes
            self.maximumBodyBytes = maximumBodyBytes
            self.maximumConnections = maximumConnections
            self.hostHeaderPolicy = hostHeaderPolicy
        }

        /// Validates the listener's network trust boundary without opening a
        /// socket. Non-loopback binds must make their Host-header policy
        /// explicit so wildcard/LAN listeners are never permissive by default.
        public func validate() throws {
            guard !bindHost.isEmpty,
                  !bindHost.contains("/"),
                  !bindHost.contains(where: { $0.isWhitespace }),
                  LiveHTTPHostPolicy.normalizedHost(bindHost) != nil
            else { throw LiveHTTPServerError.invalidBindHost }

            switch hostHeaderPolicy {
            case .automatic:
                guard LiveHTTPHostPolicy.isNumericLoopback(bindHost) else {
                    throw LiveHTTPServerError.hostHeaderPolicyRequired(bindHost)
                }
            case .allowed(let configured):
                guard !configured.isEmpty else {
                    throw LiveHTTPServerError.emptyAllowedHosts
                }
                for host in configured.sorted() {
                    guard LiveHTTPHostPolicy.normalizedHost(host) != nil else {
                        throw LiveHTTPServerError.invalidAllowedHost(host)
                    }
                }
            case .disabled:
                break
            }
        }
    }

    public typealias ReadyHandler = @Sendable (_ port: UInt16) -> Void
    public typealias FailureHandler = @Sendable (_ message: String) -> Void

    private let router: LiveHTTPRouter
    private let configuration: Configuration
    private let hostPolicy: LiveHTTPHostPolicy
    private let bodyBudget = LiveHTTPBodyBudget.shared
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var reportedPort: UInt16?
    private var sessions: [UUID: LiveHTTPConnectionSession] = [:]
    private var readyHandler: ReadyHandler?
    private var failureHandler: FailureHandler?

    public var onReady: ReadyHandler? {
        get { stateLock.withLock { readyHandler } }
        set { stateLock.withLock { readyHandler = newValue } }
    }

    public var onFailure: FailureHandler? {
        get { stateLock.withLock { failureHandler } }
        set { stateLock.withLock { failureHandler = newValue } }
    }

    public init(
        service: any LiveHTTPService,
        configuration: Configuration = Configuration(),
        staticAssets: (any LiveHTTPStaticAssetProviding)? = LiveHTTPBundledWebAssets(),
        frameRenderer: LiveHTTPRouter.FrameRenderer? = nil,
        limits: LiveHTTPRouter.Limits = LiveHTTPRouter.Limits(),
        queue: DispatchQueue? = nil
    ) {
        self.router = LiveHTTPRouter(
            service: service,
            staticAssets: staticAssets,
            frameRenderer: frameRenderer,
            limits: limits)
        self.configuration = configuration
        self.hostPolicy = LiveHTTPHostPolicy(
            bindHost: configuration.bindHost,
            policy: configuration.hostHeaderPolicy)
        if let target = queue {
            // Session state is deliberately lock-free and confined to this
            // private serial queue even if a caller supplies a concurrent one.
            self.queue = DispatchQueue(
                label: "studio.banny.live.http.serial",
                target: target)
        } else {
            self.queue = DispatchQueue(
                label: "studio.banny.live.http",
                qos: .userInitiated)
        }
    }

    deinit {
        stop()
    }

    /// Starts listening and returns immediately. `onReady` reports the actual
    /// port, including the system-assigned port when configuration.port is 0.
    public func start() throws {
        try configuration.validate()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.transportProtocol
            as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = Int(configuration.requestTimeoutSeconds)
        }

        let endpointPort = NWEndpoint.Port(rawValue: configuration.port) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(configuration.bindHost),
            port: endpointPort)

        stateLock.lock()
        guard listener == nil else {
            stateLock.unlock()
            throw LiveHTTPServerError.alreadyRunning
        }
        let created: NWListener
        do {
            created = try NWListener(using: parameters)
        } catch {
            stateLock.unlock()
            throw LiveHTTPServerError.listenerFailed(error.localizedDescription)
        }
        created.newConnectionHandler = { [weak self, weak created] connection in
            self?.accept(connection, from: created)
        }
        created.stateUpdateHandler = { [weak self, weak created] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = created?.port?.rawValue ?? self.configuration.port
                let handler = self.stateLock.withLock { () -> ReadyHandler? in
                    guard let created, self.listener === created else { return nil }
                    self.reportedPort = port
                    return self.readyHandler
                }
                handler?(port)
            case .failed(let error):
                if let handler = self.clearListener(created) {
                    handler(error.localizedDescription)
                }
            case .cancelled:
                _ = self.clearListener(created)
            default:
                break
            }
        }
        listener = created
        reportedPort = nil
        stateLock.unlock()
        created.start(queue: queue)
    }

    public func stop() {
        let stopped = stateLock.withLock {
            () -> (NWListener?, [LiveHTTPConnectionSession]) in
            let current = listener
            listener = nil
            reportedPort = nil
            let active = Array(sessions.values)
            sessions.removeAll()
            return (current, active)
        }
        stopped.0?.stateUpdateHandler = nil
        stopped.0?.newConnectionHandler = nil
        stopped.0?.cancel()
        for session in stopped.1 {
            session.requestStop()
        }
    }

    public var localPort: UInt16? {
        stateLock.withLock { reportedPort }
    }

    public var localURL: URL? {
        guard let port = localPort else { return nil }
        let bracketedHost = configuration.bindHost.contains(":")
            ? "[\(configuration.bindHost)]" : configuration.bindHost
        return URL(string: "http://\(bracketedHost):\(port)/")
    }

    private func accept(_ connection: NWConnection, from source: NWListener?) {
        guard let source else {
            connection.cancel()
            return
        }
        let id = UUID()
        let session = LiveHTTPConnectionSession(
            connection: connection,
            router: router,
            queue: queue,
            timeoutSeconds: configuration.requestTimeoutSeconds,
            parser: LiveHTTPRequestParser(
                maximumHeaderBytes: configuration.maximumHeaderBytes,
                maximumBodyBytes: configuration.maximumBodyBytes,
                bodyLimit: { [router] method, target in
                    router.maximumRequestBodyBytes(method: method, target: target)
                },
                headerValidator: { [hostPolicy, bodyBudget] _, _, headers, contentLength in
                    guard hostPolicy.allows(headers["host"]) else {
                        throw LiveHTTPRequestParserError.invalidHost
                    }
                    guard bodyBudget.reserve(contentLength, for: id) else {
                        throw LiveHTTPRequestParserError.bodyCapacityExceeded(
                            limit: bodyBudget.limit)
                    }
                }),
            releaseBodyReservation: { [bodyBudget] in
                bodyBudget.release(id)
            },
            onFinish: { [weak self] in
                self?.removeSession(id)
            })
        let accepted = stateLock.withLock { () -> Bool in
            guard listener === source,
                  sessions.count < configuration.maximumConnections else { return false }
            sessions[id] = session
            return true
        }
        if accepted {
            session.start()
        } else {
            connection.cancel()
        }
    }

    private func removeSession(_ id: UUID) {
        _ = stateLock.withLock {
            sessions.removeValue(forKey: id)
        }
    }

    /// Clears only the currently installed listener and returns the failure
    /// callback captured under the same lock. A stale listener callback must
    /// never clear or report failure for a newer run.
    private func clearListener(_ expected: NWListener?) -> FailureHandler? {
        stateLock.withLock {
            guard let expected, listener === expected else { return nil }
            listener = nil
            reportedPort = nil
            return failureHandler
        }
    }
}

/// Resolves one request authority to a normalized host before it can reach the
/// application router. This blocks browser DNS rebinding against the default
/// numeric loopback listener without coupling Host semantics to in-memory
/// router tests.
struct LiveHTTPHostPolicy: Equatable, Sendable {
    private let allowedHosts: Set<String>?

    init(
        bindHost: String,
        policy: LiveHTTPServer.Configuration.HostHeaderPolicy
    ) {
        switch policy {
        case .automatic:
            if Self.isNumericLoopback(bindHost),
               let normalized = Self.normalizedHost(bindHost) {
                allowedHosts = [normalized]
            } else {
                // Configuration validation rejects this combination before a
                // socket opens. Deny here as defense in depth for direct policy
                // tests and any future call site that constructs it alone.
                allowedHosts = []
            }
        case .allowed(let configured):
            allowedHosts = Set(configured.compactMap(Self.normalizedHost))
        case .disabled:
            allowedHosts = nil
        }
    }

    func allows(_ authority: String?) -> Bool {
        guard let allowedHosts else { return true }
        guard let authority, let host = Self.host(fromAuthority: authority) else {
            return false
        }
        return allowedHosts.contains(host)
    }

    private static func host(fromAuthority authority: String) -> String? {
        guard !authority.isEmpty,
              !authority.unicodeScalars.contains(where: {
                  $0.value <= 32 || $0.value == 127
              })
        else { return nil }

        if authority.hasPrefix("[") {
            guard let closing = authority.firstIndex(of: "]") else { return nil }
            let hostStart = authority.index(after: authority.startIndex)
            let host = String(authority[hostStart..<closing])
            let suffix = authority[authority.index(after: closing)...]
            guard validPortSuffix(suffix), IPv6Address(host) != nil else { return nil }
            return normalizedHost(host)
        }

        let colons = authority.indices.filter { authority[$0] == ":" }
        guard colons.count <= 1 else { return nil }
        let host: String
        if let colon = colons.first {
            host = String(authority[..<colon])
            guard validPortSuffix(authority[colon...]) else { return nil }
        } else {
            host = authority
        }
        return normalizedHost(host)
    }

    private static func validPortSuffix<S: StringProtocol>(_ suffix: S) -> Bool {
        guard !suffix.isEmpty else { return true }
        guard suffix.first == ":" else { return false }
        let digits = suffix.dropFirst()
        guard !digits.isEmpty,
              digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(digits), port > 0
        else { return false }
        return true
    }

    static func normalizedHost(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if let address = IPv4Address(raw) {
            return String(describing: address).lowercased()
        }
        if let address = IPv6Address(raw) {
            return String(describing: address).lowercased()
        }
        var name = raw.lowercased()
        if name.last == "." { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253 else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first != "-",
                  label.last != "-"
            else { return false }
            return label.utf8.allSatisfy { byte in
                (48...57).contains(byte)
                    || (97...122).contains(byte)
                    || byte == 45
            }
        }) else { return nil }
        return name
    }

    static func isNumericLoopback(_ raw: String) -> Bool {
        if let address = IPv4Address(raw) {
            return address.rawValue.first == 127
        }
        if let address = IPv6Address(raw) {
            return Array(address.rawValue) == Array(repeating: 0, count: 15) + [1]
        }
        return false
    }
}

/// One declaration-based memory budget shared by every room listener in this
/// process. Reserving Content-Length at header completion prevents many slow
/// clients from each claiming the full 100 MiB parser allowance.
final class LiveHTTPBodyBudget: @unchecked Sendable {
    static let defaultProcessLimit = 128 * 1_024 * 1_024
    static let shared = LiveHTTPBodyBudget(limit: defaultProcessLimit)

    let limit: Int
    private let lock = NSLock()
    private var reservations: [UUID: Int] = [:]
    private var reservedBytes = 0

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func reserve(_ bytes: Int, for id: UUID) -> Bool {
        guard bytes >= 0 else { return false }
        if bytes == 0 { return true }
        return lock.withLock {
            guard reservations[id] == nil,
                  bytes <= limit - min(reservedBytes, limit) else { return false }
            reservations[id] = bytes
            reservedBytes += bytes
            return true
        }
    }

    func release(_ id: UUID) {
        lock.withLock {
            guard let bytes = reservations.removeValue(forKey: id) else { return }
            reservedBytes -= bytes
        }
    }

    var reservedByteCount: Int {
        lock.withLock { reservedBytes }
    }
}

private final class LiveHTTPConnectionSession: @unchecked Sendable {
    private let connection: NWConnection
    private let router: LiveHTTPRouter
    private let queue: DispatchQueue
    private let timeoutSeconds: UInt32
    private let releaseBodyReservation: @Sendable () -> Void
    private let onFinish: @Sendable () -> Void
    private var parser: LiveHTTPRequestParser
    private var timeoutGeneration: UInt64 = 0
    private var finished = false
    private var requestReceived = false
    private var keepAlive: LiveHTTPConnectionSession?
    private var responseTask: Task<Void, Never>?
    private var notifiedFinish = false
    private var reservationTransferredToTask = false

    init(
        connection: NWConnection,
        router: LiveHTTPRouter,
        queue: DispatchQueue,
        timeoutSeconds: UInt32,
        parser: LiveHTTPRequestParser,
        releaseBodyReservation: @escaping @Sendable () -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.router = router
        self.queue = queue
        self.timeoutSeconds = timeoutSeconds
        self.parser = parser
        self.releaseBodyReservation = releaseBodyReservation
        self.onFinish = onFinish
    }

    func start() {
        // NWConnection retains its callbacks but those callbacks use weak
        // captures. Keep the session alive explicitly until every exit path
        // reaches cancel/terminalState.
        keepAlive = self
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.terminalState()
            default:
                break
            }
        }
        connection.start(queue: queue)
        armAbsoluteRequestDeadline()
        armTimeout()
        receive()
    }

    func requestStop() {
        queue.async { [self] in
            cancel()
        }
    }

    private func receive() {
        guard !finished, !requestReceived else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.armTimeout()
                do {
                    switch try self.parser.append(data) {
                    case .incomplete:
                        break
                    case .complete(let request):
                        self.requestReceived = true
                        self.armTimeout()
                        self.parser.discardBufferedBodyAfterCompletion()
                        self.reservationTransferredToTask = true
                        self.responseTask = Task {
                            [router = self.router,
                             releaseBodyReservation = self.releaseBodyReservation,
                             weak self] in
                            defer { releaseBodyReservation() }
                            let response = await router.response(to: request)
                            self?.queue.async { [weak self] in
                                guard let self, !self.finished else { return }
                                self.finished = true
                                self.responseTask = nil
                                self.send(response)
                            }
                        }
                        return
                    }
                } catch let parserError as LiveHTTPRequestParserError {
                    self.finished = true
                    self.send(self.router.response(to: parserError))
                    return
                } catch {
                    self.finished = true
                    self.send(self.router.response(to: .malformedHeader))
                    return
                }
            }

            if error != nil {
                self.cancel()
            } else if isComplete {
                self.finished = true
                self.send(self.router.response(to: .malformedRequestLine))
            } else {
                self.receive()
            }
        }
    }

    private func armTimeout() {
        timeoutGeneration &+= 1
        let generation = timeoutGeneration
        queue.asyncAfter(deadline: .now() + .seconds(Int(timeoutSeconds))) { [weak self] in
            guard let self, !self.finished, self.timeoutGeneration == generation else { return }
            self.finished = true
            self.responseTask?.cancel()
            self.responseTask = nil
            self.send(self.router.errorResponse(
                status: 408,
                code: "request_timeout",
                message: "The HTTP request timed out."))
        }
    }

    private func armAbsoluteRequestDeadline() {
        queue.asyncAfter(deadline: .now() + .seconds(Int(timeoutSeconds))) { [weak self] in
            guard let self, !self.finished, !self.requestReceived else { return }
            self.finished = true
            self.send(self.router.errorResponse(
                status: 408,
                code: "request_timeout",
                message: "The HTTP request timed out."))
        }
    }

    private func send(_ response: LiveHTTPResponse) {
        let bytes = response.serialized()
        // A peer which stops reading must not retain a session forever after
        // the request/handler timeout has already been disarmed.
        timeoutGeneration &+= 1
        let generation = timeoutGeneration
        queue.asyncAfter(deadline: .now() + .seconds(Int(timeoutSeconds))) { [weak self] in
            guard let self, !self.notifiedFinish,
                  self.timeoutGeneration == generation else { return }
            self.cancel()
        }
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    private func cancel() {
        finished = true
        responseTask?.cancel()
        responseTask = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        keepAlive = nil
        notifyFinish()
    }

    private func terminalState() {
        finished = true
        responseTask?.cancel()
        responseTask = nil
        connection.stateUpdateHandler = nil
        keepAlive = nil
        notifyFinish()
    }

    private func notifyFinish() {
        guard !notifiedFinish else { return }
        notifiedFinish = true
        if !reservationTransferredToTask {
            releaseBodyReservation()
        }
        onFinish()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
