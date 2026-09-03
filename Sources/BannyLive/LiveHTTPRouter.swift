import Foundation

public struct LiveHTTPRouter: Sendable {
    public typealias FrameRenderer = @Sendable (_ roomID: String) async throws -> Data

    public struct Limits: Equatable, Sendable {
        public var createRoomBytes: Int
        public var joinBytes: Int
        public var decisionBytes: Int
        public var leaveBytes: Int
        public var renderedFrameBytes: Int

        public init(
            createRoomBytes: Int = 100 * 1_024 * 1_024,
            joinBytes: Int = 32 * 1_024,
            decisionBytes: Int = 16 * 1_024,
            leaveBytes: Int = 64 * 1_024,
            renderedFrameBytes: Int = 16 * 1_024 * 1_024
        ) {
            precondition(createRoomBytes > 0)
            precondition(joinBytes > 0)
            precondition(decisionBytes > 0)
            precondition(leaveBytes > 0)
            precondition(renderedFrameBytes > 0)
            self.createRoomBytes = createRoomBytes
            self.joinBytes = joinBytes
            self.decisionBytes = decisionBytes
            self.leaveBytes = leaveBytes
            self.renderedFrameBytes = renderedFrameBytes
        }
    }

    private let service: any LiveHTTPService
    private let staticAssets: (any LiveHTTPStaticAssetProviding)?
    private let frameRenderer: FrameRenderer?
    private let limits: Limits

    public init(
        service: any LiveHTTPService,
        staticAssets: (any LiveHTTPStaticAssetProviding)? = nil,
        frameRenderer: FrameRenderer? = nil,
        limits: Limits = Limits()
    ) {
        self.service = service
        self.staticAssets = staticAssets
        self.frameRenderer = frameRenderer
        self.limits = limits
    }

    public func response(to request: LiveHTTPRequest) async -> LiveHTTPResponse {
        do {
            let target = try ParsedTarget(request.target)
            let response: LiveHTTPResponse
            if target.components.first == "v1" {
                response = try await routeAPI(request, target: target)
            } else {
                response = try await routeStatic(request, target: target)
            }
            return secured(response, api: target.components.first == "v1")
        } catch let problem as LiveHTTPMethodProblem {
            var response = Self.problemResponse(
                status: problem.liveHTTPStatusCode,
                code: problem.liveHTTPErrorCode,
                message: problem.liveHTTPPublicMessage)
            response.setHeader("Allow", value: problem.allowed)
            return secured(response, api: true)
        } catch let problem as any LiveHTTPErrorRepresentable {
            return secured(Self.problemResponse(
                status: problem.liveHTTPStatusCode,
                code: problem.liveHTTPErrorCode,
                message: problem.liveHTTPPublicMessage), api: true)
        } catch {
            return secured(Self.problemResponse(
                status: 500,
                code: "internal_error",
                message: "The room server could not complete the request."), api: true)
        }
    }

    public func response(to parserError: LiveHTTPRequestParserError) -> LiveHTTPResponse {
        errorResponse(
            status: parserError.statusCode,
            code: parserError.errorCode,
            message: "The HTTP request could not be accepted.")
    }

    func errorResponse(status: Int, code: String, message: String) -> LiveHTTPResponse {
        secured(Self.problemResponse(
            status: status,
            code: code,
            message: message), api: true)
    }

    /// Lets the streaming parser reject an oversized endpoint body from its
    /// Content-Length before buffering it. The router repeats these checks for
    /// requests supplied by in-memory tests or alternate transports.
    func maximumRequestBodyBytes(method: String, target: String) -> Int {
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        guard method == "POST" || method == "PUT" || method == "PATCH" else {
            return 0
        }
        if path == "/v1/rooms" { return limits.createRoomBytes }
        if path.hasSuffix("/join") { return limits.joinBytes }
        if path.contains("/decisions/") { return limits.decisionBytes }
        if path.hasSuffix("/leave") { return limits.leaveBytes }
        if path.hasSuffix("/end") { return 0 }
        return min(limits.decisionBytes, limits.leaveBytes)
    }

    private func routeAPI(
        _ request: LiveHTTPRequest,
        target: ParsedTarget
    ) async throws -> LiveHTTPResponse {
        let c = target.components
        if (request.method == "GET" || request.method == "DELETE"),
           !request.body.isEmpty {
            throw LiveHTTPProblem(
                status: 400,
                code: "unexpected_body",
                message: "This request must not contain a body.")
        }
        if c == ["v1", "catalog"] {
            try Self.requireNoQuery(target)
            guard request.method == "GET" else {
                throw Self.methodNotAllowed("GET")
            }
            return try await perform(.catalog)
        }
        guard c.count >= 2, c[0] == "v1", c[1] == "rooms" else {
            throw Self.notFound
        }

        if c.count == 2 {
            try Self.requireNoQuery(target)
            switch request.method {
            case "GET":
                return try await perform(.listRooms)
            case "POST":
                try requireJSON(request, maximumBytes: limits.createRoomBytes)
                return try await perform(.createRoom(json: request.body))
            default:
                throw Self.methodNotAllowed("GET, POST")
            }
        }

        let roomID = try Self.identifier(c[2], kind: "room")
        if c.count == 3 {
            try Self.requireNoQuery(target)
            guard request.method == "GET" else {
                throw Self.methodNotAllowed("GET")
            }
            return try await perform(.getRoom(roomID: roomID))
        }

        let tail = Array(c.dropFirst(3))
        switch tail {
        case ["join"]:
            try Self.requireNoQuery(target)
            guard request.method == "POST" else {
                throw Self.methodNotAllowed("POST")
            }
            let object = try requireJSON(request, maximumBytes: limits.joinBytes)
            guard !Self.containsAgentEndpoint(in: object) else {
                throw LiveHTTPProblem(
                    status: 400,
                    code: "agent_endpoint_not_allowed",
                    message: "The local agent endpoint belongs only in the participant bridge.")
            }
            return try await perform(.join(
                roomID: roomID,
                json: request.body,
                authorization: try Self.optionalBearerCredential(request)))

        case ["decisions", "next"]:
            guard request.method == "GET" else {
                throw Self.methodNotAllowed("GET")
            }
            let authorization = try Self.bearerCredential(request)
            let after = try Self.afterCursor(target.query)
            return try await perform(.nextDecision(
                roomID: roomID,
                after: after,
                authorization: authorization))

        case let values where values.count == 2 && values[0] == "decisions"
            && values[1] != "next":
            try Self.requireNoQuery(target)
            let requestID = values[1]
            guard request.method == "POST" else {
                throw Self.methodNotAllowed("POST")
            }
            let authorization = try Self.bearerCredential(request)
            _ = try requireJSON(request, maximumBytes: limits.decisionBytes)
            return try await perform(.submitDecision(
                roomID: roomID,
                requestID: try Self.identifier(requestID, kind: "request"),
                json: request.body,
                authorization: authorization))

        case ["leave"]:
            try Self.requireNoQuery(target)
            guard request.method == "POST" else {
                throw Self.methodNotAllowed("POST")
            }
            let authorization = try Self.bearerCredential(request)
            let body: Data?
            if request.body.isEmpty {
                body = nil
            } else {
                _ = try requireJSON(request, maximumBytes: limits.leaveBytes)
                body = request.body
            }
            return try await perform(.leave(
                roomID: roomID,
                json: body,
                authorization: authorization))

        case ["frame.jpg"]:
            guard request.method == "GET" else {
                throw Self.methodNotAllowed("GET")
            }
            guard let frameRenderer else {
                throw LiveHTTPProblem(
                    status: 501,
                    code: "frame_renderer_unavailable",
                    message: "This room server was started without a live frame renderer.")
            }
            let data = try await frameRenderer(roomID)
            guard data.count <= limits.renderedFrameBytes else {
                throw LiveHTTPProblem(
                    status: 500,
                    code: "rendered_frame_too_large",
                    message: "The rendered frame exceeded the server limit.")
            }
            return LiveHTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "image/jpeg",
                    "Cache-Control": "no-store",
                ],
                body: data)

        case ["music"]:
            try Self.requireNoQuery(target)
            guard request.method == "GET" else {
                throw Self.methodNotAllowed("GET")
            }
            return Self.musicResponse(
                try await perform(.music(roomID: roomID)),
                rangeHeader: request.header("range"))

        case ["end"]:
            try Self.requireNoQuery(target)
            guard request.method == "POST" else {
                throw Self.methodNotAllowed("POST")
            }
            guard request.body.isEmpty else {
                throw LiveHTTPProblem(
                    status: 400,
                    code: "unexpected_body",
                    message: "This request must not contain a body.")
            }
            return try await perform(.endRoom(
                roomID: roomID,
                authorization: Self.bearerCredential(request)))

        case let values where values.count == 2 && values[0] == "participants":
            try Self.requireNoQuery(target)
            let participantID = values[1]
            guard request.method == "DELETE" else {
                throw Self.methodNotAllowed("DELETE")
            }
            return try await perform(.removeParticipant(
                roomID: roomID,
                participantID: Self.identifier(participantID, kind: "participant"),
                authorization: Self.bearerCredential(request)))

        default:
            throw Self.notFound
        }
    }

    private func routeStatic(
        _ request: LiveHTTPRequest,
        target: ParsedTarget
    ) async throws -> LiveHTTPResponse {
        guard request.method == "GET" else {
            throw Self.methodNotAllowed("GET")
        }
        guard let staticAssets else { throw Self.notFound }

        let requestedPath = target.components.isEmpty
            ? "index.html" : target.components.joined(separator: "/")
        let requested = try await staticAssets.asset(at: requestedPath)
        let isSPARoute = !target.components.isEmpty
            && !(target.components.last?.contains(".") ?? false)
        let asset: LiveHTTPStaticAsset?
        if let requested {
            asset = requested
        } else if isSPARoute && !staticAssets.isAuthoritative(for: requestedPath) {
            asset = try await staticAssets.asset(at: "index.html")
        } else {
            asset = nil
        }
        guard let asset else { throw Self.notFound }

        return LiveHTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": asset.contentType,
                "Cache-Control": asset.cacheControl,
            ],
            body: asset.data)
    }

    private func perform(_ operation: LiveHTTPOperation) async throws -> LiveHTTPResponse {
        let result = try await service.perform(operation)
        guard (200...599).contains(result.statusCode) else {
            throw LiveHTTPProblem(
                status: 500,
                code: "invalid_service_response",
                message: "The room service produced an invalid response.")
        }
        return LiveHTTPResponse(
            statusCode: result.statusCode,
            headers: result.headers,
            body: result.body)
    }

    @discardableResult
    private func requireJSON(
        _ request: LiveHTTPRequest,
        maximumBytes: Int
    ) throws -> [String: Any] {
        guard request.body.count <= maximumBytes else {
            throw LiveHTTPProblem(
                status: 413,
                code: "body_too_large",
                message: "The request body exceeded this endpoint's limit.")
        }
        guard !request.body.isEmpty else {
            throw LiveHTTPProblem(
                status: 400, code: "missing_json", message: "A JSON body is required.")
        }
        guard let contentType = request.header("content-type")?.lowercased(),
              contentType.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) == "application/json"
        else {
            throw LiveHTTPProblem(
                status: 415,
                code: "unsupported_media_type",
                message: "Content-Type must be application/json.")
        }
        do {
            guard let object = try JSONSerialization.jsonObject(
                with: request.body, options: []) as? [String: Any]
            else {
                throw LiveHTTPProblem(
                    status: 400,
                    code: "invalid_json",
                    message: "The JSON request body must be an object.")
            }
            return object
        } catch let problem as LiveHTTPProblem {
            throw problem
        } catch {
            throw LiveHTTPProblem(
                status: 400,
                code: "invalid_json",
                message: "The request body is not valid JSON.")
        }
    }

    private func secured(_ original: LiveHTTPResponse, api: Bool) -> LiveHTTPResponse {
        var response = original
        if response.statusCode == 204 || response.statusCode == 304 {
            response.body = Data()
        }
        response.setHeader("Content-Security-Policy", value:
            "default-src 'self'; script-src 'self'; style-src 'self'; "
            + "img-src 'self' data: blob:; media-src 'self' blob:; "
            + "connect-src 'self'; object-src 'none'; base-uri 'none'; "
            + "frame-ancestors 'none'; form-action 'self'")
        response.setHeader("Cross-Origin-Resource-Policy", value: "same-origin")
        response.setHeader("Cross-Origin-Opener-Policy", value: "same-origin")
        response.setHeader("Permissions-Policy", value:
            "camera=(), microphone=(), geolocation=()")
        response.setHeader("Referrer-Policy", value: "no-referrer")
        response.setHeader("X-Content-Type-Options", value: "nosniff")
        response.setHeader("X-Frame-Options", value: "DENY")
        if response.statusCode == 401 {
            response.setHeader("WWW-Authenticate", value: "Bearer")
        }
        if api {
            response.setHeader("Cache-Control", value: "no-store")
        }
        return response
    }

    private static func bearerCredential(
        _ request: LiveHTTPRequest
    ) throws -> LiveHTTPBearerCredential {
        guard let value = request.header("authorization") else {
            throw LiveHTTPProblem(
                status: 401,
                code: "authentication_required",
                message: "A bearer credential is required.")
        }
        let pieces = value.split(whereSeparator: { $0.isWhitespace })
        let rawToken = pieces.count == 2 ? pieces[1] : Substring()
        guard pieces.count == 2,
              pieces[0].caseInsensitiveCompare("Bearer") == .orderedSame,
              !rawToken.isEmpty, rawToken.count <= 4_096,
              rawToken.utf8.allSatisfy({ (33...126).contains($0) })
        else {
            throw LiveHTTPProblem(
                status: 401,
                code: "invalid_authorization",
                message: "Authorization must contain one bearer credential.")
        }
        return LiveHTTPBearerCredential(token: String(rawToken))
    }

    private static func optionalBearerCredential(
        _ request: LiveHTTPRequest
    ) throws -> LiveHTTPBearerCredential? {
        guard request.header("authorization") != nil else { return nil }
        return try bearerCredential(request)
    }

    private static func afterCursor(_ query: [String: [String]]) throws -> Int64? {
        let unknown = query.keys.filter { $0 != "after" }
        guard unknown.isEmpty else {
            throw LiveHTTPProblem(
                status: 400,
                code: "unknown_query_parameter",
                message: "Only the after query parameter is supported.")
        }
        guard let values = query["after"] else { return nil }
        guard values.count == 1, let raw = values.first, !raw.isEmpty,
              raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(raw)
        else {
            throw LiveHTTPProblem(
                status: 400,
                code: "invalid_cursor",
                message: "The after cursor must be one unsigned integer.")
        }
        return value
    }

    private static func requireNoQuery(_ target: ParsedTarget) throws {
        guard target.query.isEmpty else {
            throw LiveHTTPProblem(
                status: 400,
                code: "unknown_query_parameter",
                message: "This route does not accept query parameters.")
        }
    }

    private static func identifier(_ value: String, kind: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 200,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45 || byte == 46 || byte == 95 || byte == 126
              })
        else {
            throw LiveHTTPProblem(
                status: 400,
                code: "invalid_\(kind)_id",
                message: "The \(kind) identifier is invalid.")
        }
        return value
    }

    private static func containsAgentEndpoint(in value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if normalized == "agentendpoint" || normalized == "agenturl" {
                    return true
                }
                if containsAgentEndpoint(in: child) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: containsAgentEndpoint)
        }
        return false
    }

    private static func musicResponse(
        _ original: LiveHTTPResponse,
        rangeHeader: String?
    ) -> LiveHTTPResponse {
        var response = original
        guard response.statusCode == 200 else { return response }
        response.setHeader("Accept-Ranges", value: "bytes")
        guard let rangeHeader else { return response }

        let total = original.body.count
        guard let range = singleByteRange(rangeHeader, totalBytes: total) else {
            return LiveHTTPResponse(
                statusCode: 416,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Content-Range": "bytes */\(total)",
                    "Accept-Ranges": "bytes",
                ],
                body: Data(#"{"error":{"code":"invalid_range","message":"The requested byte range is unavailable."}}"#.utf8))
        }

        response.statusCode = 206
        response.body = original.body.subdata(in: range)
        response.setHeader(
            "Content-Range",
            value: "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)")
        return response
    }

    private static func singleByteRange(
        _ raw: String,
        totalBytes: Int
    ) -> Range<Int>? {
        guard totalBytes > 0, raw.hasPrefix("bytes="), !raw.contains(",") else {
            return nil
        }
        let value = raw.dropFirst("bytes=".count)
        let pieces = value.split(separator: "-", maxSplits: 1,
                                 omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }

        if pieces[0].isEmpty {
            guard let suffix = Self.decimalInt(pieces[1]), suffix > 0 else { return nil }
            let count = min(suffix, totalBytes)
            return (totalBytes - count)..<totalBytes
        }

        guard let start = Self.decimalInt(pieces[0]), start < totalBytes else {
            return nil
        }
        if pieces[1].isEmpty {
            return start..<totalBytes
        }
        guard let inclusiveEnd = Self.decimalInt(pieces[1]), inclusiveEnd >= start else {
            return nil
        }
        let end = min(inclusiveEnd, totalBytes - 1)
        return start..<(end + 1)
    }

    private static func decimalInt<S: StringProtocol>(_ raw: S) -> Int? {
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt64(raw), value <= UInt64(Int.max)
        else { return nil }
        return Int(value)
    }

    private static func problemResponse(
        status: Int,
        code: String,
        message: String
    ) -> LiveHTTPResponse {
        let safeObject: [String: Any] = [
            "error": ["code": code, "message": message],
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: safeObject, options: [.sortedKeys])) ?? Data()
        return LiveHTTPResponse(
            statusCode: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data)
    }

    private static var notFound: LiveHTTPProblem {
        LiveHTTPProblem(status: 404, code: "not_found", message: "No route was found.")
    }

    private static func methodNotAllowed(_ allowed: String) -> LiveHTTPMethodProblem {
        LiveHTTPMethodProblem(allowed: allowed)
    }
}

private struct LiveHTTPMethodProblem: LiveHTTPErrorRepresentable {
    let allowed: String
    let liveHTTPStatusCode = 405
    let liveHTTPErrorCode = "method_not_allowed"
    let liveHTTPPublicMessage = "That method is not allowed for this route."
}

private struct ParsedTarget: Sendable {
    let components: [String]
    let query: [String: [String]]

    init(_ target: String) throws {
        guard target.hasPrefix("/"), !target.contains("#") else {
            throw LiveHTTPProblem(
                status: 400, code: "invalid_target", message: "The request target is invalid.")
        }
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces[0])
        let rawPathComponents = path.dropFirst().split(
            separator: "/", omittingEmptySubsequences: false)

        if path == "/" {
            components = []
        } else {
            guard !rawPathComponents.contains(where: { $0.isEmpty }) else {
                throw LiveHTTPProblem(
                    status: 400,
                    code: "invalid_path",
                    message: "Empty path components are not supported.")
            }
            components = try rawPathComponents.map { raw in
                guard let decoded = String(raw).removingPercentEncoding,
                      decoded != ".", decoded != "..",
                      !decoded.contains("/"), !decoded.contains("\\"),
                      !decoded.unicodeScalars.contains(where: {
                          $0.value == 0 || $0.value < 32 || $0.value == 127
                      })
                else {
                    throw LiveHTTPProblem(
                        status: 400,
                        code: "invalid_path",
                        message: "A path component is invalid.")
                }
                return decoded
            }
        }

        if pieces.count == 1 || pieces[1].isEmpty {
            query = [:]
        } else {
            var values: [String: [String]] = [:]
            for item in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
                guard !item.isEmpty else {
                    throw LiveHTTPProblem(
                        status: 400,
                        code: "invalid_query",
                        message: "The query string is invalid.")
                }
                let pair = item.split(separator: "=", maxSplits: 1,
                                      omittingEmptySubsequences: false)
                guard let name = String(pair[0]).removingPercentEncoding,
                      !name.isEmpty,
                      let value = String(pair.count == 2 ? pair[1] : "")
                        .removingPercentEncoding
                else {
                    throw LiveHTTPProblem(
                        status: 400,
                        code: "invalid_query",
                        message: "The query string is invalid.")
                }
                values[name, default: []].append(value)
            }
            query = values
        }
    }
}
