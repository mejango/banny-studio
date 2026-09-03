import Foundation

/// A single, fully buffered HTTP/1.1 request.
///
/// Header names are normalized to lowercase. The live server intentionally
/// closes the connection after every response, so a request never contains
/// pipelined bytes belonging to a later request.
public struct LiveHTTPRequest: Equatable, Sendable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: [String: String]
    public var body: Data

    public init(
        method: String,
        target: String,
        version: String = "HTTP/1.1",
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method.uppercased()
        self.target = target
        self.version = version
        var normalizedHeaders: [String: String] = [:]
        for name in headers.keys.sorted() where normalizedHeaders[name.lowercased()] == nil {
            normalizedHeaders[name.lowercased()] = headers[name]
        }
        self.headers = normalizedHeaders
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public struct LiveHTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public static func json(
        statusCode: Int = 200,
        _ object: Any,
        headers: [String: String] = [:]
    ) throws -> LiveHTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json; charset=utf-8"
        return LiveHTTPResponse(statusCode: statusCode, headers: responseHeaders, body: data)
    }

    /// Produces one HTTP/1.1 response with an authoritative Content-Length.
    /// Invalid service-supplied header names and values are omitted to prevent
    /// response splitting.
    public func serialized() -> Data {
        var hopByHopNames: Set<String> = [
            "connection", "content-length", "keep-alive", "proxy-connection",
            "trailer", "transfer-encoding", "upgrade",
        ]
        for (name, value) in headers
        where name.caseInsensitiveCompare("Connection") == .orderedSame {
            for token in value.split(separator: ",") {
                let candidate = token.trimmingCharacters(in: .whitespaces)
                if Self.isValidHeaderName(candidate) {
                    hopByHopNames.insert(candidate.lowercased())
                }
            }
        }

        var normalized: [String: (name: String, value: String)] = [:]
        for name in headers.keys.sorted() {
            guard let value = headers[name], Self.isValidHeaderName(name),
                  !value.unicodeScalars.contains(where: {
                      ($0.value < 32 && $0.value != 9) || $0.value == 127
                  }),
                  !hopByHopNames.contains(name.lowercased())
            else { continue }
            let key = name.lowercased()
            if normalized[key] == nil {
                normalized[key] = (name, value)
            }
        }
        var safeHeaders = Dictionary(uniqueKeysWithValues:
            normalized.values.map { ($0.name, $0.value) })
        Self.setHeader("Content-Length", value: String(body.count), in: &safeHeaders)
        Self.setHeader("Connection", value: "close", in: &safeHeaders)

        var head = "HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))\r\n"
        for (name, value) in safeHeaders.sorted(by: {
            $0.key.lowercased() < $1.key.lowercased()
        }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    mutating func setHeader(_ name: String, value: String) {
        Self.setHeader(name, value: value, in: &headers)
    }

    private static func setHeader(
        _ name: String,
        value: String,
        in headers: inout [String: String]
    ) {
        let existingKeys = headers.keys.filter {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
        for existing in existingKeys {
            headers.removeValue(forKey: existing)
        }
        headers[name] = value
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 65...90, 97...122: true
            case 33, 35...39, 42, 43, 45, 46, 94...96, 124, 126: true
            default: false
            }
        }
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 416: "Range Not Satisfiable"
        case 417: "Expectation Failed"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        case 507: "Insufficient Storage"
        default: "Response"
        }
    }
}

public struct LiveHTTPBearerCredential: Equatable, Sendable {
    /// Kept out of descriptions and errors deliberately. This value should be
    /// passed directly to the room actor and never recorded in a show package.
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

/// The stable seam between HTTP and the room coordinator. JSON remains bytes
/// here so the server transport does not introduce a second copy of the agent
/// or room wire models.
public enum LiveHTTPOperation: Equatable, Sendable {
    case catalog
    case listRooms
    case createRoom(json: Data)
    case getRoom(roomID: String)
    case join(
        roomID: String,
        json: Data,
        authorization: LiveHTTPBearerCredential?
    )
    case nextDecision(
        roomID: String,
        after: Int64?,
        authorization: LiveHTTPBearerCredential
    )
    case submitDecision(
        roomID: String,
        requestID: String,
        json: Data,
        authorization: LiveHTTPBearerCredential
    )
    case leave(
        roomID: String,
        json: Data?,
        authorization: LiveHTTPBearerCredential
    )
    case music(roomID: String)
    case endRoom(roomID: String, authorization: LiveHTTPBearerCredential)
    case removeParticipant(
        roomID: String,
        participantID: String,
        authorization: LiveHTTPBearerCredential
    )
}

public struct LiveHTTPServiceResult: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable & Sendable>(
        statusCode: Int = 200,
        _ value: T,
        encoder: JSONEncoder = LiveHTTPJSON.encoder
    ) throws -> LiveHTTPServiceResult {
        LiveHTTPServiceResult(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: try encoder.encode(value))
    }
}

public protocol LiveHTTPService: Sendable {
    func perform(_ operation: LiveHTTPOperation) async throws -> LiveHTTPServiceResult
}

/// Room-layer errors can opt into a public HTTP representation. All other
/// errors are reduced to a generic 500 response so implementation details and
/// credentials cannot leak onto the wire.
public protocol LiveHTTPErrorRepresentable: Error {
    var liveHTTPStatusCode: Int { get }
    var liveHTTPErrorCode: String { get }
    var liveHTTPPublicMessage: String { get }
}

public struct LiveHTTPProblem: Error, Equatable, Sendable, LiveHTTPErrorRepresentable {
    public let liveHTTPStatusCode: Int
    public let liveHTTPErrorCode: String
    public let liveHTTPPublicMessage: String

    public init(status: Int, code: String, message: String) {
        self.liveHTTPStatusCode = status
        self.liveHTTPErrorCode = code
        self.liveHTTPPublicMessage = message
    }
}

public enum LiveHTTPJSON {
    /// Wire DTOs must declare explicit snake-case CodingKeys. A global key
    /// strategy cannot reliably map acronym properties such as `roomID`.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder {
        JSONDecoder()
    }
}
