import Foundation

/// Bounded URL loading policy shared by participant-side and CLI HTTP clients.
///
/// A delegate supplied for every task declines redirects even when the injected
/// session was created with a permissive delegate. The explicit timeout race is
/// intentional: custom URL protocols and unusual session configurations do not
/// always honor `URLRequest.timeoutInterval` promptly. Response bytes are
/// consumed incrementally and the task is abandoned at the first byte over the
/// configured cap.
public enum BannyLiveURLLoader {
    public struct Payload: @unchecked Sendable {
        public let data: Data
        public let response: URLResponse

        public init(data: Data, response: URLResponse) {
            self.data = data
            self.response = response
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case timedOut
        case responseTooLarge(actual: Int64, limit: Int)
    }

    public static func data(
        for request: URLRequest,
        session: URLSession,
        timeout: TimeInterval,
        maximumResponseBytes: Int
    ) async throws -> Payload {
        precondition(timeout > 0 && timeout.isFinite)
        precondition(maximumResponseBytes >= 0)

        return try await withThrowingTaskGroup(of: Payload.self) { group in
            group.addTask {
                let (bytes, response) = try await session.bytes(
                    for: request,
                    delegate: NoRedirectDelegate.shared)
                return try await withTaskCancellationHandler {
                    if response.expectedContentLength > Int64(maximumResponseBytes) {
                        bytes.task.cancel()
                        throw Error.responseTooLarge(
                            actual: response.expectedContentLength,
                            limit: maximumResponseBytes)
                    }

                    var data = Data()
                    if response.expectedContentLength > 0 {
                        data.reserveCapacity(min(
                            maximumResponseBytes,
                            Int(response.expectedContentLength)))
                    }
                    for try await byte in bytes {
                        guard data.count < maximumResponseBytes else {
                            bytes.task.cancel()
                            throw Error.responseTooLarge(
                                actual: Int64(data.count) + 1,
                                limit: maximumResponseBytes)
                        }
                        data.append(byte)
                    }
                    return Payload(data: data, response: response)
                } onCancel: {
                    bytes.task.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw Error.timedOut
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
