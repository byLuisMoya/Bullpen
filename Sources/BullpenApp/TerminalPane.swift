import BPCore
import SwiftTerm
import SwiftUI

/// Integrated terminal for a worktree, backed by a `bpd` session that outlives the view and the app.
struct TerminalPane: NSViewRepresentable {
    let worktree: Worktree
    var environment: [String: String] = [:]
    /// An extra tab's session id; nil is the main tab (the worktree's agent).
    var tab: String?
    @Environment(SessionManager.self) private var sessions

    func makeCoordinator() -> Coordinator { Coordinator(sessions: sessions) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        // Recent history only; the full log stays on disk in the daemon (ADR 0002).
        view.getTerminal().changeHistorySize(2_000)
        view.terminalDelegate = context.coordinator
        context.coordinator.start(view: view, worktree: worktree, environment: environment, tab: tab)
        context.coordinator.wheel = WheelForwarder(view: view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate, SessionOutputHandler {
        private let sessions: SessionManager
        private weak var view: TerminalView?
        private var sessionID: String?

        /// Scrolling inside full-screen agents (Claude Code), which SwiftTerm doesn't do on its own.
        var wheel: WheelForwarder?

        init(sessions: SessionManager) { self.sessions = sessions }

        func start(view: TerminalView, worktree: Worktree, environment: [String: String], tab: String?) {
            self.view = view
            opening = OpenTiming(name: tab.map { "\(worktree.branch) [\($0)]" } ?? worktree.branch)
            Task {
                do {
                    // Before layout the view is 2×1: told that size, the agent redraws for it, and
                    // again (its whole conversation) at the real one — a black screen meanwhile.
                    for _ in 0..<60 where !Self.isLaidOut(view.getTerminal()) && !stopped {
                        try await Task.sleep(for: .milliseconds(16))
                    }
                    opening?.mark("layout")
                    let terminal = view.getTerminal()
                    let cols = UInt16(max(terminal.cols, 20)), rows = UInt16(max(terminal.rows, 5))
                    let id = if let tab {
                        try await sessions.ensureTab(tab, for: worktree, environment: environment, cols: cols, rows: rows)
                    } else {
                        try await sessions.ensureMain(for: worktree, environment: environment, cols: cols, rows: rows)
                    }
                    // Gone while the session was being readied: don't attach a view nobody shows.
                    guard !stopped else { return }
                    opening?.mark("session")
                    sessionID = id
                    // Size first: when it is the session's own, nothing changes and the snapshot
                    // that follows is drawn for exactly this size.
                    if Self.isLaidOut(terminal) { sessions.resize(id, cols: terminal.cols, rows: terminal.rows) }
                    try await sessions.attach(id, handler: self)
                    view.window?.makeFirstResponder(view)
                } catch {
                    if let opening {
                        self.opening = nil
                        Diagnostics.note("open: \(opening.name): " + (opening.steps + ["failed \(OpenTiming.ms(ContinuousClock.now - opening.began))"]).joined(separator: ", "))
                    }
                    view.feed(text: "\r\n\u{1B}[31mNo se pudo abrir la terminal: \(error.localizedDescription)\u{1B}[0m\r\n")
                }
            }
        }

        private var stopped = false

        /// How long opening this terminal took, step by step, until the agent's first output
        /// after the snapshot (a redraw, if the size changed). Written to Diagnostics when slow.
        private struct OpenTiming {
            let name: String
            let began = ContinuousClock.now
            var steps: [String] = []
            var snapshotAt: ContinuousClock.Instant?
            var firstOutputAt: ContinuousClock.Instant?
            var outputBytes = 0

            init(name: String) { self.name = name }

            mutating func mark(_ step: String, _ detail: String = "") {
                steps.append("\(step) \(Self.ms(ContinuousClock.now - began))\(detail)")
            }

            static func ms(_ d: Duration) -> String {
                "\(Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)) ms"
            }
        }
        private var opening: OpenTiming?
        /// When the user typed something and nothing has come back yet.
        private var typedAt: ContinuousClock.Instant?

        func stop() {
            stopped = true
            typedAt = nil
            wheel = nil
            pendingResize?.cancel()
            if let sessionID { sessions.detach(sessionID, handler: self) }
        }

        /// SwiftTerm's size before the view has one (its minimum) is 2×1: that one is never real.
        static func isLaidOut(_ terminal: Terminal) -> Bool { terminal.cols > 2 || terminal.rows > 1 }

        private var pendingResize: Task<Void, Never>?

        /// Each size the agent hears it redraws for (Claude Code: its whole conversation), so only
        /// the one the layout settles on goes, not every step of a sidebar or split animating.
        private func resizeSoon() {
            pendingResize?.cancel()
            pendingResize = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, let sessionID = self.sessionID,
                      let terminal = self.view?.getTerminal(), Self.isLaidOut(terminal) else { return }
                self.sessions.resize(sessionID, cols: terminal.cols, rows: terminal.rows)
            }
        }

        // MARK: SessionOutputHandler

        func sessionSnapshot(_ data: Data) {
            guard let view else { return }
            let fed = ContinuousClock.now
            view.getTerminal().resetToInitialState()
            view.feed(byteArray: ArraySlice(data))
            typedAt = nil
            // The first snapshot only (a reconnect sends another).
            guard opening != nil, opening?.snapshotAt == nil else { return }
            opening?.mark("snapshot", " (\(data.count / 1024) KB, drawn in \(OpenTiming.ms(ContinuousClock.now - fed)))")
            opening?.snapshotAt = .now
            // What the agent sends in the next 3 s: a big burst is it redrawing everything.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finishOpening()
            }
        }

        func sessionOutput(_ data: Data) {
            view?.feed(byteArray: ArraySlice(data))
            if opening?.snapshotAt != nil {
                if opening?.firstOutputAt == nil {
                    opening?.mark("first output")
                    opening?.firstOutputAt = .now
                }
                opening?.outputBytes += data.count
            }
            if let typedAt {
                self.typedAt = nil
                let waited = ContinuousClock.now - typedAt
                // Over 30 s it wasn't waiting on the key (a key with no echo, then the agent spoke later).
                if waited > .milliseconds(300), waited < .seconds(30), let sessionID {
                    Diagnostics.note("typing: \(sessionID) answered after \(OpenTiming.ms(waited))")
                }
            }
        }

        private func finishOpening() {
            guard let opening else { return }
            self.opening = nil
            let total = (opening.firstOutputAt ?? opening.snapshotAt ?? .now) - opening.began
            // Only the slow ones, or a redraw burst after the snapshot.
            guard total > .milliseconds(300) || opening.outputBytes > 200_000 else { return }
            Diagnostics.note("open: \(opening.name): " + opening.steps.joined(separator: ", ")
                             + ", then \(opening.outputBytes / 1024) KB of output in 3 s")
        }

        func sessionExited(status: Int32) {
            typedAt = nil
            view?.feed(text: "\r\n\u{1B}[2m[proceso terminado con código \(status)]\u{1B}[0m\r\n")
        }

        // MARK: TerminalViewDelegate

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            MainActor.assumeIsolated {
                guard let sessionID else { return }
                // Typed text, not SwiftTerm answering the agent's queries (those start with ESC).
                if typedAt == nil, let first = bytes.first, first != 0x1B { typedAt = .now }
                sessions.input(sessionID, bytes)
            }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                resizeSoon()
            }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            MainActor.assumeIsolated {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(content, forType: .string)
            }
        }
    }
}

/// SwiftTerm's scroll wheel only moves its own history, and a full-screen app (Claude Code draws
/// on the alternate screen and asks for the mouse) has none: the wheel did nothing and a long
/// answer couldn't be read back. Like Terminal or iTerm, the wheel goes to the app instead — as
/// wheel clicks when it asks for the mouse, as arrow keys on the alternate screen otherwise.
/// SwiftTerm's `scrollWheel` can't be overridden from here, hence the event monitor.
@MainActor
final class WheelForwarder {
    private weak var view: TerminalView?
    nonisolated(unsafe) private var monitor: Any?
    /// Trackpad points not yet worth a whole line.
    private var pending: CGFloat = 0

    init(view: TerminalView) {
        self.view = view
        // Local monitors run on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            nonisolated(unsafe) let event = event
            let forwarded = MainActor.assumeIsolated { self?.forward(event) == true }
            return forwarded ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// True when the event went to the app; false leaves it to SwiftTerm (or whatever is under the pointer).
    private func forward(_ event: NSEvent) -> Bool {
        guard let view, let window = view.window, event.window === window else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(point), window.contentView?.hitTest(event.locationInWindow).map({ $0.isDescendant(of: view) }) == true
        else { return false }
        let terminal = view.getTerminal()
        let mouse = view.allowMouseReporting && terminal.mouseMode != .off
        guard mouse || terminal.isCurrentBufferAlternate else { return false }

        // SwiftTerm's own cell (its `cellDimension` isn't public): the bounds also hold its scroller.
        let font = view.font
        let cellHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let cellWidth = font.advancement(forGlyph: font.glyph(withName: "W")).width
        guard cellHeight > 0, cellWidth > 0 else { return false }
        let lines: Int
        if event.hasPreciseScrollingDeltas {
            // A new gesture, or one turning back, doesn't inherit what the last one left over.
            if event.phase == .began || (pending != 0 && (pending > 0) != (event.scrollingDeltaY > 0)) { pending = 0 }
            pending += event.scrollingDeltaY
            lines = Int(pending / cellHeight)
            pending -= CGFloat(lines) * cellHeight
        } else {
            pending = 0
            lines = event.deltaY == 0 ? 0 : Int(event.deltaY.rounded(.awayFromZero))
        }
        // Sideways scrolls and a gesture's empty begin/end events aren't the app's.
        if lines == 0 { return event.scrollingDeltaY != 0 }
        let up = lines > 0
        let count = min(abs(lines), 3 * terminal.rows)

        if mouse {
            // Capped at 222: SwiftTerm's x10 encoding (the default) traps past one byte.
            let col = min(max(Int(point.x / cellWidth), 0), terminal.cols - 1, 222)
            let row = min(max(Int((view.bounds.height - point.y) / cellHeight), 0), terminal.rows - 1, 222)
            let flags = event.modifierFlags
            let button = terminal.encodeButton(button: up ? 4 : 5, release: false, shift: flags.contains(.shift),
                                               meta: flags.contains(.option), control: flags.contains(.control))
            let pixelX = Int(max(point.x, 0)), pixelY = Int(max(view.bounds.height - point.y, 0))
            for _ in 0..<count { terminal.sendEvent(buttonFlags: button, x: col, y: row, pixelX: pixelX, pixelY: pixelY) }
        } else {
            let key: [UInt8] = terminal.applicationCursor ? [0x1B, 0x4F, up ? 0x41 : 0x42] : [0x1B, 0x5B, up ? 0x41 : 0x42]
            view.send(data: ArraySlice(Array((0..<count).map { _ in key }.joined())))
        }
        return true
    }
}
