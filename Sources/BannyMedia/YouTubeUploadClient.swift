import Foundation
import BannyCore

public enum YouTubePrivacyStatus: String, Codable, CaseIterable, Sendable {
    case `private`
    case unlisted
    case `public`

    public var displayName: String {
        switch self {
        case .private: "Private"
        case .unlisted: "Unlisted"
        case .public: "Public"
        }
    }
}

public struct YouTubeVideoMetadata: Equatable, Sendable {
    public var title: String
    public var description: String
    public var privacy: YouTubePrivacyStatus
    public var madeForKids: Bool
    /// YouTube only permits scheduled publishing while the video is private.
    public var publishAt: Date?
    /// YouTube's disclosure is specifically for realistic altered/synthetic
    /// material, not every animation or effect.
    public var containsSyntheticMedia: Bool

    public init(title: String, description: String = "",
                privacy: YouTubePrivacyStatus = .private,
                madeForKids: Bool = false, publishAt: Date? = nil,
                containsSyntheticMedia: Bool = false) {
        self.title = title
        self.description = description
        self.privacy = privacy
        self.madeForKids = madeForKids
        self.publishAt = publishAt
        self.containsSyntheticMedia = containsSyntheticMedia
    }
}

public struct YouTubeChannel: Equatable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct YouTubeUploadResult: Equatable, Sendable {
    public var videoID: String

    public init(videoID: String) {
        self.videoID = videoID
    }

    public var watchURL: URL {
        URL(string: "https://youtu.be/\(videoID)")!
    }

    public var studioURL: URL {
        URL(string: "https://studio.youtube.com/video/\(videoID)/edit")!
    }
}

public enum YouTubeUploadError: LocalizedError, Equatable {
    case emptyVideo
    case invalidResponse
    case missingUploadSession
    case missingVideoID
    case thumbnailTooLarge
    case api(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .emptyVideo:
            "The rendered video is empty."
        case .invalidResponse:
            "YouTube returned an unreadable response."
        case .missingUploadSession:
            "YouTube did not create an upload session."
        case .missingVideoID:
            "YouTube accepted the upload but did not return a video ID."
        case .thumbnailTooLarge:
            "The thumbnail is larger than YouTube's 2 MB limit."
        case .api(let status, let message):
            "YouTube (\(status)): \(message)"
        }
    }
}

/// Minimal YouTube Data API client with bounded-memory, resumable uploads.
///
/// Uploading in 8 MiB chunks lets the UI report useful progress and lets a
/// transient failure resume from YouTube's acknowledged byte rather than
/// rendering or sending the entire movie again.
public final class YouTubeUploadClient: @unchecked Sendable {
    public static let chunkSize = 8 * 1_024 * 1_024
    private let session: URLSession
    private let apiRoot = URL(string: "https://www.googleapis.com/youtube/v3/")!
    private let uploadRoot = URL(string: "https://www.googleapis.com/upload/youtube/v3/")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func channel(accessToken: String) async throws -> YouTubeChannel {
        var components = URLComponents(
            url: apiRoot.appendingPathComponent("channels"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "mine", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let http = try Self.checked(response, data: data)
        guard (200..<300).contains(http.statusCode) else {
            throw Self.apiError(response: http, data: data)
        }
        struct Envelope: Decodable {
            struct Item: Decodable {
                struct Snippet: Decodable { var title: String }
                var id: String
                var snippet: Snippet
            }
            var items: [Item]
        }
        guard let item = try JSONDecoder().decode(Envelope.self, from: data).items.first else {
            throw YouTubeUploadError.api(
                status: http.statusCode,
                message: "No YouTube channel is available for this Google account.")
        }
        return YouTubeChannel(id: item.id, title: item.snippet.title)
    }

    public func uploadVideo(fileURL: URL, metadata: YouTubeVideoMetadata,
                            accessToken: String,
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws
        -> YouTubeUploadResult {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let total = Int64(values.fileSize ?? 0)
        guard total > 0 else { throw YouTubeUploadError.emptyVideo }

        let startRequest = try Self.resumableStartRequest(
            url: uploadRoot.appendingPathComponent("videos"),
            metadata: metadata, totalBytes: total, accessToken: accessToken)
        let (startData, startResponse) = try await performWithRetry(request: startRequest)
        let startHTTP = try Self.checked(startResponse, data: startData)
        guard (200..<300).contains(startHTTP.statusCode) else {
            throw Self.apiError(response: startHTTP, data: startData)
        }
        guard let location = startHTTP.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: location)
        else { throw YouTubeUploadError.missingUploadSession }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var recoveryAttempts = 0
        progress(0)

        while offset < total {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let requested = min(Self.chunkSize, Int(total - offset))
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                throw YouTubeUploadError.emptyVideo
            }
            let end = offset + Int64(chunk.count) - 1
            let request = Self.uploadChunkRequest(
                url: uploadURL, data: chunk, from: offset, through: end,
                totalBytes: total, accessToken: accessToken)

            do {
                let (data, response) = try await session.data(for: request)
                let http = try Self.checked(response, data: data)
                switch http.statusCode {
                case 200, 201:
                    progress(1)
                    return try Self.decodeUploadResult(data)
                case 308:
                    offset = max(offset, Self.nextOffset(from: http))
                    recoveryAttempts = 0
                    progress(min(0.999, Double(offset) / Double(total)))
                case 500, 502, 503, 504:
                    throw YouTubeUploadError.api(
                        status: http.statusCode,
                        message: "A temporary upload error occurred.")
                default:
                    throw Self.apiError(response: http, data: data)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as YouTubeUploadError {
                if case .api(let status, _) = error,
                   ![500, 502, 503, 504].contains(status) {
                    throw error
                }
                recoveryAttempts += 1
                guard recoveryAttempts <= 5 else { throw error }
                try await backOff(attempt: recoveryAttempts)
                switch try await queryStatus(
                    uploadURL: uploadURL, totalBytes: total, accessToken: accessToken) {
                case .incomplete(let serverOffset):
                    offset = serverOffset
                case .complete(let result):
                    progress(1)
                    return result
                }
                progress(min(0.999, Double(offset) / Double(total)))
            } catch {
                recoveryAttempts += 1
                guard recoveryAttempts <= 5 else { throw error }
                try await backOff(attempt: recoveryAttempts)
                switch try await queryStatus(
                    uploadURL: uploadURL, totalBytes: total, accessToken: accessToken) {
                case .incomplete(let serverOffset):
                    offset = serverOffset
                case .complete(let result):
                    progress(1)
                    return result
                }
                progress(min(0.999, Double(offset) / Double(total)))
            }
        }

        // A lost final response can leave every byte acknowledged. Asking for
        // status returns the completed video's resource instead of uploading
        // a duplicate.
        switch try await queryStatus(
            uploadURL: uploadURL, totalBytes: total, accessToken: accessToken) {
        case .complete(let result):
            progress(1)
            return result
        case .incomplete:
            throw YouTubeUploadError.missingVideoID
        }
    }

    public func uploadCaptions(webVTT: String, videoID: String,
                               language: String, name: String = "Banny Studio captions",
                               accessToken: String) async throws {
        let boundary = "banny-\(UUID().uuidString)"
        let metadata: [String: Any] = [
            "snippet": [
                "videoId": videoID,
                "language": language,
                "name": name,
                "isDraft": false,
            ],
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\nContent-Type: text/vtt; charset=UTF-8\r\n\r\n")
        body.append(Data(webVTT.utf8))
        body.append("\r\n--\(boundary)--\r\n")

        var components = URLComponents(
            url: uploadRoot.appendingPathComponent("captions"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "uploadType", value: "multipart"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        let (data, response) = try await performWithRetry(request: request)
        let http = try Self.checked(response, data: data)
        guard (200..<300).contains(http.statusCode) else {
            throw Self.apiError(response: http, data: data)
        }
    }

    public func setThumbnail(data: Data, mimeType: String, videoID: String,
                             accessToken: String) async throws {
        guard data.count <= 2_000_000 else { throw YouTubeUploadError.thumbnailTooLarge }
        var components = URLComponents(
            url: uploadRoot.appendingPathComponent("thumbnails/set"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "videoId", value: videoID),
            URLQueryItem(name: "uploadType", value: "media"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await performWithRetry(request: request)
        let http = try Self.checked(response, data: responseData)
        guard (200..<300).contains(http.statusCode) else {
            throw Self.apiError(response: http, data: responseData)
        }
    }

    static func resumableStartRequest(url: URL, metadata: YouTubeVideoMetadata,
                                      totalBytes: Int64, accessToken: String) throws -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "part", value: "snippet,status"),
        ]
        let title = YouTubePublishPlan.videoTitle(metadata.title)
        var status: [String: Any] = [
            "privacyStatus": metadata.publishAt == nil ? metadata.privacy.rawValue : "private",
            "selfDeclaredMadeForKids": metadata.madeForKids,
            "containsSyntheticMedia": metadata.containsSyntheticMedia,
        ]
        if let publishAt = metadata.publishAt {
            status["publishAt"] = ISO8601DateFormatter().string(from: publishAt)
        }
        let resource: [String: Any] = [
            "snippet": [
                "title": title.isEmpty ? "Banny show" : title,
                "description": YouTubePublishPlan.videoDescription(metadata.description),
                "categoryId": "22",
            ],
            "status": status,
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: resource)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(String(totalBytes), forHTTPHeaderField: "X-Upload-Content-Length")
        request.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        return request
    }

    static func uploadChunkRequest(url: URL, data: Data, from: Int64,
                                   through: Int64, totalBytes: Int64,
                                   accessToken: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue("bytes \(from)-\(through)/\(totalBytes)",
                         forHTTPHeaderField: "Content-Range")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func nextOffset(from response: HTTPURLResponse) -> Int64 {
        guard let value = response.value(forHTTPHeaderField: "Range"),
              let dash = value.lastIndex(of: "-"),
              let last = Int64(value[value.index(after: dash)...])
        else { return 0 }
        return last + 1
    }

    private enum UploadStatus {
        case incomplete(Int64)
        case complete(YouTubeUploadResult)
    }

    private func queryStatus(uploadURL: URL, totalBytes: Int64,
                             accessToken: String) async throws -> UploadStatus {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.httpBody = Data()
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("bytes */\(totalBytes)", forHTTPHeaderField: "Content-Range")
        let (data, response) = try await performWithRetry(request: request)
        let http = try Self.checked(response, data: data)
        switch http.statusCode {
        case 200, 201:
            return .complete(try Self.decodeUploadResult(data))
        case 308:
            return .incomplete(Self.nextOffset(from: http))
        default:
            throw Self.apiError(response: http, data: data)
        }
    }

    private func performWithRetry(request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0...5 {
            try Task.checkCancellation()
            do {
                let result = try await session.data(for: request)
                if let http = result.1 as? HTTPURLResponse,
                   [500, 502, 503, 504].contains(http.statusCode),
                   attempt < 5 {
                    try await backOff(attempt: attempt + 1)
                    continue
                }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < 5 else { throw error }
                try await backOff(attempt: attempt + 1)
            }
        }
        throw lastError ?? YouTubeUploadError.invalidResponse
    }

    private func backOff(attempt: Int) async throws {
        let seconds = min(16.0, pow(2.0, Double(max(0, attempt - 1))))
        try await Task.sleep(for: .seconds(seconds))
    }

    private static func checked(_ response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeUploadError.invalidResponse
        }
        return http
    }

    private static func decodeUploadResult(_ data: Data) throws -> YouTubeUploadResult {
        struct Resource: Decodable { var id: String }
        guard let resource = try? JSONDecoder().decode(Resource.self, from: data),
              !resource.id.isEmpty
        else { throw YouTubeUploadError.missingVideoID }
        return YouTubeUploadResult(videoID: resource.id)
    }

    private static func apiError(response: HTTPURLResponse, data: Data) -> YouTubeUploadError {
        struct Envelope: Decodable {
            struct Body: Decodable { var message: String? }
            var error: Body?
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        let message = envelope?.error?.message
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        return .api(status: response.statusCode, message: message)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
