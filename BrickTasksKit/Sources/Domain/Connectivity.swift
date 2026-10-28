/// Whether the device currently has a usable network path. A hint only: requests can still fail
/// while this says online, so callers must also handle `APIError.notConnected`.
public protocol Connectivity: Sendable {
    var isOnline: Bool { get async }
    /// Emits the current value on subscription, then every change.
    func updates() -> AsyncStream<Bool>
}
