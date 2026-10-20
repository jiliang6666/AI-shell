import Foundation

enum AIHTTPStreamTimeoutPolicy {
    /// Maximum time to wait for a response or the next byte in a model stream.
    /// URLSession resets this timer whenever new data arrives, so a slow but
    /// active SSE response can continue while a stalled connection fails.
    static let requestIdleInterval: TimeInterval = 120
}

private enum AIHTTPStreamSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = AIHTTPStreamTimeoutPolicy.requestIdleInterval
        // A whole model stream may legitimately run for a long time. The
        // request idle timeout above bounds stalls without imposing a total
        // response duration limit.
        configuration.timeoutIntervalForResource = .infinity
        return URLSession(configuration: configuration)
    }()
}

struct AIHTTPStreamResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var bytes: AsyncThrowingStream<UInt8, any Error>

    func value(forHTTPHeaderField name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

protocol AIHTTPStreamTransport: Sendable {
    func stream(for request: URLRequest) async throws -> AIHTTPStreamResponse
}

struct URLSessionAIHTTPStreamTransport: AIHTTPStreamTransport {
    func stream(for request: URLRequest) async throws -> AIHTTPStreamResponse {
        let (bytes, response) = try await AIHTTPStreamSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ModelAPIError.badResponse("模型服务没有返回有效的 HTTP 响应。")
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        let stream = AsyncThrowingStream<UInt8, any Error> { continuation in
            let task = Task {
                do {
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        continuation.yield(byte)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return AIHTTPStreamResponse(statusCode: response.statusCode, headers: headers, bytes: stream)
    }
}
