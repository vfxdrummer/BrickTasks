/// Injected so retry delays are instant and assertable in tests.
public protocol Sleeper: Sendable {
    func sleep(seconds: Double) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
