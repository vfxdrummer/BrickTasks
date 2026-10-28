/// Sandbox-only: regenerate the server's data. Kept out of `TaskAPI` because production has no such call.
public protocol SandboxReset: Sendable {
    func resetSandbox() async throws(APIError)
}
