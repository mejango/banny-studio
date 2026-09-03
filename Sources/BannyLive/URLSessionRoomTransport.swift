import Foundation

/// Small, deterministic retry budget for participant-to-room WAN requests.
///
/// The policy deliberately has no jitter: participant bridges are independent,
/// and deterministic delays make cancellation and deadline behavior testable.
/// `maximumAttempts` includes the initial request.
public struct URLSessionRoomTransportRetryPolicy: Equatable, Sendable {
    public static let hardMaximumAttempts = 5
    public static let hardMaximumBackoffMS: UInt64 = 5_000
    public static let polling = Self()
    public static let decisionSubmission = Self(
        maximumAttempts: 3,
        initialBackoffMS: 50,
        maximumBackoffMS: 200)

    public var maximumAttempts: Int
    public var initialBackoffMS: UInt64
    public var maximumBackoffMS: UInt64

    public init(
        maximumAttempts: Int = 3,
        initialBackoffMS: UInt64 = 150,
        maximumBackoffMS: UInt64 = 600
    ) {
        self.maximumAttempts = maximumAttempts
        self.initialBackoffMS = initialBackoffMS
        self.maximumBackoffMS = maximumBackoffMS
    }

    fileprivate var isValid: Bool {
        (1...Self.hardMaximumAttempts).contains(maximumAttempts)
            && initialBackoffMS <= maximumBackoffMS
            && maximumBackoffMS <= Self.hardMaximumBackoffMS
    }

    /// `failedAttempt` is one-based: after the first failure this returns the
    /// initial delay, then doubles until the configured cap.
    fileprivate func delay(afterFailedAttempt failedAttempt: Int) -> UInt64 {
        guard failedAttempt > 0 else { return 0 }
        var delay = initialBackoffMS
        for _ in 1..<failedAttempt {
            let (doubled, overflow) = delay.multipliedReportingOverflow(by: 2)
            delay = overflow ? maximumBackoffMS : min(doubled, maximumBackoffMS)
        }
        return delay
    }

    fileprivate func remainingBackoffMS(afterFailedAttempts failedAttempts: Int) -> UInt64 {
        guard failedAttempts < maximumAttempts - 1 else { return 0 }
        var total: UInt64 = 0
        for failure in (failedAttempts + 1)..<maximumAttempts {
            let delay = delay(afterFailedAttempt: failure)
            let (next, overflow) = total.addingReportingOverflow(delay)
            total = overflow ? UInt64.max : next
        }
        return total
    }
}

public struct URLSessionRoomTransportConfiguration: Equatable, Sendable {
    public static let hardMaximumContextBytes = 64 * 1_024
    public static let hardMaximumDecisionBytes = 16 * 1_024
    public static let hardMaximumResponseBytes = 16 * 1_024
    /// A participant is expired after 45 seconds without host contact. No one
    /// transport operation may be configured to outlive that server lease.
    public static let hardMaximumOperationTimeout: TimeInterval = 45

    public var maximumContextBytes: Int
    public var maximumDecisionBytes: Int
    public var maximumResponseBytes: Int
    public var pollTimeout: TimeInterval
    public var mutationTimeout: TimeInterval
    public var pollRetryPolicy: URLSessionRoomTransportRetryPolicy
    public var submissionRetryPolicy: URLSessionRoomTransportRetryPolicy
    public var allowInsecureRemoteHTTP: Bool

    public init(
        maximumContextBytes: Int = Self.hardMaximumContextBytes,
        maximumDecisionBytes: Int = Self.hardMaximumDecisionBytes,
        maximumResponseBytes: Int = 16 * 1_024,
        pollTimeout: TimeInterval = 35,
        mutationTimeout: TimeInterval = 10,
        pollRetryPolicy: URLSessionRoomTransportRetryPolicy = .polling,
        submissionRetryPolicy: URLSessionRoomTransportRetryPolicy = .decisionSubmission,
        allowInsecureRemoteHTTP: Bool = false
    ) {
        self.maximumContextBytes = maximumContextBytes
        self.maximumDecisionBytes = maximumDecisionBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.pollTimeout = pollTimeout
        self.mutationTimeout = mutationTimeout
        self.pollRetryPolicy = pollRetryPolicy
        self.submissionRetryPolicy = submissionRetryPolicy
        self.allowInsecureRemoteHTTP = allowInsecureRemoteHTTP
    }
}

public enum URLSessionRoomTransportError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidRoomURL
    case insecureRemoteRoomURL
    case invalidBearerToken
    case invalidCursor(Int64)
    case encodingFailed
    case requestTooLarge(actual: Int, limit: Int)
    case responseTooLarge(actual: Int64, limit: Int)
    case timedOut
    case invalidHTTPResponse
    case redirected
    case httpStatus(Int)
    case malformedContext
}

extension URLSessionRoomTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The room transport limits are invalid."
        case .invalidRoomURL:
            "The room URL must be an HTTP(S) URL without credentials, a query, or a fragment."
        case .insecureRemoteRoomURL:
            "A non-loopback room URL must use HTTPS unless insecure HTTP is explicitly enabled."
        case .invalidBearerToken:
            "The room session token is missing or malformed."
        case .invalidCursor:
            "The room decision cursor must be nonnegative."
        case .encodingFailed:
            "The room decision could not be encoded."
        case .requestTooLarge(let actual, let limit):
            "The room request is \(actual) bytes; the limit is \(limit)."
        case .responseTooLarge(let actual, let limit):
            "The room response is \(actual) bytes; the limit is \(limit)."
        case .timedOut:
            "The room request timed out."
        case .invalidHTTPResponse:
            "The room returned an invalid HTTP response."
        case .redirected:
            "The room attempted to redirect an authenticated request."
        case .httpStatus(let status):
            "The room returned HTTP \(status)."
        case .malformedContext:
            "The room returned malformed agent context JSON."
        }
    }
}

/// Authenticated participant transport for the frozen room polling REST API.
/// Redirects are declined so the bearer token is never replayed to another URL.
public final class URLSessionRoomTransport: DeadlineAwareRoomTransport, @unchecked Sendable {
    public let roomURL: URL
    public let configuration: URLSessionRoomTransportConfiguration

    private let bearerToken: String
    private let expectedRoomID: String
    private let session: URLSession
    private let retrySleeper: any RoomPollingSleeper
    private let retryClock: any RoomTransportClock

    public init(
        roomURL: URL,
        bearerToken: String,
        configuration: URLSessionRoomTransportConfiguration = .init(),
        session: URLSession = .shared,
        retrySleeper: any RoomPollingSleeper = TaskRoomPollingSleeper(),
        retryClock: any RoomTransportClock = SystemRoomTransportClock()
    ) throws {
        guard configuration.maximumContextBytes > 0,
              configuration.maximumContextBytes
                <= URLSessionRoomTransportConfiguration.hardMaximumContextBytes,
              configuration.maximumDecisionBytes > 0,
              configuration.maximumDecisionBytes
                <= URLSessionRoomTransportConfiguration.hardMaximumDecisionBytes,
              configuration.maximumResponseBytes >= 0,
              configuration.maximumResponseBytes
                <= URLSessionRoomTransportConfiguration.hardMaximumResponseBytes,
              configuration.pollTimeout > 0,
              configuration.pollTimeout
                <= URLSessionRoomTransportConfiguration.hardMaximumOperationTimeout,
              configuration.pollTimeout.isFinite,
              configuration.mutationTimeout > 0,
              configuration.mutationTimeout
                <= URLSessionRoomTransportConfiguration.hardMaximumOperationTimeout,
              configuration.mutationTimeout.isFinite,
              configuration.pollRetryPolicy.isValid,
              configuration.submissionRetryPolicy.isValid
        else { throw URLSessionRoomTransportError.invalidConfiguration }
        guard let components = URLComponents(url: roomURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              !components.path.isEmpty,
              components.path != "/"
        else { throw URLSessionRoomTransportError.invalidRoomURL }
        if scheme == "http", let host = components.host,
           !LocalAgentClient.isNumericLoopbackHost(host),
           !configuration.allowInsecureRemoteHTTP {
            throw URLSessionRoomTransportError.insecureRemoteRoomURL
        }
        let roomID = roomURL.lastPathComponent
        guard !roomID.isEmpty, roomID != ".", roomID != ".." else {
            throw URLSessionRoomTransportError.invalidRoomURL
        }
        guard !bearerToken.isEmpty,
              bearerToken.unicodeScalars.count <= 4_096,
              bearerToken.unicodeScalars.allSatisfy(Self.isBearerTokenScalar)
        else { throw URLSessionRoomTransportError.invalidBearerToken }

        self.roomURL = roomURL
        self.bearerToken = bearerToken
        self.expectedRoomID = roomID
        self.configuration = configuration
        self.session = session
        self.retrySleeper = retrySleeper
        self.retryClock = retryClock
    }

    public func poll(after cursor: Int64?) async throws -> RoomPolledContext? {
        if let cursor, cursor < 0 {
            throw URLSessionRoomTransportError.invalidCursor(cursor)
        }
        var components = URLComponents(
            url: try endpoint(pathSegments: ["decisions", "next"]),
            resolvingAgainstBaseURL: false)!
        if let cursor {
            components.queryItems = [URLQueryItem(name: "after", value: String(cursor))]
        }
        guard let url = components.url else {
            throw URLSessionRoomTransportError.invalidRoomURL
        }
        var request = authenticatedRequest(url: url, method: "GET", timeout: configuration.pollTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let payload = try await loadWithRetry(
            request,
            timeout: configuration.pollTimeout,
            maximumResponseBytes: configuration.maximumContextBytes,
            policy: configuration.pollRetryPolicy)
        let response = try checkedResponse(payload, expectedURL: url)
        if response.statusCode == 204 {
            guard payload.data.isEmpty else {
                throw URLSessionRoomTransportError.malformedContext
            }
            return nil
        }
        guard response.statusCode == 200 else {
            throw URLSessionRoomTransportError.httpStatus(response.statusCode)
        }
        let context: AgentContextEnvelope
        do {
            context = try BannyAgentWireJSON.decoder.decode(
                AgentContextEnvelope.self,
                from: payload.data)
        } catch {
            throw URLSessionRoomTransportError.malformedContext
        }
        guard context.protocolVersion == LocalAgentClient.protocolVersion,
              context.roomID == expectedRoomID,
              context.basisSeq >= 0
        else { throw URLSessionRoomTransportError.malformedContext }
        return RoomPolledContext(cursor: context.basisSeq, context: context)
    }

    public func submit(_ decision: AgentDecisionEnvelope) async throws {
        try await submit(decision, timeout: configuration.mutationTimeout)
    }

    public func submit(
        _ decision: AgentDecisionEnvelope,
        timeout: TimeInterval
    ) async throws {
        guard timeout > 0, timeout.isFinite else {
            throw URLSessionRoomTransportError.timedOut
        }
        let body: Data
        do {
            body = try AgentProtocolCodec.encode(decision)
        } catch {
            throw URLSessionRoomTransportError.encodingFailed
        }
        guard body.count <= configuration.maximumDecisionBytes else {
            throw URLSessionRoomTransportError.requestTooLarge(
                actual: body.count,
                limit: configuration.maximumDecisionBytes)
        }
        let operationTimeout = min(timeout, configuration.mutationTimeout)
        let url = try endpoint(pathSegments: ["decisions", decision.requestID])
        var request = authenticatedRequest(
            url: url,
            method: "POST",
            timeout: operationTimeout)
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        let payload = try await loadWithRetry(
            request,
            timeout: operationTimeout,
            maximumResponseBytes: configuration.maximumResponseBytes,
            policy: configuration.submissionRetryPolicy)
        let response = try checkedResponse(payload, expectedURL: url)
        guard (200..<300).contains(response.statusCode) else {
            throw URLSessionRoomTransportError.httpStatus(response.statusCode)
        }
    }

    public func leave() async throws {
        let url = try endpoint(pathSegments: ["leave"])
        var request = authenticatedRequest(
            url: url,
            method: "POST",
            timeout: configuration.mutationTimeout)
        request.httpBody = Data()
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let payload = try await load(
            request,
            timeout: configuration.mutationTimeout,
            maximumResponseBytes: configuration.maximumResponseBytes)
        let response = try checkedResponse(payload, expectedURL: url)
        guard (200..<300).contains(response.statusCode) else {
            throw URLSessionRoomTransportError.httpStatus(response.statusCode)
        }
    }

    private func authenticatedRequest(url: URL, method: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func endpoint(pathSegments: [String]) throws -> URL {
        guard var components = URLComponents(url: roomURL, resolvingAgainstBaseURL: false) else {
            throw URLSessionRoomTransportError.invalidRoomURL
        }
        var path = components.percentEncodedPath
        while path.last == "/" { path.removeLast() }
        for segment in pathSegments {
            guard !segment.isEmpty,
                  let encoded = segment.addingPercentEncoding(
                    withAllowedCharacters: Self.pathSegmentCharacters)
            else { throw URLSessionRoomTransportError.invalidRoomURL }
            path += "/\(encoded)"
        }
        components.percentEncodedPath = path
        guard let url = components.url else {
            throw URLSessionRoomTransportError.invalidRoomURL
        }
        return url
    }

    private func load(
        _ request: URLRequest,
        timeout: TimeInterval,
        maximumResponseBytes: Int
    ) async throws -> BannyLiveURLLoader.Payload {
        do {
            return try await BannyLiveURLLoader.data(
                for: request,
                session: session,
                timeout: timeout,
                maximumResponseBytes: maximumResponseBytes)
        } catch BannyLiveURLLoader.Error.timedOut {
            throw URLSessionRoomTransportError.timedOut
        } catch let BannyLiveURLLoader.Error.responseTooLarge(actual, limit) {
            throw URLSessionRoomTransportError.responseTooLarge(actual: actual, limit: limit)
        } catch let error as URLError where error.code == .timedOut {
            throw URLSessionRoomTransportError.timedOut
        }
    }

    /// Executes one safe GET poll or correlated decision submission with a
    /// bounded retry budget. Attempts and backoffs share one monotonic deadline;
    /// each attempt receives only its apportioned share of the remaining time.
    private func loadWithRetry(
        _ request: URLRequest,
        timeout: TimeInterval,
        maximumResponseBytes: Int,
        policy: URLSessionRoomTransportRetryPolicy
    ) async throws -> BannyLiveURLLoader.Payload {
        guard let expectedURL = request.url else {
            throw URLSessionRoomTransportError.invalidRoomURL
        }
        guard timeout > 0, timeout.isFinite else {
            throw URLSessionRoomTransportError.timedOut
        }
        let timeoutNanoseconds = UInt64(
            (timeout * 1_000_000_000).rounded(.down))
        let startedAt = retryClock.nowNanoseconds()
        let (proposedDeadline, overflow) = startedAt.addingReportingOverflow(
            timeoutNanoseconds)
        let deadline = overflow ? UInt64.max : proposedDeadline
        var failedAttempts = 0
        while true {
            try Task.checkCancellation()
            let now = retryClock.nowNanoseconds()
            guard now < deadline else {
                throw URLSessionRoomTransportError.timedOut
            }
            let attemptsRemaining = policy.maximumAttempts - failedAttempts
            let remainingNanoseconds = deadline - now
            let backoffMS = policy.remainingBackoffMS(
                afterFailedAttempts: failedAttempts)
            let (backoffNanoseconds, backoffOverflow) = backoffMS
                .multipliedReportingOverflow(by: 1_000_000)
            let reservedBackoffNanoseconds = backoffOverflow
                ? remainingNanoseconds
                : min(remainingNanoseconds, backoffNanoseconds)
            let attemptPool = max(
                UInt64(1),
                remainingNanoseconds - reservedBackoffNanoseconds)
            let apportionedAttempt = attemptPool / UInt64(attemptsRemaining)
            let attemptNanoseconds = min(
                remainingNanoseconds,
                max(UInt64(1_000_000), apportionedAttempt))
            let attemptTimeout = TimeInterval(attemptNanoseconds) / 1_000_000_000
            var attemptRequest = request
            attemptRequest.timeoutInterval = attemptTimeout
            do {
                let payload = try await load(
                    attemptRequest,
                    timeout: attemptTimeout,
                    maximumResponseBytes: maximumResponseBytes)
                guard retryClock.nowNanoseconds() < deadline else {
                    throw URLSessionRoomTransportError.timedOut
                }
                let response = try checkedResponse(payload, expectedURL: expectedURL)
                if Self.retryableHTTPStatuses.contains(response.statusCode) {
                    throw URLSessionRoomTransportError.httpStatus(response.statusCode)
                }
                return payload
            } catch {
                try Task.checkCancellation()
                failedAttempts += 1
                guard failedAttempts < policy.maximumAttempts,
                      Self.isRetryable(error)
                else { throw error }

                let delay = policy.delay(
                    afterFailedAttempt: failedAttempts)
                if delay > 0 {
                    let now = retryClock.nowNanoseconds()
                    let (delayNanoseconds, overflow) = delay.multipliedReportingOverflow(
                        by: 1_000_000)
                    guard !overflow,
                          now < deadline,
                          delayNanoseconds < deadline - now
                    else { throw error }
                    try await retrySleeper.sleep(milliseconds: delay)
                }
                try Task.checkCancellation()
            }
        }
    }

    private func checkedResponse(
        _ payload: BannyLiveURLLoader.Payload,
        expectedURL: URL
    ) throws -> HTTPURLResponse {
        guard let response = payload.response as? HTTPURLResponse else {
            throw URLSessionRoomTransportError.invalidHTTPResponse
        }
        guard response.url == expectedURL else {
            throw URLSessionRoomTransportError.redirected
        }
        return response
    }

    private static let pathSegmentCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static let retryableHTTPStatuses: Set<Int> = [502, 503, 504]

    private static func isRetryable(_ error: Error) -> Bool {
        if let transportError = error as? URLSessionRoomTransportError {
            switch transportError {
            case .timedOut:
                return true
            case .httpStatus(let status):
                return retryableHTTPStatuses.contains(status)
            default:
                return false
            }
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable,
             .cannotLoadFromNetwork,
             .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }

    private static func isBearerTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 43, 45...57, 61, 65...90, 95, 97...122, 126:
            true
        default:
            false
        }
    }
}
