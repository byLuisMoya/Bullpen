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

        init(sessions: SessionManager) { self.sessions = sessions }

        func start(view: TerminalView, worktree: Worktree, environment: [String: String], tab: String?) {
            self.view = view
            Task {
                do {
                    // Before layout the view is 2×1: told that size, the agent redraws for it, and
                    // again (its whole conversation) at the real one — a black screen meanwhile.
                    for _ in 0..<60 where !Self.isLaidOut(view.getTerminal()) && !stopped {
                        try await Task.sleep(for: .milliseconds(16))
                    }
                    let terminal = view.getTerminal()
                    let cols = UInt16(max(terminal.cols, 20)), rows = UInt16(max(terminal.rows, 5))
                    let id = if let tab {
                        try await sessions.ensureTab(tab, for: worktree, environment: environment, cols: cols, rows: rows)
                    } else {
                        try await sessions.ensureMain(for: worktree, environment: environment, cols: cols, rows: rows)
                    }
                    // Gone while the session was being readied: don't attach a view nobody shows.
                    guard !stopped else { return }
                    sessionID = id
                    // Size first: when it is the session's own, nothing changes and the snapshot
                    // that follows is drawn for exactly this size.
                    if Self.isLaidOut(terminal) { sessions.resize(id, cols: terminal.cols, rows: terminal.rows) }
                    try await sessions.attach(id, handler: self)
                    view.window?.makeFirstResponder(view)
                } catch {
                    view.feed(text: "\r\n\u{1B}[31mNo se pudo abrir la terminal: \(error.localizedDescription)\u{1B}[0m\r\n")
                }
            }
        }

        private var stopped = false

        func stop() {
            stopped = true
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
            view.getTerminal().resetToInitialState()
            view.feed(byteArray: ArraySlice(data))
        }

        func sessionOutput(_ data: Data) { view?.feed(byteArray: ArraySlice(data)) }

        func sessionExited(status: Int32) {
            view?.feed(text: "\r\n\u{1B}[2m[proceso terminado con código \(status)]\u{1B}[0m\r\n")
        }

        // MARK: TerminalViewDelegate

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            MainActor.assumeIsolated {
                if let sessionID { sessions.input(sessionID, bytes) }
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
