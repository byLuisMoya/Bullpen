@testable import BPSessions
import Darwin
import Foundation
import Testing

/// Starts an in-process daemon on a short temp socket path (Unix socket paths are limited to ~104 bytes).
func startServer() throws -> (SessionServer, SessionClient) {
    let id = UUID().uuidString.prefix(8)
    let socket = "/tmp/bp-\(id).sock"
    let logs = FileManager.default.temporaryDirectory.appendingPathComponent("bp-logs-\(id)")
    let server = SessionServer(socketPath: socket, logDirectory: logs, build: "test")
    server.idleExit = nil
    try server.start()
    return (server, try SessionClient.connect(socketPath: socket))
}

/// Collects output for `session` until `predicate` holds on the accumulated text, or times out.
func collect(_ client: SessionClient, session: String, timeout: Double = 5, until predicate: @escaping @Sendable (String, Int32?) -> Bool) async -> (String, Int32?) {
    await withTaskGroup(of: (String, Int32?).self) { group in
        group.addTask {
            var text = ""
            var status: Int32?
            for await event in client.events {
                switch event {
                case let .snapshot(id, data) where id == session, let .output(id, data) where id == session:
                    text += String(decoding: data, as: UTF8.self)
                case let .exited(id, code) where id == session:
                    status = code
                default: break
                }
                if predicate(text, status) { break }
            }
            return (text, status)
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeout))
            return ("<timeout>", nil)
        }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
}

@Suite(.serialized) struct SessionServerTests {
    @Test func handshake() async throws {
        let (server, client) = try startServer()
        defer { client.close(); server.stop() }
        let hello = try await client.hello()
        #expect(hello.protocolVersion == SessionProtocol.version)
        #expect(hello.build == "test")
    }

    @Test func runsCommandAndReportsExitCode() async throws {
        let (server, client) = try startServer()
        defer { client.close(); server.stop() }
        let info = try await client.create(SessionSpec(id: "s1", cwd: NSTemporaryDirectory(), command: "echo hello-bullpen; exit 3"))
        #expect(info.isRunning)
        try await client.attach("s1")
        let (text, status) = await collect(client, session: "s1") { _, status in status != nil }
        #expect(text.contains("hello-bullpen"))
        #expect(status == 3)
        #expect(try await client.list().first?.exitStatus == 3)
    }

    @Test func forwardsInputAndRunsInCwd() async throws {
        let (server, client) = try startServer()
        defer { client.close(); server.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bp-cwd-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await client.create(SessionSpec(id: "s2", cwd: dir.path, command: "read line; echo \"got:$line pwd:$(pwd -P)\""))
        try await client.attach("s2")
        client.input("s2", Data("ping\n".utf8))
        let (text, status) = await collect(client, session: "s2") { _, status in status != nil }
        #expect(text.contains("got:ping"))
        #expect(text.contains(dir.resolvingSymlinksInPath().path))
        #expect(status == 0)
    }

    @Test func replaysOutputToLateAttachers() async throws {
        let (server, client) = try startServer()
        defer { client.close(); server.stop() }
        _ = try await client.create(SessionSpec(id: "s3", cwd: NSTemporaryDirectory(), command: "echo before-attach; sleep 30"))
        try await Task.sleep(for: .milliseconds(800))
        try await client.attach("s3")
        let (text, _) = await collect(client, session: "s3") { text, _ in text.contains("before-attach") }
        #expect(text.contains("before-attach"))
        try await client.kill("s3", signal: SIGTERM)
        let (_, status) = await collect(client, session: "s3") { _, status in status != nil }
        #expect(status == 128 + SIGTERM)
    }

    @Test func sessionsSurviveClientDisconnect() async throws {
        let (server, first) = try startServer()
        defer { server.stop() }
        _ = try await first.create(SessionSpec(id: "s4", cwd: NSTemporaryDirectory(), command: "sleep 30"))
        first.close()
        let second = try SessionClient.connect(socketPath: server.socketPath)
        defer { second.close() }
        let sessions = try await second.list()
        #expect(sessions.map(\.id) == ["s4"])
        #expect(sessions.first?.isRunning == true)
        try await second.kill("s4", signal: SIGKILL)
    }

    @Test func resizeReachesTheProgram() async throws {
        let (server, client) = try startServer()
        defer { client.close(); server.stop() }
        _ = try await client.create(SessionSpec(id: "s5", cwd: NSTemporaryDirectory(), command: "read _; stty size", cols: 80, rows: 24))
        try await client.attach("s5")
        client.resize("s5", cols: 132, rows: 50)
        try await Task.sleep(for: .milliseconds(200))
        client.input("s5", Data("\n".utf8))
        let (text, _) = await collect(client, session: "s5") { _, status in status != nil }
        #expect(text.contains("50 132"))
    }

    @Test func rejectsDuplicateRunningSession() async throws {
        let (server, client) = try startServer()
        defer { client.close(); server.stop() }
        _ = try await client.create(SessionSpec(id: "dup", cwd: NSTemporaryDirectory(), command: "sleep 30"))
        await #expect(throws: SessionError.self) {
            _ = try await client.create(SessionSpec(id: "dup", cwd: NSTemporaryDirectory(), command: "sleep 30"))
        }
        try await client.kill("dup", signal: SIGKILL)
    }

    @Test func lineBufferSplitsFrames() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("a\nb".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["a"])
        #expect(buffer.append(Data("c\n\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["bc", ""])
    }
}
