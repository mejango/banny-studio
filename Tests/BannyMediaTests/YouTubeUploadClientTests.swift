import XCTest
@testable import BannyMedia

final class YouTubeUploadClientTests: XCTestCase {
    override func tearDown() {
        YouTubeMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testResumableStartRequestUsesLeastSurprisingMetadata() throws {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let request = try YouTubeUploadClient.resumableStartRequest(
            url: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos")!,
            metadata: YouTubeVideoMetadata(
                title: "  My show  ",
                description: "A description",
                privacy: .public,
                madeForKids: true,
                publishAt: date,
                containsSyntheticMedia: true),
            totalBytes: 123,
            accessToken: "token")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Upload-Content-Length"), "123")
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "uploadType" })?.value,
                       "resumable")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let snippet = try XCTUnwrap(object["snippet"] as? [String: Any])
        let status = try XCTUnwrap(object["status"] as? [String: Any])
        XCTAssertEqual(snippet["title"] as? String, "My show")
        XCTAssertEqual(status["privacyStatus"] as? String, "private",
                       "scheduled uploads must begin private")
        XCTAssertEqual(status["selfDeclaredMadeForKids"] as? Bool, true)
        XCTAssertEqual(status["containsSyntheticMedia"] as? Bool, true)
        XCTAssertNotNil(status["publishAt"])
    }

    func testChunkRequestAndAcknowledgedRange() throws {
        let url = URL(string: "https://upload.example/session")!
        let data = Data(repeating: 7, count: 10)
        let request = YouTubeUploadClient.uploadChunkRequest(
            url: url, data: data, from: 100, through: 109, totalBytes: 1_000,
            accessToken: "token")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"),
                       "bytes 100-109/1000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(request.httpBody, data)

        let response = try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 308, httpVersion: nil,
                            headerFields: ["Range": "bytes=0-109"]))
        XCTAssertEqual(YouTubeUploadClient.nextOffset(from: response), 110)
    }

    func testMissingAcknowledgedRangeRestartsAtZero() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(url: URL(string: "https://upload.example/session")!,
                            statusCode: 308, httpVersion: nil, headerFields: nil))
        XCTAssertEqual(YouTubeUploadClient.nextOffset(from: response), 0)
    }

    func testLostFinalResponseRecoversCompletedVideoWithoutDuplicateUpload() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("youtube-upload-\(UUID().uuidString).mp4")
        try Data([1, 2, 3, 4]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        final class Counts: @unchecked Sendable {
            let lock = NSLock()
            var starts = 0
            var mediaPuts = 0
            var statusQueries = 0
            func mutate(_ body: (Counts) -> Void) {
                lock.lock()
                body(self)
                lock.unlock()
            }
            func snapshot() -> (Int, Int, Int) {
                lock.lock()
                defer { lock.unlock() }
                return (starts, mediaPuts, statusQueries)
            }
        }
        let counts = Counts()
        YouTubeMockURLProtocol.handler = { request in
            let status: Int
            let headers: [String: String]
            let body: Data
            if request.httpMethod == "POST" {
                counts.mutate { $0.starts += 1 }
                status = 200
                headers = ["Location": "https://upload.example/session"]
                body = Data()
            } else if request.value(forHTTPHeaderField: "Content-Range")?.contains("*") == true {
                counts.mutate { $0.statusQueries += 1 }
                status = 200
                headers = [:]
                body = Data(#"{"id":"recovered-video"}"#.utf8)
            } else {
                // Simulates YouTube committing the bytes, followed by the app
                // receiving a transient response instead of the final resource.
                counts.mutate { $0.mediaPuts += 1 }
                status = 503
                headers = [:]
                body = Data(#"{"error":{"message":"temporary"}}"#.utf8)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: headers)!
            return (response, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [YouTubeMockURLProtocol.self]
        let client = YouTubeUploadClient(session: URLSession(configuration: configuration))

        let result = try await client.uploadVideo(
            fileURL: file,
            metadata: YouTubeVideoMetadata(title: "Recovery"),
            accessToken: "token")

        XCTAssertEqual(result.videoID, "recovered-video")
        let snapshot = counts.snapshot()
        XCTAssertEqual(snapshot.0, 1)
        XCTAssertEqual(snapshot.1, 1)
        XCTAssertEqual(snapshot.2, 1)
    }
}

private final class YouTubeMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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
