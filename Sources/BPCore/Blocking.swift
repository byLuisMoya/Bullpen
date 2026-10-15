import Foundation

/// Runs blocking work (reading a process to its end, waiting for it) on a GCD thread. Swift
/// concurrency has one thread per core and expects none of them to block: a few held by slow
/// commands stall every `await` in the app, the UI's included.
public func offPool<T: Sendable>(qos: DispatchQoS.QoSClass = .utility, _ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
    }
}

/// `offPool` for work that throws.
public func offPool<T: Sendable>(qos: DispatchQoS.QoSClass = .utility, _ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: qos).async { continuation.resume(with: Result { try work() }) }
    }
}
