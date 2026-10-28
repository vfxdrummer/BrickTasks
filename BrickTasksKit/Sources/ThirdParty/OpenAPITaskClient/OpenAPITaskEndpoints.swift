public import Domain
public import Foundation
public import Networking
internal import OpenAPIRuntime
internal import OpenAPIURLSession

/// `TaskEndpoints` backed by swift-openapi-generator. The only place in the app that knows
/// about OpenAPI types; everything it returns or throws is a domain type or `RemoteDataSourceError`.
public struct OpenAPITaskEndpoints: TaskEndpoints, SandboxReset {
    private let client: Client

    /// `session` is injectable so tests can stub HTTP with a `URLProtocol`.
    public init(baseURL: URL, session: URLSession = .shared) {
        self.client = Client(
            serverURL: baseURL,
            // The server sends `2026-10-28T21:04:49.125Z`; the default transcoder rejects the fraction.
            configuration: Configuration(dateTranscoder: .iso8601WithFractionalSeconds),
            transport: URLSessionTransport(configuration: .init(session: session))
        )
    }

    public func listTasks(_ query: TaskQuery, offset: Int, limit: Int) async throws(RemoteDataSourceError) -> TaskPage {
        let output = try await call {
            try await client.listTasks(query: .init(
                date: query.day?.description,
                workOrderId: query.workOrderID,
                status: try query.status.map(TaskMapper.wireStatus),
                offset: offset,
                limit: limit
            ))
        }
        switch output {
        case .ok(let ok):
            let page = try map { try ok.body.json }
            return TaskPage(items: try page.items.map(TaskMapper.task), total: page.total, offset: page.offset)
        case .badRequest(let r): throw ErrorMapper.error(status: 400, body: try? r.body.json)
        case .notFound(let r): throw ErrorMapper.error(status: 404, body: try? r.body.json)
        case .tooManyRequests(let r): throw .rateLimited(retryAfter: r.headers.retryAfter.map(Double.init))
        case .default(let status, let r): throw ErrorMapper.error(status: status, body: try? r.body.json)
        }
    }

    public func getTask(id: String) async throws(RemoteDataSourceError) -> WorkTask {
        let output = try await call { try await client.getTask(path: .init(id: id)) }
        switch output {
        case .ok(let ok): return try TaskMapper.task(try map { try ok.body.json })
        case .notFound(let r): throw ErrorMapper.error(status: 404, body: try? r.body.json)
        case .tooManyRequests(let r): throw .rateLimited(retryAfter: r.headers.retryAfter.map(Double.init))
        case .default(let status, let r): throw ErrorMapper.error(status: status, body: try? r.body.json)
        }
    }

    public func createAction(_ action: TaskActionRequest) async throws(RemoteDataSourceError) -> ActionReceipt {
        let body: Components.Schemas.ActionRequest = switch action {
        case .complete(let id):
            .complete(.init(taskId: id, kind: .complete))
        case .reschedule(let id, let day):
            .reschedule(.init(taskId: id, kind: .reschedule, date: day.description))
        }
        let output = try await call { try await client.createAction(body: .json(body)) }
        switch output {
        case .created(let created): return try TaskMapper.receipt(try map { try created.body.json })
        case .badRequest(let r): throw ErrorMapper.error(status: 400, body: try? r.body.json)
        case .notFound(let r): throw ErrorMapper.error(status: 404, body: try? r.body.json)
        case .conflict(let r): throw ErrorMapper.error(status: 409, body: try? r.body.json)
        case .tooManyRequests(let r): throw .rateLimited(retryAfter: r.headers.retryAfter.map(Double.init))
        case .default(let status, let r): throw ErrorMapper.error(status: status, body: try? r.body.json)
        }
    }

    public func resetSandbox() async throws(RemoteDataSourceError) {
        switch try await call({ try await client.resetSandbox() }) {
        case .noContent: return
        case .notFound(let r): throw ErrorMapper.error(status: 404, body: try? r.body.json)
        case .tooManyRequests(let r): throw .rateLimited(retryAfter: r.headers.retryAfter.map(Double.init))
        case .default(let status, let r): throw ErrorMapper.error(status: status, body: try? r.body.json)
        }
    }

    private func call<T>(_ operation: () async throws -> T) async throws(RemoteDataSourceError) -> T {
        do { return try await operation() } catch { throw ErrorMapper.error(from: error) }
    }

    private func map<T>(_ operation: () throws -> T) throws(RemoteDataSourceError) -> T {
        do { return try operation() } catch { throw .invalidResponse(String(describing: error)) }
    }
}
