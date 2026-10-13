import Darwin
import Foundation

/// Starts `bpd` in its own session so it outlives whoever launched it (the app or the CLI).
public enum DaemonLauncher {
    /// Connects to bpd, launching `bpdPath` first if nothing answers.
    public static func connect(socketPath: String = SessionProtocol.defaultSocketPath, bpdPath: String) async throws -> SessionClient {
        if let client = try? SessionClient.connect(socketPath: socketPath) { return client }
        try launch(bpdPath, socketPath: socketPath)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if let client = try? SessionClient.connect(socketPath: socketPath) { return client }
        }
        throw SessionError(message: "No se pudo arrancar bpd")
    }

    /// Replaces the running bpd with the one at `bpdPath` without closing its terminals (the new one
    /// takes them over), then returns a client of the new one. Needs a daemon that speaks protocol 3.
    public static func takeOver(socketPath: String = SessionProtocol.defaultSocketPath, bpdPath: String, expectBuild: String) async throws -> SessionClient {
        try launch(bpdPath, socketPath: socketPath, extra: ["--takeover"])
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if let client = try? SessionClient.connect(socketPath: socketPath), let hello = try? await client.hello(), hello.build == expectBuild {
                return client
            }
        }
        throw SessionError(message: "El nuevo bpd no ha tomado el relevo")
    }

    public static func launch(_ path: String, socketPath: String = SessionProtocol.defaultSocketPath, extra: [String] = []) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw SessionError(message: "No encuentro bpd en \(path)") }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var args = [path]
        if socketPath != SessionProtocol.defaultSocketPath { args += ["--socket", socketPath] }
        args += extra
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        // Reap it if it exits while we're alive, so it never lingers as a zombie.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }
}
