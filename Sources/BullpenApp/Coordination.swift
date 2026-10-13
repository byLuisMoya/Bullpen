import BPCore
import BPPersistence
import Foundation
import Observation
import SwiftUI

/// Delivers the mailbox: a message for an agent is typed in when it finishes its turn (never
/// while it works or waits on a permission); one for the user becomes a notification.
@MainActor
final class MailCarrier {
    func start(store: BuildingStore, sessions: SessionManager, attention: AttentionCenter) async {
        while !Task.isCancelled {
            await deliver(store: store, sessions: sessions, attention: attention)
            await Pacing.pause(active: 2, background: 5)
        }
    }

    private func deliver(store: BuildingStore, sessions: SessionManager, attention: AttentionCenter) async {
        guard let database = store.workspace?.database, let pending = try? database.undeliveredMessages(), !pending.isEmpty else { return }
        let active = Dictionary(store.offices.flatMap(\.worktrees).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for message in pending where message.toWorktree == nil {
            BackgroundNotice.post(id: "message-\(message.id)", title: "\(message.fromLabel) te escribe", body: message.text)
            AlertSounds.play(.message)
            try? database.markMessages([message.id])
        }
        // One delivery per recipient, with everything waiting for it.
        let byRecipient = Dictionary(grouping: pending.filter { $0.toWorktree != nil }, by: { $0.toWorktree! })
        for (id, messages) in byRecipient {
            guard let worktree = active[id], worktree.agentProfileID != nil, let state = attention.statuses[id]?.state, state == .done || state == .idle else { continue }
            let text = messages.map { "[Buzón de Bullpen · de «\($0.fromLabel)»] \($0.text)" }.joined(separator: "\n\n")
            do {
                try await sessions.sendMessage(text, to: worktree)
                try database.markMessages(messages.map(\.id))
            } catch {
                continue   // no terminal running: it waits for the next one
            }
        }
    }
}

/// "Equipo": the project's task board and this worktree's mailbox.
struct CoordinationView: View {
    let worktree: Worktree
    let project: Project
    @Environment(BuildingStore.self) private var store
    @State private var tasks: [AgentTask] = []
    @State private var messages: [AgentMessage] = []
    @State private var newTask = ""
    @State private var newMessage = ""

    private var database: AppDatabase? { store.workspace?.database }

    var body: some View {
        List {
            Section {
                if tasks.isEmpty {
                    Text("Sin tareas. Los agentes las crean con create_task, o añade una aquí.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("#\(task.number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Text(task.title).font(.callout.bold())
                            Spacer()
                            Text(task.status.title)
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(color(task.status).opacity(0.18), in: Capsule())
                                .foregroundStyle(color(task.status))
                        }
                        Text(caption(task)).font(.caption).foregroundStyle(.secondary)
                        if let result = task.result { Text(result).font(.callout).textSelection(.enabled).lineLimit(6) }
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    TextField("Nueva tarea para cualquier agente", text: $newTask).onSubmit(addTask)
                    Button("Añadir", action: addTask).disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Tablero de \(project.name)")
            }
            Section {
                if messages.isEmpty {
                    Text("Sin mensajes. Lo que le escribas aquí le llega cuando termine su turno, sin interrumpirle.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(messages) { message in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(direction(message)).font(.caption.bold())
                            Spacer()
                            Text(message.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(message.text).font(.callout).textSelection(.enabled).lineLimit(10)
                        if message.toWorktree == worktree.id, message.deliveredAt == nil {
                            Label("Esperando a que termine su turno", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    TextField("Escribir a este agente", text: $newMessage).onSubmit(sendMessage)
                    Button("Enviar", action: sendMessage).disabled(newMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Buzón")
            }
        }
        .task(id: worktree.id) {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func reload() {
        guard let database else { return }
        let freshTasks = (try? database.tasks(project: project.id)) ?? []
        let freshMessages = (try? database.conversation(of: worktree.id)) ?? []
        if freshTasks != tasks { tasks = freshTasks }
        if freshMessages != messages { messages = freshMessages }
        // Looking at it is reading it.
        let unread = freshMessages.filter { $0.toWorktree == nil && $0.readAt == nil }.map(\.id)
        try? database.markMessages(unread, read: true)
    }

    private func addTask() {
        let title = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let database else { return }
        do {
            _ = try database.createTask(AgentTask(projectID: project.id, title: title, createdBy: nil, createdByLabel: "Tú"))
            newTask = ""
            reload()
        } catch { store.errorMessage = error.localizedDescription }
    }

    private func sendMessage() {
        let text = newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let database else { return }
        do {
            try database.save(AgentMessage(projectID: project.id, toWorktree: worktree.id, fromWorktree: nil, fromLabel: "Tú", text: text))
            newMessage = ""
            reload()
        } catch { store.errorMessage = error.localizedDescription }
    }

    private func direction(_ message: AgentMessage) -> String {
        if message.toWorktree == nil { return "\(message.fromLabel) → Tú" }
        if message.toWorktree == worktree.id { return "\(message.fromLabel) → \(worktree.branch)" }
        let to = store.offices.flatMap(\.worktrees).first { $0.id == message.toWorktree }?.branch ?? "otro worktree"
        return "\(worktree.branch) → \(to)"
    }

    private func caption(_ task: AgentTask) -> String {
        var parts = ["De \(task.createdByLabel)"]
        if let assignee = task.assigneeLabel { parts.append("la tiene \(assignee)") }
        if let detail = task.detail { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    private func color(_ status: AgentTask.Status) -> Color {
        switch status {
        case .open: .orange
        case .claimed: .blue
        case .done: .green
        }
    }
}
