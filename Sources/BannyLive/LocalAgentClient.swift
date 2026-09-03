import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct LocalAgentClientConfiguration: Equatable, Sendable {
    public static let hardMaximumRequestBytes = 64 * 1_024
    public static let hardMaximumResponseBytes = BannyAgentProtocol.maximumResponseBytes
    public static let hardMaximumTimeoutMS = 10_000

    public var maximumRequestBytes: Int
    public var maximumResponseBytes: Int
    public var maximumTimeoutMS: Int
    public var allowRemoteEndpoint: Bool

    public init(
        maximumRequestBytes: Int = Self.hardMaximumRequestBytes,
        maximumResponseBytes: Int = Self.hardMaximumResponseBytes,
        maximumTimeoutMS: Int = Self.hardMaximumTimeoutMS,
        allowRemoteEndpoint: Bool = false
    ) {
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumTimeoutMS = maximumTimeoutMS
        self.allowRemoteEndpoint = allowRemoteEndpoint
    }
}

public enum LocalAgentClientError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidEndpoint
    case remoteEndpointDenied(host: String)
    case insecureRemoteEndpointDenied(host: String)
    case invalidBearerToken
    case invalidContext(String)
    case requestTooLarge(actual: Int, limit: Int)
    case decisionAlreadyInFlight
    case timedOut
    case responseTooLarge(actual: Int64, limit: Int)
    case invalidHTTPResponse
    case redirected
    case httpStatus(Int)
    case malformedDecision
    case protocolMismatch(received: String)
    case requestIDMismatch(received: String)
    case invalidDecision(String)
}

extension LocalAgentClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The local-agent client limits are invalid."
        case .invalidEndpoint:
            "The local-agent endpoint must be an HTTP(S) origin."
        case .remoteEndpointDenied(let host):
            "The local-agent endpoint host \"\(host)\" is not numeric loopback."
        case .insecureRemoteEndpointDenied(let host):
            "Remote agent \"\(host)\" must use HTTPS."
        case .invalidBearerToken:
            "The local-agent bearer token is malformed."
        case .invalidContext(let reason):
            "The room supplied an invalid agent context: \(reason)"
        case .requestTooLarge(let actual, let limit):
            "The local-agent request is \(actual) bytes; the limit is \(limit)."
        case .decisionAlreadyInFlight:
            "A local-agent decision request is already in flight."
        case .timedOut:
            "The local agent did not decide before its deadline."
        case .responseTooLarge(let actual, let limit):
            "The local-agent response is \(actual) bytes; the limit is \(limit)."
        case .invalidHTTPResponse:
            "The local agent returned an invalid HTTP response."
        case .redirected:
            "The local agent attempted to redirect the decision request."
        case .httpStatus(let status):
            "The local agent returned HTTP \(status)."
        case .malformedDecision:
            "The local agent returned malformed or non-strict decision JSON."
        case .protocolMismatch(let received):
            "The local agent returned protocol \"\(received)\" instead of banny.agent.v1."
        case .requestIDMismatch:
            "The local agent returned a decision for a different request."
        case .invalidDecision(let reason):
            "The local agent returned an invalid decision: \(reason)"
        }
    }
}

/// Participant-side client for a locally running AI.
///
/// By default only numeric IPv4 127/8 and the IPv6 loopback address are
/// accepted. DNS names (including `localhost`) are deliberately rejected to
/// remove name-resolution and rebinding from this trust boundary.
public actor LocalAgentClient: AgentDecisionProvider {
    public static let protocolVersion = BannyAgentProtocol.version
    /// Time reserved inside the room's advertised deadline to validate and
    /// submit either the decision or a bridge-generated no-op. Without this
    /// margin, a local timeout would necessarily reach the room too late.
    public static let maximumSubmissionSlackMS = 500
    public static let minimumAgentBudgetMS = 50

    public nonisolated let endpoint: URL
    public nonisolated let decisionURL: URL
    public nonisolated let configuration: LocalAgentClientConfiguration

    private let session: URLSession
    private let bearerToken: String?
    private var hasDecisionInFlight = false

    public init(
        endpoint: URL,
        bearerToken: String? = nil,
        configuration: LocalAgentClientConfiguration = .init(),
        session: URLSession = .shared
    ) throws {
        guard configuration.maximumRequestBytes > 0,
              configuration.maximumRequestBytes
                <= LocalAgentClientConfiguration.hardMaximumRequestBytes,
              configuration.maximumResponseBytes > 0,
              configuration.maximumResponseBytes
                <= LocalAgentClientConfiguration.hardMaximumResponseBytes,
              (100...LocalAgentClientConfiguration.hardMaximumTimeoutMS)
                .contains(configuration.maximumTimeoutMS)
        else { throw LocalAgentClientError.invalidConfiguration }
        if let bearerToken,
           bearerToken.isEmpty || bearerToken.unicodeScalars.count > 4_096
            || !bearerToken.unicodeScalars.allSatisfy(Self.isBearerTokenScalar) {
            throw LocalAgentClientError.invalidBearerToken
        }

        self.endpoint = endpoint
        self.decisionURL = try Self.makeDecisionURL(
            endpoint: endpoint,
            allowRemote: configuration.allowRemoteEndpoint)
        self.configuration = configuration
        self.session = session
        self.bearerToken = bearerToken
    }

    public func decide(_ context: AgentContextEnvelope) async throws -> AgentDecisionEnvelope {
        guard !hasDecisionInFlight else {
            throw LocalAgentClientError.decisionAlreadyInFlight
        }
        hasDecisionInFlight = true
        defer { hasDecisionInFlight = false }

        try Self.validate(context: context)
        let body: Data
        do {
            body = try AgentProtocolCodec.encode(context)
        } catch {
            throw LocalAgentClientError.invalidContext("it could not be encoded")
        }
        guard body.count <= configuration.maximumRequestBytes else {
            throw LocalAgentClientError.requestTooLarge(
                actual: body.count,
                limit: configuration.maximumRequestBytes)
        }

        let advertisedBudgetMS = min(context.timeoutMS, configuration.maximumTimeoutMS)
        let submissionSlackMS = min(
            Self.maximumSubmissionSlackMS,
            max(Self.minimumAgentBudgetMS, advertisedBudgetMS / 5))
        let timeoutMS = max(
            Self.minimumAgentBudgetMS,
            advertisedBudgetMS - submissionSlackMS)
        var request = URLRequest(
            url: decisionURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Double(timeoutMS) / 1_000)
        request.httpMethod = "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let payload: BannyLiveURLLoader.Payload
        do {
            payload = try await BannyLiveURLLoader.data(
                for: request,
                session: session,
                timeout: Double(timeoutMS) / 1_000,
                maximumResponseBytes: configuration.maximumResponseBytes)
        } catch BannyLiveURLLoader.Error.timedOut {
            throw LocalAgentClientError.timedOut
        } catch let BannyLiveURLLoader.Error.responseTooLarge(actual, limit) {
            throw LocalAgentClientError.responseTooLarge(actual: actual, limit: limit)
        } catch let error as URLError where error.code == .timedOut {
            throw LocalAgentClientError.timedOut
        }

        guard let response = payload.response as? HTTPURLResponse else {
            throw LocalAgentClientError.invalidHTTPResponse
        }
        guard response.url == decisionURL else {
            throw LocalAgentClientError.redirected
        }
        guard (200..<300).contains(response.statusCode) else {
            throw LocalAgentClientError.httpStatus(response.statusCode)
        }

        let decision: AgentDecisionEnvelope
        do {
            decision = try AgentProtocolCodec.decodeDecision(
                payload.data,
                expectedRequestID: context.requestID,
                constraints: context.context.constraints)
        } catch let error as AgentProtocolValidationError {
            throw Self.clientError(for: error)
        }
        try Self.validateAdditionalDecisionRules(decision, for: context)
        return decision
    }

    public nonisolated static func isNumericLoopbackHost(_ host: String) -> Bool {
        let normalized: String
        if host.first == "[", host.last == "]" {
            normalized = String(host.dropFirst().dropLast())
        } else {
            normalized = host
        }

        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        if pieces.count == 4,
           pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
           let first = UInt8(pieces[0]), first == 127,
           pieces.dropFirst().allSatisfy({ UInt8($0) != nil }) {
            return true
        }

        #if canImport(Darwin)
        var address = in6_addr()
        let parsed = normalized.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else { return false }
        return withUnsafeBytes(of: address) { bytes in
            bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        }
        #else
        return normalized == "::1"
        #endif
    }

    private nonisolated static func makeDecisionURL(
        endpoint: URL,
        allowRemote: Bool
    ) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { throw LocalAgentClientError.invalidEndpoint }

        let loopback = isNumericLoopbackHost(host)
        guard allowRemote || loopback else {
            throw LocalAgentClientError.remoteEndpointDenied(host: host)
        }
        guard loopback || scheme == "https" else {
            throw LocalAgentClientError.insecureRemoteEndpointDenied(host: host)
        }
        components.scheme = scheme
        components.path = "/v1/decide"
        guard let result = components.url else {
            throw LocalAgentClientError.invalidEndpoint
        }
        return result
    }

    private nonisolated static func validate(context: AgentContextEnvelope) throws {
        guard context.protocolVersion == protocolVersion else {
            throw LocalAgentClientError.invalidContext("unsupported protocol")
        }
        guard validIdentifier(context.requestID),
              validIdentifier(context.roomID),
              validIdentifier(context.participantID)
        else {
            throw LocalAgentClientError.invalidContext("identifier length")
        }
        guard context.basisSeq >= 0 else {
            throw LocalAgentClientError.invalidContext("basis_seq must be nonnegative")
        }
        guard context.context.sceneTimeMS >= 0,
              context.context.selfState.participantID == context.participantID,
              context.context.recentEvents.count <= 32,
              context.context.recentEvents.allSatisfy({
                  $0.seq >= 0 && $0.seq <= context.basisSeq && $0.sceneTimeMS >= 0
              })
        else {
            throw LocalAgentClientError.invalidContext("inconsistent scene snapshot")
        }
        guard (100...10_000).contains(context.timeoutMS) else {
            throw LocalAgentClientError.invalidContext("timeout_ms must be 100 through 10000")
        }

        let constraints = context.context.constraints
        guard (0...BannyAgentProtocol.maximumActions).contains(constraints.maxActions),
              (0...BannyAgentProtocol.maximumSpeechCharacters)
                .contains(constraints.maxSpeechChars),
              (BannyAgentProtocol.minimumActionDurationMS...BannyAgentProtocol.maximumActionDurationMS)
                .contains(constraints.maxActionMS),
              constraints.allowedReactionIDs.count <= 32,
              Set(constraints.allowedActions).count == constraints.allowedActions.count,
              Set(constraints.allowedReactionIDs).count == constraints.allowedReactionIDs.count,
              constraints.allowedReactionIDs.allSatisfy(validIdentifier)
        else {
            throw LocalAgentClientError.invalidContext("invalid constraints")
        }
        let known = Set(AgentConstraints.allOperations)
        guard constraints.allowedActions.allSatisfy(known.contains) else {
            throw LocalAgentClientError.invalidContext("unknown allowed action")
        }
    }

    private nonisolated static func validateAdditionalDecisionRules(
        _ decision: AgentDecisionEnvelope,
        for context: AgentContextEnvelope
    ) throws {
        guard validIdentifier(decision.intentID) else {
            throw LocalAgentClientError.invalidDecision("intent_id must be 1 through 128 characters")
        }
        let constraints = context.context.constraints
        if let say = decision.say {
            guard constraints.maxSpeechChars > 0,
                  !say.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  })
            else {
                throw LocalAgentClientError.invalidDecision("say violates plain-text limits")
            }
        }
    }

    private nonisolated static func clientError(
        for error: AgentProtocolValidationError
    ) -> LocalAgentClientError {
        switch error {
        case .payloadTooLarge(let actual, let limit):
            .responseTooLarge(actual: Int64(actual), limit: limit)
        case .malformedJSON:
            .malformedDecision
        case .wrongProtocol(let received):
            .protocolMismatch(received: received)
        case .requestMismatch(let received):
            .requestIDMismatch(received: received)
        case .duplicateActionGroup(let group):
            .invalidDecision("multiple actions control \"\(group)\"")
        default:
            .invalidDecision(error.localizedDescription)
        }
    }

    private nonisolated static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.count <= 128
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private nonisolated static func isBearerTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 43, 45...57, 61, 65...90, 95, 97...122, 126:
            true
        default:
            false
        }
    }

}
