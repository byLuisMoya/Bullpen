import Darwin
import Foundation
import os

/// The core of `bpd`: owns PTY sessions so agents keep running while the app is closed or updated.
/// All state lives on one serial queue.
public final class SessionServer: @unchecked Sendable {
    public let socketPath: String
    public let logDirectory: URL
    public let build: String
    /// Recent output kept in memory per session and replayed on attach. Full history goes to disk.
    public var replayBytes = 1_048_576
    /// The daemon exits after this long with no running sessions and no clients. nil = never.
    public var idleExit: TimeInterval? = 600

    let queue = DispatchQueue(label: "bpd.server")
    private let log = Logger(subsystem: "com.byluismoya.Bullpen", category: "bpd")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var sessions: [String: Session] = [:]
    private var lastActivity = Date()
    private var idleTimer: DispatchSourceTimer?
    public var onExit: (@Sendable () -> Void)?

    public init(socketPath: String, logDirectory: URL, build: String) {
        self.socketPath = socketPath
        self.logDirectory = logDirectory
        self.build = build
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        listenFD = try UnixSocket.listen(at: socketPath)
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.resume()
        acceptSource = source

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.checkIdle() }
        timer.resume()
        idleTimer = timer
        log.info("bpd \(self.build, privacy: .public) listening on \(self.socketPath, privacy: .public)")
    }

    /// Stops listening and drops clients. Running sessions are hung up (SIGHUP), like closing a terminal window.
    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            idleTimer?.cancel()
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            unlink(socketPath)
            clients.values.forEach { $0.close() }
            clients.removeAll()
            for session in sessions.values where session.info.isRunning {
                kill(session.info.pid, SIGHUP)
            }
        }
    }

    // MARK: Clients

    private func acceptClients() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            UnixSocket.configure(fd)
            let client = Client(fd: fd, queue: queue)
            client.onMessage = { [weak self, weak client] message in
                guard let self, let client else { return }
                self.handle(message, from: client)
            }
            client.onClose = { [weak self, weak client] in
                guard let self, let client else { return }
                self.clients[ObjectIdentifier(client)] = nil
                self.sessions.values.forEach { $0.subscribers.remove(ObjectIdentifier(client)) }
                self.lastActivity = Date()
            }
            clients[ObjectIdentifier(client)] = client
            client.start()
        }
    }

    private func handle(_ message: ClientMessage, from client: Client) {
        lastActivity = Date()
        switch message {
        case let .hello(request, _):
            client.send(.hello(request: request, protocolVersion: SessionProtocol.version, build: build, pid: getpid()))

        case let .create(request, spec):
            if let existing = sessions[spec.id], existing.info.isRunning {
                client.send(.error(request: request, message: "session \(spec.id) already running"))
                return
            }
            do {
                let session = try makeSession(spec)
                sessions[spec.id] = session
                client.send(.created(request: request, session: session.info))
            } catch {
                client.send(.error(request: request, message: "cannot start session: \(error)"))
            }

        case let .list(request):
            client.send(.sessions(request: request, sessions: sessions.values.map(\.info).sorted { $0.startedAt < $1.startedAt }))

        case let .attach(request, id):
            guard let session = sessions[id] else {
                client.send(.error(request: request, message: "no session \(id)"))
                return
            }
            client.send(.ok(request: request))
            client.send(.snapshot(session: id, data: session.replay))
            if let status = session.info.exitStatus {
                client.send(.exited(session: id, status: status))
            } else {
                session.subscribers.insert(ObjectIdentifier(client))
            }

        case let .detach(id):
            sessions[id]?.subscribers.remove(ObjectIdentifier(client))

        case let .input(id, data):
            sessions[id]?.writer?.write(data)

        case let .resize(id, cols, rows):
            guard let session = sessions[id], session.info.isRunning else { return }
            session.info.cols = cols
            session.info.rows = rows
            PTY.resize(master: session.master, cols: cols, rows: rows)

        case let .kill(request, id, signal):
            guard let session = sessions[id], session.info.isRunning else {
                client.send(.error(request: request, message: "no running session \(id)"))
                return
            }
            // Signal the whole process group so the agent's children go too.
            Darwin.kill(-session.info.pid, signal)
            client.send(.ok(request: request))

        case let .remove(request, id):
            guard let session = sessions[id] else {
                client.send(.ok(request: request))
                return
            }
            guard !session.info.isRunning else {
                client.send(.error(request: request, message: "session \(id) is still running"))
                return
            }
            sessions[id] = nil
            client.send(.ok(request: request))

        case let .shutdown(request):
            client.send(.ok(request: request))
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.exitDaemon() }
        }
    }

    private func broadcast(_ message: ServerMessage, to session: Session) {
        for id in session.subscribers {
            clients[id]?.send(message)
        }
    }

    // MARK: Sessions

    private func makeSession(_ spec: SessionSpec) throws -> Session {
        let shell = Self.loginShell()
        let argv = spec.command.map { [shell, "-l", "-c", $0] } ?? [shell, "-l"]
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Bullpen"
        env["BULLPEN_SESSION_ID"] = spec.id
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env.merge(spec.environment) { _, new in new }

        let (pid, master) = try PTY.spawn(argv: argv, environment: env, cwd: spec.cwd, cols: spec.cols, rows: spec.rows)
        let info = SessionInfo(id: spec.id, cwd: spec.cwd, command: spec.command, pid: pid, cols: spec.cols, rows: spec.rows, startedAt: Date(), exitStatus: nil)
        let logURL = logDirectory.appendingPathComponent("\(safeFileName(spec.id)).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let session = Session(info: info, master: master, log: try? FileHandle(forWritingTo: logURL))
        session.writer = FDWriter(fd: master, queue: queue)

        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.readOutput(of: session)
        }
        read.resume()
        session.readSource = read

        let proc = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        proc.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.reap(session)
        }
        proc.resume()
        session.processSource = proc
        // The child may already have exited before the source was armed.
        queue.async { [weak self, weak session] in
            guard let self, let session else { return }
            self.reap(session)
        }
        return session
    }

    private func readOutput(of session: Session) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(session.master, &buffer, buffer.count)
            if n > 0 {
                let data = Data(buffer[0..<n])
                session.record(data, keep: replayBytes)
                broadcast(.output(session: session.info.id, data: data), to: session)
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                return
            } else {
                // EOF / EIO: the slave side is closed.
                session.outputClosed = true
                session.readSource?.cancel()
                session.readSource = nil
                finishIfDone(session)
                return
            }
        }
    }

    private func reap(_ session: Session) {
        guard session.info.isRunning, session.waitStatus == nil else { return }
        var status: Int32 = 0
        guard waitpid(session.info.pid, &status, WNOHANG) == session.info.pid else { return }
        session.waitStatus = PTY.exitCode(fromWaitStatus: status)
        session.processSource?.cancel()
        session.processSource = nil
        finishIfDone(session)
        // Grandchildren can keep the tty open; don't wait for EOF forever.
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self, weak session] in
            guard let self, let session else { return }
            if session.readSource != nil { self.readOutput(of: session) }
            session.outputClosed = true
            self.finishIfDone(session)
        }
    }

    private func finishIfDone(_ session: Session) {
        guard session.info.isRunning, session.outputClosed, let status = session.waitStatus else { return }
        session.info.exitStatus = status
        session.readSource?.cancel()
        session.readSource = nil
        session.writer?.cancel()
        session.writer = nil
        close(session.master)
        try? session.log?.close()
        broadcast(.exited(session: session.info.id, status: status), to: session)
        session.subscribers.removeAll()
        lastActivity = Date()
    }

    // MARK: Lifetime

    private func checkIdle() {
        guard let idleExit, clients.isEmpty, !sessions.values.contains(where: \.info.isRunning),
              Date().timeIntervalSince(lastActivity) > idleExit else { return }
        log.info("bpd idle, exiting")
        exitDaemon()
    }

    private func exitDaemon() {
        acceptSource?.cancel()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
        onExit?()
    }

    /// `$SHELL`, or the account's shell when launched from Finder (GUI apps may not have `$SHELL`).
    static func loginShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let value = String(cString: shell)
            if !value.isEmpty { return value }
        }
        return "/bin/zsh"
    }

    private func safeFileName(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}

final class Session {
    var info: SessionInfo
    let master: Int32
    let log: FileHandle?
    var writer: FDWriter?
    var readSource: DispatchSourceRead?
    var processSource: DispatchSourceProcess?
    var subscribers: Set<ObjectIdentifier> = []
    var waitStatus: Int32?
    var outputClosed = false
    private(set) var replay = Data()

    init(info: SessionInfo, master: Int32, log: FileHandle?) {
        self.info = info
        self.master = master
        self.log = log
    }

    func record(_ data: Data, keep: Int) {
        try? log?.write(contentsOf: data)
        replay.append(data)
        // Trim in batches so we don't shift the buffer on every read.
        if replay.count > keep + keep / 2 {
            replay = replay.suffix(keep)
        }
    }
}

final class Client {
    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private let writer: FDWriter
    private var lines = LineBuffer()
    private var closed = false
    var onMessage: ((ClientMessage) -> Void)?
    var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        writer = FDWriter(fd: fd, queue: queue)
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source
    }

    func send(_ message: ServerMessage) {
        guard !closed, let frame = try? Wire.frame(message) else { return }
        if !writer.write(frame) { close() }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                for line in lines.append(Data(buffer[0..<n])) {
                    if let message = try? Wire.decoder.decode(ClientMessage.self, from: line) {
                        onMessage?(message)
                    }
                }
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                return
            } else {
                close()
                return
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        writer.cancel()
        Darwin.close(fd)
        onClose?()
    }
}
