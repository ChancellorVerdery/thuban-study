import Foundation

/// The HTTP layer under `ClaudeClient` and `OAuthFlow`. The body is delivered as a stream of byte chunks so
/// server-sent events can be parsed as they arrive; tests inject a mock.
public protocol ClaudeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)
}

/// `URLSession`-backed transport. Chunks are flushed at every newline so SSE events surface with low latency.
public struct URLSessionTransport: ClaudeTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw ThubanError.cancelled
        } catch {
            throw ThubanError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ThubanError.network("The server did not return an HTTP response.")
        }
        return (Self.chunked(bytes), http)
    }

    private static func chunked(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 0x0A {
                            continuation.yield(buffer)
                            buffer = Data()
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ThubanError.cancelled)
                } catch {
                    continuation.finish(throwing: ThubanError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AsyncThrowingStream where Element == Data, Failure == Error {
    /// Drains the stream into one `Data`.
    func collect() async throws -> Data {
        var out = Data()
        for try await chunk in self { out.append(chunk) }
        return out
    }
}
