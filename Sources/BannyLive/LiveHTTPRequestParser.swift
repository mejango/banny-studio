import Foundation

public enum LiveHTTPRequestParserError: Error, Equatable, Sendable {
    case headerTooLarge
    case bodyTooLarge(limit: Int)
    case malformedRequestLine
    case unsupportedHTTPVersion
    case malformedHeader
    case duplicateHeader(String)
    case missingHost
    case unsupportedTransferEncoding
    case expectationFailed
    case lengthRequired
    case invalidContentLength
    case unexpectedTrailingBytes
    case invalidHost
    case bodyCapacityExceeded(limit: Int)

    public var statusCode: Int {
        switch self {
        case .headerTooLarge: 431
        case .bodyTooLarge: 413
        case .lengthRequired: 411
        case .expectationFailed: 417
        case .bodyCapacityExceeded: 503
        default: 400
        }
    }

    public var errorCode: String {
        switch self {
        case .headerTooLarge: "headers_too_large"
        case .bodyTooLarge: "body_too_large"
        case .malformedRequestLine: "malformed_request_line"
        case .unsupportedHTTPVersion: "unsupported_http_version"
        case .malformedHeader: "malformed_header"
        case .duplicateHeader: "duplicate_header"
        case .missingHost: "missing_host"
        case .unsupportedTransferEncoding: "unsupported_transfer_encoding"
        case .expectationFailed: "expectation_failed"
        case .lengthRequired: "length_required"
        case .invalidContentLength: "invalid_content_length"
        case .unexpectedTrailingBytes: "http_pipelining_not_supported"
        case .invalidHost: "invalid_host"
        case .bodyCapacityExceeded: "body_capacity_exceeded"
        }
    }
}

public enum LiveHTTPRequestParseResult: Equatable, Sendable {
    case incomplete
    case complete(LiveHTTPRequest)
}

/// Incremental, strict HTTP/1.1 parser for one request per connection.
///
/// Transfer-Encoding and pipelining are rejected. This deliberately small
/// surface avoids request-smuggling ambiguities while supporting ordinary
/// browser, URLSession, and curl requests with Content-Length bodies.
public struct LiveHTTPRequestParser: Sendable {
    public typealias BodyLimit = @Sendable (_ method: String, _ target: String) -> Int
    public typealias HeaderValidator = @Sendable (
        _ method: String,
        _ target: String,
        _ headers: [String: String],
        _ contentLength: Int
    ) throws -> Void

    public static let defaultMaximumHeaderBytes = 32 * 1_024
    public static let defaultMaximumBodyBytes = 100 * 1_024 * 1_024

    public let maximumHeaderBytes: Int
    public let maximumBodyBytes: Int

    private var buffer = Data()
    private var parsedHead: ParsedHead?
    private let bodyLimit: BodyLimit?
    private let headerValidator: HeaderValidator?

    public init(
        maximumHeaderBytes: Int = Self.defaultMaximumHeaderBytes,
        maximumBodyBytes: Int = Self.defaultMaximumBodyBytes,
        bodyLimit: BodyLimit? = nil,
        headerValidator: HeaderValidator? = nil
    ) {
        precondition(maximumHeaderBytes > 0)
        precondition(maximumBodyBytes >= 0)
        precondition(maximumHeaderBytes <= Int.max - 4)
        precondition(maximumHeaderBytes <= Int.max - maximumBodyBytes)
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
        self.bodyLimit = bodyLimit
        self.headerValidator = headerValidator
    }

    public mutating func append(_ bytes: Data) throws -> LiveHTTPRequestParseResult {
        if let head = parsedHead {
            guard bytes.count <= maximumBodyBytes - min(buffer.count, maximumBodyBytes) else {
                throw LiveHTTPRequestParserError.bodyTooLarge(limit: maximumBodyBytes)
            }
            buffer.append(bytes)
            return try finishIfPossible(head)
        }

        let delimiter = Data([13, 10, 13, 10])
        let maximumHeadProbeBytes = maximumHeaderBytes + delimiter.count
        var consumed = 0
        var delimiterRange: Range<Data.Index>?
        for byte in bytes {
            guard buffer.count < maximumHeadProbeBytes else {
                throw LiveHTTPRequestParserError.headerTooLarge
            }
            buffer.append(byte)
            consumed += 1
            if buffer.count >= delimiter.count {
                let lower = buffer.index(buffer.endIndex, offsetBy: -delimiter.count)
                if buffer[lower...] == delimiter {
                    delimiterRange = lower..<buffer.endIndex
                    break
                }
            }
        }

        guard let delimiterRange else {
            return .incomplete
        }
        guard delimiterRange.lowerBound <= maximumHeaderBytes else {
            throw LiveHTTPRequestParserError.headerTooLarge
        }

        let headerData = buffer[..<delimiterRange.lowerBound]
        let bodyStart = delimiterRange.upperBound
        let head = try Self.parseHead(
            Data(headerData),
            maximumBodyBytes: maximumBodyBytes,
            bodyLimit: bodyLimit,
            headerValidator: headerValidator)
        var bodyBytes = Data(buffer[bodyStart...])
        if consumed < bytes.count {
            let remaining = bytes.dropFirst(consumed)
            guard remaining.count <= maximumBodyBytes - min(bodyBytes.count, maximumBodyBytes)
            else {
                throw LiveHTTPRequestParserError.bodyTooLarge(limit: maximumBodyBytes)
            }
            bodyBytes.append(remaining)
        }
        parsedHead = head
        buffer = bodyBytes
        return try finishIfPossible(head)
    }

    /// The completed request owns its body value. The network session calls
    /// this before handing that request to an async service so the parser does
    /// not retain a second reference for the handler's entire lifetime.
    mutating func discardBufferedBodyAfterCompletion() {
        buffer = Data()
    }

    private func finishIfPossible(_ head: ParsedHead) throws -> LiveHTTPRequestParseResult {
        if buffer.count < head.contentLength {
            return .incomplete
        }
        guard buffer.count == head.contentLength else {
            throw LiveHTTPRequestParserError.unexpectedTrailingBytes
        }
        return .complete(LiveHTTPRequest(
            method: head.method,
            target: head.target,
            version: head.version,
            headers: head.headers,
            body: buffer))
    }

    private static func parseHead(
        _ data: Data,
        maximumBodyBytes: Int,
        bodyLimit: BodyLimit?,
        headerValidator: HeaderValidator?
    ) throws -> ParsedHead {
        guard let text = String(data: data, encoding: .isoLatin1) else {
            throw LiveHTTPRequestParserError.malformedHeader
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw LiveHTTPRequestParserError.malformedRequestLine
        }
        let requestParts = requestLine.split(
            separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              !requestParts[0].isEmpty,
              !requestParts[1].isEmpty,
              !requestParts[2].isEmpty,
              requestParts[0].utf8.allSatisfy(Self.isTokenByte),
              requestParts[1].first == "/",
              !requestParts[1].utf8.contains(where: Self.isForbiddenTargetByte)
        else {
            throw LiveHTTPRequestParserError.malformedRequestLine
        }
        guard requestParts[2] == "HTTP/1.1" else {
            throw LiveHTTPRequestParserError.unsupportedHTTPVersion
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  line.first != " ", line.first != "\t",
                  let colon = line.firstIndex(of: ":")
            else { throw LiveHTTPRequestParserError.malformedHeader }

            let rawName = line[..<colon]
            let rawValue = line[line.index(after: colon)...]
            guard !rawName.isEmpty,
                  rawName.utf8.allSatisfy(Self.isTokenByte),
                  rawValue.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 })
            else { throw LiveHTTPRequestParserError.malformedHeader }

            let name = rawName.lowercased()
            guard headers[name] == nil else {
                throw LiveHTTPRequestParserError.duplicateHeader(name)
            }
            headers[name] = Self.trimmingHTTPOptionalWhitespace(rawValue)
        }

        guard let host = headers["host"], !host.isEmpty else {
            throw LiveHTTPRequestParserError.missingHost
        }
        if headers["transfer-encoding"] != nil {
            throw LiveHTTPRequestParserError.unsupportedTransferEncoding
        }
        if headers["expect"] != nil {
            throw LiveHTTPRequestParserError.expectationFailed
        }

        let method = String(requestParts[0]).uppercased()
        let target = String(requestParts[1])
        let endpointMaximum = min(
            maximumBodyBytes,
            max(0, bodyLimit?(method, target) ?? maximumBodyBytes))
        let bodyMethod = method == "POST" || method == "PUT" || method == "PATCH"
        if bodyMethod && headers["content-length"] == nil {
            throw LiveHTTPRequestParserError.lengthRequired
        }

        let length: Int
        if let rawLength = headers["content-length"] {
            guard !rawLength.isEmpty,
                  rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = UInt64(rawLength),
                  parsed <= UInt64(Int.max)
            else { throw LiveHTTPRequestParserError.invalidContentLength }
            guard parsed <= UInt64(endpointMaximum) else {
                throw LiveHTTPRequestParserError.bodyTooLarge(limit: endpointMaximum)
            }
            length = Int(parsed)
        } else {
            length = 0
        }

        try headerValidator?(method, target, headers, length)

        return ParsedHead(
            method: method,
            target: target,
            version: String(requestParts[2]),
            headers: headers,
            contentLength: length)
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122: true
        case 33, 35...39, 42, 43, 45, 46, 94...96, 124, 126: true
        default: false
        }
    }

    private static func isForbiddenTargetByte(_ byte: UInt8) -> Bool {
        byte <= 32 || byte >= 127
    }

    /// RFC 9110 optional whitespace is exactly SP / HTAB. Foundation's
    /// Unicode whitespace set would also remove Latin-1 NBSP (wire byte A0),
    /// which can make Content-Length framing disagree with an intermediary.
    private static func trimmingHTTPOptionalWhitespace(
        _ raw: Substring
    ) -> String {
        var lower = raw.startIndex
        var upper = raw.endIndex
        while lower < upper, raw[lower] == " " || raw[lower] == "\t" {
            lower = raw.index(after: lower)
        }
        while lower < upper {
            let previous = raw.index(before: upper)
            guard raw[previous] == " " || raw[previous] == "\t" else { break }
            upper = previous
        }
        return String(raw[lower..<upper])
    }

    private struct ParsedHead: Sendable {
        let method: String
        let target: String
        let version: String
        let headers: [String: String]
        let contentLength: Int
    }
}
