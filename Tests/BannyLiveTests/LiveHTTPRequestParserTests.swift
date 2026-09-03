import Foundation
import XCTest
@testable import BannyLive

final class LiveHTTPRequestParserTests: XCTestCase {
    func testParsesFragmentedContentLengthRequest() throws {
        var parser = LiveHTTPRequestParser(maximumBodyBytes: 32)
        let first = Data("POST /v1/rooms HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8)
        let second = Data("Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{".utf8)
        let third = Data("}".utf8)

        XCTAssertEqual(try parser.append(first), .incomplete)
        XCTAssertEqual(try parser.append(second), .incomplete)
        let parsed = try parser.append(third)

        guard case .complete(let request) = parsed else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/v1/rooms")
        XCTAssertEqual(request.header("HOST"), "127.0.0.1")
        XCTAssertEqual(request.body, Data("{}".utf8))
    }

    func testRejectsBodyOverConfiguredLimitFromHead() throws {
        var parser = LiveHTTPRequestParser(maximumBodyBytes: 4)
        let request = Data(
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n".utf8)
        XCTAssertThrowsError(try parser.append(request)) { error in
            XCTAssertEqual(
                error as? LiveHTTPRequestParserError,
                .bodyTooLarge(limit: 4))
        }
    }

    func testEndpointLimitRejectsBeforeBodyIsBuffered() throws {
        var parser = LiveHTTPRequestParser(
            maximumBodyBytes: 1_024,
            bodyLimit: { _, target in target.contains("decisions") ? 16 : 1_024 })
        let request = Data(
            "POST /v1/rooms/r/decisions/q HTTP/1.1\r\nHost: localhost\r\nContent-Length: 17\r\n\r\n".utf8)

        XCTAssertThrowsError(try parser.append(request)) { error in
            XCTAssertEqual(
                error as? LiveHTTPRequestParserError,
                .bodyTooLarge(limit: 16))
        }
    }

    func testHeaderValidatorRejectsImmediatelyWithoutWaitingForDeclaredBody() throws {
        let observation = LockedHeaderObservation()
        var parser = LiveHTTPRequestParser(
            maximumBodyBytes: 100 * 1_024 * 1_024,
            headerValidator: { method, target, headers, contentLength in
                observation.set(
                    method: method,
                    target: target,
                    host: headers["host"],
                    contentLength: contentLength)
                throw LiveHTTPRequestParserError.invalidHost
            })
        let headersOnly = Data(
            "POST /v1/rooms HTTP/1.1\r\nHost: attacker.example\r\nContent-Length: 104857600\r\n\r\n".utf8)

        XCTAssertThrowsError(try parser.append(headersOnly)) { error in
            XCTAssertEqual(error as? LiveHTTPRequestParserError, .invalidHost)
        }
        XCTAssertEqual(observation.get(), HeaderObservation(
            method: "POST",
            target: "/v1/rooms",
            host: "attacker.example",
            contentLength: 100 * 1_024 * 1_024))
    }

    func testRejectsDuplicateHeadersAndTransferEncoding() throws {
        var duplicate = LiveHTTPRequestParser()
        let duplicateRequest = Data(
            "GET / HTTP/1.1\r\nHost: localhost\r\nHost: other\r\n\r\n".utf8)
        XCTAssertThrowsError(try duplicate.append(duplicateRequest)) { error in
            XCTAssertEqual(
                error as? LiveHTTPRequestParserError,
                .duplicateHeader("host"))
        }

        var chunked = LiveHTTPRequestParser()
        let chunkedRequest = Data(
            "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        XCTAssertThrowsError(try chunked.append(chunkedRequest)) { error in
            XCTAssertEqual(
                error as? LiveHTTPRequestParserError,
                .unsupportedTransferEncoding)
        }
    }

    func testContentLengthTrimsOnlyHTTPWhitespaceNotLatin1NBSP() throws {
        var parser = LiveHTTPRequestParser()
        var request = Data("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length:".utf8)
        request.append(0xa0)
        request.append(Data("5\r\n\r\nhello".utf8))

        XCTAssertThrowsError(try parser.append(request)) { error in
            XCTAssertEqual(error as? LiveHTTPRequestParserError, .invalidContentLength)
        }
    }

    func testRequiresLengthForMethodsWithBodies() throws {
        var parser = LiveHTTPRequestParser()
        let request = Data("POST / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        XCTAssertThrowsError(try parser.append(request)) { error in
            XCTAssertEqual(error as? LiveHTTPRequestParserError, .lengthRequired)
        }
    }

    func testRejectsPipelinedOrSmuggledTrailingBytes() throws {
        var parser = LiveHTTPRequestParser()
        let request = Data(
            "GET / HTTP/1.1\r\nHost: localhost\r\n\r\nGET /two HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        XCTAssertThrowsError(try parser.append(request)) { error in
            XCTAssertEqual(
                error as? LiveHTTPRequestParserError,
                .unexpectedTrailingBytes)
        }
    }

    func testSerializedResponseOwnsLengthAndDropsInjectedHeader() {
        let response = LiveHTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "999",
                "X-Unsafe": "okay\r\nInjected: yes",
                "X-Control": "okay\u{0}still-unsafe",
                "Content-Type": "text/plain",
                "Transfer-Encoding": "chunked",
                "Connection": "X-Internal-Hop",
                "X-Internal-Hop": "remove-me",
            ],
            body: Data("hello".utf8))
        let wire = String(decoding: response.serialized(), as: UTF8.self)

        XCTAssertTrue(wire.contains("Content-Length: 5\r\n"))
        XCTAssertFalse(wire.contains("999"))
        XCTAssertFalse(wire.contains("Injected"))
        XCTAssertFalse(wire.contains("still-unsafe"))
        XCTAssertFalse(wire.lowercased().contains("transfer-encoding"))
        XCTAssertFalse(wire.contains("X-Internal-Hop"))
        XCTAssertTrue(wire.contains("Connection: close\r\n"))
        XCTAssertTrue(wire.hasSuffix("\r\n\r\nhello"))
    }
}

private struct HeaderObservation: Equatable {
    let method: String
    let target: String
    let host: String?
    let contentLength: Int
}

private final class LockedHeaderObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HeaderObservation?

    func set(method: String, target: String, host: String?, contentLength: Int) {
        lock.lock()
        value = HeaderObservation(
            method: method,
            target: target,
            host: host,
            contentLength: contentLength)
        lock.unlock()
    }

    func get() -> HeaderObservation? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
