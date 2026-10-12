import Darwin
import Foundation
import os

public struct SessionError: Error, LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
    public init(message: String) { self.message = message }
}

/// Connection to `bpd`. Requests are async; terminal output arrives through `events`.
public final class SessionClient: @unchecked Sendable {
    public let events: AsyncStream<ServerMessage>
    private let eventsContinuation: AsyncStream<ServerMessage>.Continuation
    private let fd: Int32
    private let queue = DispatchQueue(label: "bpd.client")
    private var readSource: DispatchSourceRead?
    private var writer: FDWriter!
    private var lines = LineBuffer()
    private var nextRequest = 1
    private var pending: [Int: CheckedContinuation<ServerMessage, Error>] = [:]
    private var closed = false

    public static func connect(socketPath: String = SessionProtocol.defaultSocketPath) throws -> SessionClient {
        SessionClient(fd: try UnixSocket.connect(to: socketPath))
    }

    private init(fd: Int32) {
        self.fd = fd
        (events, eventsContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        queue.sync {
            writer = FDWriter(fd: fd, queue: queue)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.resume()
            readSource = source
        }
    }

    deinit { close() }

    // MARK: Requests

    public func hello() async throws -> (protocolVersion: Int, build: String, pid: Int32) {
        guard case let .hello(_, version, build, pid) = try await request({ .hello(request: $0, protocolVersion: SessionProtocol.version) }) else {
            throw SessionError(message: "unexpected reply to hello")
        }
        return (version, build, pid)
    }

    public func create(_ spec: SessionSpec) async throws -> SessionInfo {
        guard case let .created(_, info) = try await request({ .create(request: $0, spec: spec) }) else {
            throw SessionError(message: "unexpected reply to create")
        }
        return info
    }

    public func list() async throws -> [SessionInfo] {
        guard case let .sessions(_, sessions) = try await request({ .list(request: $0) }) else {
            throw SessionError(message: "unexpected reply to list")
        }
        return sessions
    }

    /// After this returns, `events` delivers a `snapshot` for the session followed by live `output`.
    public func attach(_ session: String) async throws {
        _ = try await request { .attach(request: $0, session: session) }
    }

    public func kill(_ session: String, signal: Int32 = SIGHUP) async throws {
        _ = try await request { .kill(request: $0, session: session, signal: signal) }
    }

    public func remove(_ session: String) async throws {
        _ = try await request { .remove(request: $0, session: session) }
    }

    public func reportAgentEvent(_ session: String, _ activity: AgentActivity) async throws {
        _ = try await request { .agentEvent(request: $0, session: session, activity: activity) }
    }

    public func shutdown() async throws {
        _ = try await request { .shutdown(request: $0) }
    }

    /// Types `text` into a terminal app as one message, then Enter. If the program enabled bracketed
    /// paste, newlines are kept inside the paste; otherwise the text goes as a single line so an
    /// early newline can't submit half of it.
    public func sendMessage(_ session: String, _ text: String) async throws {
        let bracketed = try await list().first { $0.id == session }?.bracketedPaste == true
        if bracketed {
            input(session, Data(("\u{1B}[200~" + text + "\u{1B}[201~").utf8))
        } else {
            input(session, Data(text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ").utf8))
        }
        try await Task.sleep(for: .milliseconds(150))
        input(session, Data("\r".utf8))
        // Round-trip so both writes are flushed before the caller moves on (or exits).
        _ = try await list()
    }

    // MARK: Fire and forget

    public func detach(_ session: String) { send(.detach(session: session)) }
    public func input(_ session: String, _ data: Data) { send(.input(session: session, data: data)) }
    public func resize(_ session: String, cols: UInt16, rows: UInt16) {
        send(.resize(session: session, cols: cols, rows: rows))
    }

    public func close() {
        queue.sync { closeLocked(SessionError(message: "connection closed")) }
    }

    // MARK: Plumbing

    private func request(_ make: @escaping (Int) -> ClientMessage) async throws -> ServerMessage {
        let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ServerMessage, Error>) in
            queue.async { [self] in
                guard !closed else {
                    continuation.resume(throwing: SessionError(message: "connection closed"))
                    return
                }
                let id = nextRequest
                nextRequest += 1
                pending[id] = continuation
                write(make(id))
            }
        }
        if case let .error(_, message) = reply { throw SessionError(message: message) }
        return reply
    }

    private func send(_ message: ClientMessage) {
        queue.async { [self] in write(message) }
    }

    private func write(_ message: ClientMessage) {
        guard !closed, let frame = try? Wire.frame(message) else { return }
        if !writer.write(frame) { closeLocked(SessionError(message: "connection lost")) }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                for line in lines.append(Data(buffer[0..<n])) {
                    guard let message = try? Wire.decoder.decode(ServerMessage.self, from: line) else { continue }
                    deliver(message)
                }
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                return
            } else {
                closeLocked(SessionError(message: "daemon disconnected"))
                return
            }
        }
    }

    private func deliver(_ message: ServerMessage) {
        let request: Int? = switch message {
        case let .hello(r, _, _, _), let .created(r, _), let .sessions(r, _), let .ok(r), let .error(r, _): r
        case .snapshot, .output, .exited, .activity: nil
        }
        if let request {
            pending.removeValue(forKey: request)?.resume(returning: message)
        } else {
            eventsContinuation.yield(message)
        }
    }

    private func closeLocked(_ error: Error) {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        writer.cancel()
        Darwin.close(fd)
        pending.values.forEach { $0.resume(throwing: error) }
        pending.removeAll()
        eventsContinuation.finish()
    }
}
