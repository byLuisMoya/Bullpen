import Darwin
import Foundation

/// How `bp mcp` (an agent's tools) reaches the browser tabs, which live in the app: one JSON line
/// each way over a Unix socket in Application Support.
public struct BrowserRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case open, snapshot, screenshot, click, type, eval, console }
    public var action: Action
    /// Worktree id (its browser tab).
    public var worktree: String
    /// The worktree's own URL, opened when the tab has no page yet.
    public var home: String
    public var url: String?
    public var selector: String?
    public var text: String?
    public var submit: Bool?
    public var script: String?

    public init(action: Action, worktree: String, home: String, url: String? = nil, selector: String? = nil,
                text: String? = nil, submit: Bool? = nil, script: String? = nil) {
        self.action = action
        self.worktree = worktree
        self.home = home
        self.url = url
        self.selector = selector
        self.text = text
        self.submit = submit
        self.script = script
    }
}

public struct BrowserResponse: Codable, Sendable {
    public var ok: Bool
    public var text: String?
    /// PNG for `screenshot`.
    public var image: Data?

    public init(ok: Bool, text: String? = nil, image: Data? = nil) {
        self.ok = ok
        self.text = text
        self.image = image
    }
}

public enum BrowserBridge {
    public static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bullpen/run/browser.sock").path
    }

    /// Sends one request to the app and waits for its answer.
    public static func send(_ request: BrowserRequest, socketPath: String = socketPath, timeout: Int = 60) async throws -> BrowserResponse {
        try await Task.detached {
            let fd: Int32
            do { fd = try UnixSocket.connect(to: socketPath) } catch {
                throw SessionError(message: "El navegador está en la app de Bullpen: ábrela para usarlo.")
            }
            defer { close(fd) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var limit = timeval(tv_sec: timeout, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            guard FDPassing.writeAll(try Wire.frame(request), to: fd) else { throw SessionError(message: "No se pudo hablar con la app") }
            var line = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !line.contains(0x0A) {
                let n = read(fd, &buffer, buffer.count)
                guard n > 0 else { throw SessionError(message: "La app no respondió a tiempo") }
                line.append(contentsOf: buffer[0..<n])
            }
            return try Wire.decoder.decode(BrowserResponse.self, from: line.prefix { $0 != 0x0A })
        }.value
    }

    /// The app's side: answers each connection's request with `handler`.
    public final class Server: @unchecked Sendable {
        private let path: String
        private let handler: @Sendable (BrowserRequest) async -> BrowserResponse
        private var listenFD: Int32 = -1
        private var inode: ino_t = 0
        private var source: DispatchSourceRead?
        private let queue = DispatchQueue(label: "bullpen.browser-bridge")

        public init(path: String = BrowserBridge.socketPath, handler: @escaping @Sendable (BrowserRequest) async -> BrowserResponse) {
            self.path = path
            self.handler = handler
        }

        public func start() throws {
            // A previous app instance may have left its socket behind.
            if (try? UnixSocket.connect(to: path)).map({ close($0); return true }) != true { unlink(path) }
            (listenFD, inode) = try UnixSocket.listen(at: path)
            let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
            source.setEventHandler { [weak self] in self?.accept() }
            source.resume()
            self.source = source
        }

        public func stop() {
            source?.cancel()
            if listenFD >= 0 { close(listenFD) }
            UnixSocket.unlinkIfOurs(path, inode: inode)
        }

        private func accept() {
            while true {
                let fd = Darwin.accept(listenFD, nil, nil)
                guard fd >= 0 else { return }
                let handler = self.handler
                Thread.detachNewThread {
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                    var line = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    while !line.contains(0x0A) {
                        let n = read(fd, &buffer, buffer.count)
                        guard n > 0 else { close(fd); return }
                        line.append(contentsOf: buffer[0..<n])
                    }
                    guard let request = try? Wire.decoder.decode(BrowserRequest.self, from: line.prefix { $0 != 0x0A }) else { close(fd); return }
                    let done = DispatchSemaphore(value: 0)
                    nonisolated(unsafe) var response = BrowserResponse(ok: false, text: "sin respuesta")
                    Task {
                        response = await handler(request)
                        done.signal()
                    }
                    done.wait()
                    if let frame = try? Wire.frame(response) { _ = FDPassing.writeAll(frame, to: fd) }
                    close(fd)
                }
            }
        }
    }
}
