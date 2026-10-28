import Domain
import Foundation
import Networking
import OpenAPITaskClient
import Testing

private let baseURL = URL(string: "https://sandbox.test/c/abc123")!
private func makeEndpoints() -> OpenAPITaskEndpoints {
    OpenAPITaskEndpoints(baseURL: baseURL, session: StubURLProtocol.session())
}

private let taskJSON = """
{"id":"task_1","workOrder":{"id":"wo_1","reference":"WO-10421","customer":"Halcyon Coffee"},
 "kind":"pack","sequence":2,"status":"pending","date":"2026-10-28","time":"10:30",
 "allowedActions":["reschedule"],"createdAt":"2026-10-27T12:40:00.000Z"}
"""

private func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

private func jsonObject(_ data: Data?) throws -> NSDictionary {
    let data = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

@Suite(.serialized)
struct OpenAPITaskEndpointsTests {
    // MARK: Requests: the server rejects unknown params and fields, so these are exact.

    @Test func listBuildsExactQueryUnderTheBasePath() async throws {
        StubURLProtocol.stub(.http(status: 200, body: try fixture("tasks_empty_page")))
        _ = try await makeEndpoints().listTasks(TaskQuery(day: CalendarDay("2026-10-28")), offset: 50, limit: 50)

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.method == "GET")
        #expect(request.url.path == "/c/abc123/tasks")
        #expect(query(request.url) == ["date": "2026-10-28", "offset": "50", "limit": "50"])
    }

    @Test func listSendsWorkOrderAndStatusFilters() async throws {
        StubURLProtocol.stub(.http(status: 200, body: try fixture("tasks_empty_page")))
        _ = try await makeEndpoints().listTasks(TaskQuery(workOrderID: "wo_9", status: .pending), offset: 0, limit: 50)

        #expect(query(try #require(StubURLProtocol.lastRequest).url) == ["workOrderId": "wo_9", "status": "pending", "offset": "0", "limit": "50"])
    }

    @Test func listRejectsUnknownStatusFilterWithoutCallingTheServer() async throws {
        StubURLProtocol.stub(.http(status: 200, body: try fixture("tasks_empty_page")))
        await #expect(throws: APIError.badRequest(message: "Cannot filter by unknown status \"blocked\"")) {
            try await makeEndpoints().listTasks(TaskQuery(status: .unknown("blocked")), offset: 0, limit: 50)
        }
        #expect(StubURLProtocol.lastRequest == nil)
    }

    @Test func getTaskUsesIdInPath() async throws {
        StubURLProtocol.stub(.http(status: 200, body: json(taskJSON)))
        _ = try await makeEndpoints().getTask(id: "task_1")

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.method == "GET")
        #expect(request.url.path == "/c/abc123/tasks/task_1")
        #expect(request.url.query == nil)
    }

    @Test func completeSendsOnlyTaskIdAndKind() async throws {
        StubURLProtocol.stub(.http(status: 201, body: json(#"{"id":"act_1","taskId":"task_1","kind":"complete","appliedAt":"2026-10-28T21:04:49.125Z"}"#)))
        _ = try await makeEndpoints().createAction(.complete(taskID: "task_1"))

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.method == "POST")
        #expect(request.url.path == "/c/abc123/actions")
        #expect(try jsonObject(request.body) == ["taskId": "task_1", "kind": "complete"])
    }

    @Test func rescheduleSendsTaskIdKindAndDate() async throws {
        StubURLProtocol.stub(.http(status: 201, body: json(#"{"id":"act_2","taskId":"task_1","kind":"reschedule","date":"2026-10-30","appliedAt":"2026-10-28T21:04:50.122Z"}"#)))
        _ = try await makeEndpoints().createAction(.reschedule(taskID: "task_1", day: CalendarDay("2026-10-30")!))

        #expect(try jsonObject(StubURLProtocol.lastRequest?.body) == ["taskId": "task_1", "kind": "reschedule", "date": "2026-10-30"])
    }

    @Test func resetPostsToResetAndAcceptsNoContent() async throws {
        StubURLProtocol.stub(.http(status: 204, headers: [:], body: Data()))
        try await makeEndpoints().resetSandbox()

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.method == "POST")
        #expect(request.url.path == "/c/abc123/reset")
    }

    @Test func resetOnExpiredSandboxIsNotFound() async throws {
        StubURLProtocol.stub(.http(status: 404, body: json(#"{"error":"not_found","message":"Not found"}"#)))
        await #expect(throws: APIError.notFound(message: "Not found")) { try await makeEndpoints().resetSandbox() }
    }

    // MARK: Responses

    @Test func decodesARealSandboxPage() async throws {
        StubURLProtocol.stub(.http(status: 200, body: try fixture("tasks_page")))
        let page = try await makeEndpoints().listTasks(TaskQuery(), offset: 0, limit: 50)

        #expect(page.total == 17)
        #expect(page.offset == 0)
        #expect(page.items.count == 17)
        let first = try #require(page.items.first)
        #expect(first.id == "task_GQMTYW593YA93B3Y3XFDXHGHE1")
        #expect(first.workOrder == WorkOrder(id: "wo_KZ71EBMA9DJHG70E6XYXMRNB1T", reference: "WO-10456", customer: "Halcyon Coffee"))
        #expect(first.kind == .pick)
        #expect(first.sequence == 1)
        #expect(first.status == .pending)
        #expect(first.day == CalendarDay("2026-10-28"))
        #expect(first.time == WallClockTime("00:00"))
        #expect(first.allowedActions == [.complete, .reschedule])
        #expect(first.createdAt == (try Date("2026-10-27T09:32:00Z", strategy: .iso8601)))
    }

    @Test func doneTaskHasNoAllowedActions() async throws {
        StubURLProtocol.stub(.http(status: 200, body: try fixture("tasks_page")))
        let page = try await makeEndpoints().listTasks(TaskQuery(), offset: 0, limit: 50)

        let done = page.items.filter { $0.status == .done }
        #expect(!done.isEmpty)
        #expect(done.allSatisfy { $0.allowedActions.isEmpty })
    }

    @Test func decodesFractionalSecondTimestampsInReceipts() async throws {
        StubURLProtocol.stub(.http(status: 201, body: json(#"{"id":"act_2","taskId":"task_1","kind":"reschedule","date":"2026-10-30","appliedAt":"2026-10-28T21:04:50.122Z"}"#)))
        let receipt = try await makeEndpoints().createAction(.reschedule(taskID: "task_1", day: CalendarDay("2026-10-30")!))

        #expect(receipt == ActionReceipt(
            id: "act_2", taskID: "task_1", kind: .reschedule, day: CalendarDay("2026-10-30"),
            appliedAt: Date(timeIntervalSince1970: 1_793_221_490.122)
        ))
    }

    @Test func toleratesNewFieldsAndEnumValues() async throws {
        let future = taskJSON
            .replacingOccurrences(of: #""kind":"pack""#, with: #""kind":"returns""#)
            .replacingOccurrences(of: #""status":"pending""#, with: #""status":"blocked""#)
            .replacingOccurrences(of: #""allowedActions":["reschedule"]"#, with: #""allowedActions":["reschedule","escalate"],"priority":"high""#)
        StubURLProtocol.stub(.http(status: 200, body: json(future)))
        let task = try await makeEndpoints().getTask(id: "task_1")

        #expect(task.kind == .unknown("returns"))
        #expect(task.status == .unknown("blocked"))
        #expect(task.allowedActions == [.reschedule, .unknown("escalate")])
    }

    @Test(arguments: [
        (#""date":"2026-10-28""#, #""date":"2026-02-30""#),
        (#""time":"10:30""#, #""time":"25:00""#),
    ])
    func malformedDayOrTimeIsAnInvalidResponse(_ replacement: (String, String)) async throws {
        StubURLProtocol.stub(.http(status: 200, body: json(taskJSON.replacingOccurrences(of: replacement.0, with: replacement.1))))
        await #expect {
            try await makeEndpoints().getTask(id: "task_1")
        } throws: { error in
            if case .invalidResponse = error as? APIError { true } else { false }
        }
    }

    @Test func missingRequiredFieldIsAnInvalidResponse() async throws {
        StubURLProtocol.stub(.http(status: 200, body: json(taskJSON.replacingOccurrences(of: #""sequence":2,"#, with: ""))))
        await #expect {
            try await makeEndpoints().getTask(id: "task_1")
        } throws: { error in
            if case .invalidResponse = error as? APIError { true } else { false }
        }
    }

    // MARK: Errors

    @Test func notFoundCarriesServerMessage() async throws {
        StubURLProtocol.stub(.http(status: 404, body: try fixture("error_not_found")))
        await #expect(throws: APIError.notFound(message: "No such task")) {
            try await makeEndpoints().getTask(id: "task_nope")
        }
    }

    @Test func conflictMapsToActionNotAllowed() async throws {
        StubURLProtocol.stub(.http(status: 409, body: json(#"{"error":"action_not_allowed","message":"pack cannot be completed until pick is done"}"#)))
        await #expect(throws: APIError.actionNotAllowed(message: "pack cannot be completed until pick is done")) {
            try await makeEndpoints().createAction(.complete(taskID: "task_1"))
        }
    }

    @Test func badRequestCarriesServerMessage() async throws {
        StubURLProtocol.stub(.http(status: 400, body: json(#"{"error":"invalid_request","message":"Unknown query parameter: foo"}"#)))
        await #expect(throws: APIError.badRequest(message: "Unknown query parameter: foo")) {
            try await makeEndpoints().listTasks(TaskQuery(), offset: 0, limit: 50)
        }
    }

    @Test func rateLimitedReadsRetryAfterHeader() async throws {
        StubURLProtocol.stub(.http(
            status: 429,
            headers: ["Content-Type": "application/json; charset=utf-8", "Retry-After": "1"],
            body: json(#"{"error":"rate_limited","message":"Too many requests"}"#)
        ))
        await #expect(throws: APIError.rateLimited(retryAfter: 1)) {
            try await makeEndpoints().listTasks(TaskQuery(), offset: 0, limit: 50)
        }
    }

    @Test func serverErrorWithJSONBody() async throws {
        StubURLProtocol.stub(.http(status: 503, body: json(#"{"error":"unavailable","message":"Try again"}"#)))
        await #expect(throws: APIError.server(status: 503, message: "Try again")) {
            try await makeEndpoints().getTask(id: "task_1")
        }
    }

    @Test func serverErrorWithHTMLBodyFromTheCDN() async throws {
        StubURLProtocol.stub(.http(status: 502, headers: ["Content-Type": "text/html"], body: json("<html>Bad gateway</html>")))
        await #expect(throws: APIError.server(status: 502, message: nil)) {
            try await makeEndpoints().getTask(id: "task_1")
        }
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed])
    func failuresBeforeSendingAreNotConnected(_ code: URLError.Code) async {
        StubURLProtocol.stub(.failure(code))
        await #expect(throws: APIError.notConnected) {
            try await makeEndpoints().createAction(.complete(taskID: "task_1"))
        }
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost])
    func failuresMidRequestAreInterrupted(_ code: URLError.Code) async {
        // For an action, this means "may have landed": the repository has to reconcile.
        StubURLProtocol.stub(.failure(code))
        await #expect(throws: APIError.connectionInterrupted) {
            try await makeEndpoints().createAction(.complete(taskID: "task_1"))
        }
    }
}
