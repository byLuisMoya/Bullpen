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

    public static func launch(_ path: String, socketPath: String = SessionProtocol.defaultSocketPath) throws {
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
