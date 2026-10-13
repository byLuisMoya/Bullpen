import BPAgents
import BPCore
import BPProviders
import BPSessions
import BPWorkspace
import Foundation
import Observation

/// A few words on what each agent is doing, for the bubble over its desk and the sidebar
/// (PLAN §9.1). The latest action shows at once and for free; when the quick-tasks model is
/// set up, it rewrites that as a short sentence, at most once every 40 s per agent and only
/// when something new happened.
@MainActor
@Observable
final class SummaryCenter {
    private(set) var summaries: [UUID: String] = [:]
    @ObservationIgnored private var lastInput: [UUID: String] = [:]
    @ObservationIgnored private var lastModelCall: [UUID: Date] = [:]
    @ObservationIgnored private var pending: [UUID: ActivityDigest] = [:]

    static let activeStates: Set<AgentState> = [.working, .thinking, .needsYou, .done]

    @ObservationIgnored var orca: OrcaCenter?

    func start(store: BuildingStore, sessions: SessionManager, attention: AttentionCenter) async {
        while !Task.isCancelled {
            await refresh(store: store, sessions: sessions, attention: attention)
            try? await Task.sleep(for: .seconds(15))
        }
    }

    func refresh(store: BuildingStore, sessions: SessionManager, attention: AttentionCenter) async {
        let worktrees = store.offices.flatMap(\.worktrees)
        summaries = summaries.filter { id, _ in worktrees.contains { $0.id == id } }
        for worktree in worktrees {
            guard let state = attention.statuses[worktree.id]?.state, Self.activeStates.contains(state) else { continue }
            let transcript = sessions.infos[Workspace.sessionID(for: worktree)]?.agentActivity?.transcriptPath
            let log = SessionProtocol.outputFile(session: Workspace.sessionID(for: worktree)).path
            // Worktrees from Orca: what Orca's agent was asked and last said.
            let fromOrca = worktree.agentProfileID == nil ? orca?.activity(for: worktree) : nil
            let digest: ActivityDigest
            if let fromOrca {
                digest = ActivityDigest(request: fromOrca.prompt, lastMessage: fromOrca.lastMessage)
            } else {
                digest = await Task.detached {
                    if let transcript, let text = Self.tail(transcript, bytes: 96_000) {
                        return ActivityDigest.fromClaudeTranscript(text)
                    }
                    return ActivityDigest.fromTerminal(Self.tail(log, bytes: 12_000) ?? "")
                }.value
            }
            guard !digest.isEmpty, digest.modelPrompt != lastInput[worktree.id] else { continue }
            lastInput[worktree.id] = digest.modelPrompt
            if let quick = digest.quickSummary { summaries[worktree.id] = quick }
            pending[worktree.id] = digest
            summarizeWithModel(worktree.id)
        }
    }

    private func summarizeWithModel(_ id: UUID) {
        guard Self.modelAvailable, let digest = pending[id] else { return }
        if let last = lastModelCall[id], Date().timeIntervalSince(last) < 40 { return }
        lastModelCall[id] = Date()
        pending[id] = nil
        Task {
            guard let answer = try? await ModelService.complete(.quick, CompletionRequest(
                system: ActivityDigest.modelSystem, prompt: digest.modelPrompt, maxTokens: 1024, effort: "low"
            )) else { return }
            let line = (answer.split(separator: "\n").first.map(String.init) ?? answer)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .\"'`«»"))
            guard !line.isEmpty, line.count <= 80, self.lastInput[id] == digest.modelPrompt else { return }
            self.summaries[id] = line
        }
    }

    /// The quick-tasks model can be called: a key, a local server, or the user's Claude Code.
    static var modelAvailable: Bool { ModelService.available(for: .quick) }

    /// The last `bytes` of a file, starting at a line boundary.
    nonisolated static func tail(_ path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }
}
