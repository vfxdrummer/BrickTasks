import Domain
import Foundation
import Network

/// `Connectivity` backed by `NWPathMonitor`.
final class NetworkPathConnectivity: Connectivity, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.publish(path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "NetworkPathConnectivity"))
    }

    deinit { monitor.cancel() }

    var isOnline: Bool { lock.withLock { online } }

    func updates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        lock.withLock {
            continuations[id] = continuation
            continuation.yield(online)
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    private func publish(_ isOnline: Bool) {
        let listeners: [AsyncStream<Bool>.Continuation] = lock.withLock {
            guard online != isOnline else { return [] }
            online = isOnline
            return Array(continuations.values)
        }
        for listener in listeners { listener.yield(isOnline) }
    }
}

/// For UI-test launches: connectivity that never changes.
struct FixedConnectivity: Connectivity {
    let isOnline: Bool
    func updates() -> AsyncStream<Bool> {
        let online = isOnline
        return AsyncStream { $0.yield(online) }
    }
}
