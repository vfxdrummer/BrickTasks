import Foundation
import Testing

/// Intercepts every request on a session built with `StubURLProtocol.session()`.
/// The handler is global, so suites that use it must be `.serialized`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(status: Int, headers: [String: String] = ["Content-Type": "application/json"], body: Data)
        case failure(URLError.Code)
    }

    struct Recorded: Sendable {
        let method: String
        let url: URL
        let body: Data?
    }

    nonisolated(unsafe) private static var reply: Reply = .failure(.unknown)
    nonisolated(unsafe) private(set) static var requests: [Recorded] = []
    private static let lock = NSLock()

    static func stub(_ reply: Reply) {
        lock.withLock {
            Self.reply = reply
            Self.requests = []
        }
    }

    static var lastRequest: Recorded? { lock.withLock { requests.last } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.requests.append(Recorded(method: request.httpMethod ?? "", url: request.url!, body: Self.body(of: request)))
            return Self.reply
        }
        switch reply {
        case let .http(status, headers, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    /// URLSession hands bodies to protocols as streams, not `httpBody`.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Read to EOF: on iOS `hasBytesAvailable` can be false before the first read.
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func json(_ string: String) -> Data { Data(string.utf8) }
