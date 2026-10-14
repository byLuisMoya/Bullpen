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
    private var socketInode: ino_t = 0
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
        (listenFD, socketInode) = try UnixSocket.listen(at: socketPath)
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
            UnixSocket.unlinkIfOurs(socketPath, inode: socketInode)
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
            let infos = sessions.values.map { session in
                var info = session.info
                if info.isRunning { info.foregroundProcess = Self.foregroundProcess(leader: info.pid) }
                return info
            }
            client.send(.sessions(request: request, sessions: infos.sorted { $0.startedAt < $1.startedAt }))

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

        case let .agentEvent(request, id, activity):
            client.send(.ok(request: request))
            guard let session = sessions[id] else { return }
            var latest = activity
            // Keep the transcript path even when an event doesn't carry it.
            if latest.transcriptPath == nil { latest.transcriptPath = session.info.agentActivity?.transcriptPath }
            session.info.agentActivity = latest
            appendEvent(activity, session: id)
            let message = ServerMessage.activity(session: session.info)
            clients.values.forEach { $0.send(message) }

        case let .shutdown(request):
            client.send(.ok(request: request))
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.exitDaemon() }

        case .handover:
            handOver(to: client)
        }
    }

    private func appendEvent(_ activity: AgentActivity, session id: String) {
        guard var line = try? Wire.encoder.encode(activity) else { return }
        line.append(0x0A)
        let url = SessionProtocol.eventsFile(session: id, logDirectory: logDirectory)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    private func broadcast(_ message: ServerMessage, to session: Session) {
        // Encoded once for every window showing the session.
        guard !session.subscribers.isEmpty, let frame = try? Wire.frame(message) else { return }
        for id in session.subscribers {
            clients[id]?.send(frame: frame)
        }
    }

    // MARK: Sessions

    private func makeSession(_ spec: SessionSpec) throws -> Session {
        let shell = Self.loginShell()
        let argv = spec.command.map { [shell, "-l", "-c", $0] } ?? [shell, "-l"]
        // Don't leak markers from whatever launched bpd (e.g. a Claude Code session) into the agents.
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CODEX_") || key == "BULLPEN_SESSION_ID")
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Bullpen"
        env["BULLPEN_SESSION_ID"] = spec.id
        env["BULLPEN_SOCKET"] = socketPath
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
                session.info.lastOutputAt = Date()
                if let mode = Self.bracketedPasteChange(in: data) { session.info.bracketedPaste = mode }
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
        let reaped = waitpid(session.info.pid, &status, WNOHANG)
        if reaped == session.info.pid {
            session.waitStatus = PTY.exitCode(fromWaitStatus: status)
        } else if session.adopted, reaped == -1, Darwin.kill(session.info.pid, 0) != 0, errno == ESRCH {
            // Taken over from an older bpd: gone, exit status unknown.
            session.waitStatus = 0
        } else {
            return
        }
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

    // MARK: Handover (updating bpd without closing terminals)

    /// Gives every session to a newer bpd and leaves: state and recent output as JSON (length
    /// first), then each running session's PTY master over the socket. The processes keep
    /// running; the new daemon reads their terminals from now on.
    private func handOver(to client: Client) {
        // Stop reading first so no output is lost between the snapshot and the switch.
        for session in sessions.values {
            session.readSource?.cancel()
            session.readSource = nil
            session.processSource?.cancel()
            session.processSource = nil
        }
        let ordered = sessions.values.sorted { $0.info.startedAt < $1.info.startedAt }
        let payload = HandoverPayload(build: build, sessions: ordered.map { .init(info: $0.info, replay: $0.replay) })
        guard let json = try? Wire.encoder.encode(payload) else { return }
        var header = UInt64(json.count).bigEndian
        let fd = client.rawDescriptor
        FDPassing.setBlocking(fd)
        guard FDPassing.writeAll(Data(bytes: &header, count: 8) + json, to: fd) else { return }
        for session in ordered where session.info.isRunning {
            _ = FDPassing.send(session.master, over: fd)
        }
        log.info("bpd \(self.build, privacy: .public) handed \(ordered.count) session(s) over")
        // No SIGHUP: the sessions belong to the new daemon now.
        sessions.removeAll()
        exitDaemon()
    }

    /// Takes the sessions of the bpd listening on `socketPath` before starting. Throws if it
    /// doesn't answer a handover (too old): then it is still running and nothing changed.
    @discardableResult
    public func adopt(from socketPath: String) throws -> Int {
        let fd = try UnixSocket.connect(to: socketPath)
        defer { close(fd) }
        FDPassing.setBlocking(fd)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard FDPassing.writeAll(try Wire.frame(ClientMessage.handover(request: 1)), to: fd),
              let header = FDPassing.readExactly(8, from: fd) else {
            throw SessionError(message: "el bpd en marcha no admite el traspaso")
        }
        let length = header.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard length < 1 << 31, let json = FDPassing.readExactly(Int(length), from: fd) else {
            throw SessionError(message: "traspaso incompleto")
        }
        let payload = try Wire.decoder.decode(HandoverPayload.self, from: json)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        queue.sync {
            for item in payload.sessions {
                if item.info.isRunning {
                    guard let master = FDPassing.receive(over: fd) else { continue }
                    sessions[item.info.id] = adoptSession(item, master: master)
                } else {
                    let session = Session(info: item.info, master: -1, log: nil)
                    session.seed(item.replay)
                    sessions[item.info.id] = session
                }
            }
        }
        // The old daemon unlinks its socket as it exits; wait for that before listening here.
        for _ in 0..<50 where (try? UnixSocket.connect(to: socketPath)).map({ close($0); return true }) == true {
            Thread.sleep(forTimeInterval: 0.1)
        }
        log.info("bpd \(self.build, privacy: .public) took over \(payload.sessions.count) session(s) from \(payload.build, privacy: .public)")
        return payload.sessions.count
    }

    private func adoptSession(_ item: HandoverPayload.Item, master: Int32) -> Session {
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        let logURL = logDirectory.appendingPathComponent("\(safeFileName(item.info.id)).log")
        let log = try? FileHandle(forWritingTo: logURL)
        _ = try? log?.seekToEnd()
        let session = Session(info: item.info, master: master, log: log)
        session.adopted = true
        session.seed(item.replay)
        session.writer = FDWriter(fd: master, queue: queue)
        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.readOutput(of: session)
        }
        read.resume()
        session.readSource = read
        // Not our child: kqueue still tells us when it exits, but its status is not ours to read.
        let proc = DispatchSource.makeProcessSource(identifier: item.info.pid, eventMask: .exit, queue: queue)
        proc.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.reap(session)
        }
        proc.resume()
        session.processSource = proc
        queue.async { [weak self, weak session] in
            guard let self, let session else { return }
            self.reap(session)
        }
        return session
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
        UnixSocket.unlinkIfOurs(socketPath, inode: socketInode)
        onExit?()
    }

    /// What the user is running in the terminal right now (`claude`, `vim`, `zsh`…).
    /// A non-interactive shell (`zsh -c "claude; exec zsh"`) keeps its children in its own process
    /// group, so the group leader is the shell: pick the oldest member that is not a shell or a helper.
    static func foregroundProcess(leader: pid_t) -> String? {
        // Same source as `ps -o tpgid`: the terminal's foreground group, read from the session leader.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(leader, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let group = pid_t(bitPattern: info.e_tpgid)
        guard group > 0 else { return nil }

        var pids = [pid_t](repeating: 0, count: 256)
        // Returns the number of pids (not bytes).
        let count = Int(proc_listpgrppids(group, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let members = count > 0 ? pids.prefix(min(count, pids.count)).filter { $0 > 0 } : [group]
        let names = members.sorted().compactMap(commandName)
        return names.first { !shellNames.contains($0) && !helperNames.contains($0) } ?? names.first
    }

    /// Basename of argv[0], like `ps -o comm`. The executable name can differ: Claude Code's
    /// binary is a versioned file (`2.1.296`) launched as `claude`.
    static func commandName(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // Layout: argc (Int32), exec path, NUL padding, argv[0], ...
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var end = i
        while end < size, buffer[end] != 0 { end += 1 }
        guard end > i else { return nil }
        let argv0 = String(decoding: buffer[i..<end], as: UTF8.self)
        return (argv0 as NSString).lastPathComponent
    }

    static let helperNames: Set<String> = ["caffeinate"]

    private static let pasteOn = Data("\u{1B}[?2004h".utf8), pasteOff = Data("\u{1B}[?2004l".utf8)

    /// The last bracketed-paste switch in a chunk of output, if any.
    static func bracketedPasteChange(in data: Data) -> Bool? {
        let on = data.lastRange(of: pasteOn)?.lowerBound, off = data.lastRange(of: pasteOff)?.lowerBound
        switch (on, off) {
        case let (on?, off?): return on > off
        case (_?, nil): return true
        case (nil, _?): return false
        default: return nil
        }
    }
    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "nu", "-zsh", "-bash"]

    /// `$SHELL`, or the account's shell when launched from Finder (GUI apps may not have `$SHELL`).
    static func loginShell() -> String { ShellEnvironment.loginShell() }

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
    /// Taken over from an older bpd: its process is not our child.
    var adopted = false
    private(set) var replay = Data()

    func seed(_ data: Data) { replay = data }

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
    /// For the handover, which writes descriptors on the socket itself.
    var rawDescriptor: Int32 { fd }
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
        send(frame: frame)
    }

    func send(frame: Data) {
        guard !closed else { return }
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
