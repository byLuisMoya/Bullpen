import BPAgents
import BPCore
import BPPersistence
import Foundation
import Observation
import UserNotifications
import AppKit
import BPGit

/// Turns agent status changes into notifications and the Dock badge (PLAN §12).
/// One notification per worktree, replaced instead of piling up, removed when you look at it.
@MainActor
@Observable
final class AttentionCenter {
    private(set) var statuses: [UUID: AgentStatus] = [:]
    @ObservationIgnored private var notificationsEnabled = false
    /// Worktree being looked at: no banner for it.
    @ObservationIgnored var focusedWorktree: UUID? {
        didSet { if let focusedWorktree { clear(focusedWorktree) } }
    }

    /// Orca's agents, for the worktrees that came from Orca (set by the app).
    @ObservationIgnored var orca: OrcaCenter?

    func start(store: BuildingStore, sessions: SessionManager) async {
        // UNUserNotificationCenter needs a real app bundle (not `swift run`).
        if Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" {
            notificationsEnabled = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
        while !Task.isCancelled {
            update(store: store, sessions: sessions)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func update(store: BuildingStore, sessions: SessionManager) {
        var next: [UUID: AgentStatus] = [:]
        for office in store.offices {
            for worktree in office.worktrees {
                // A worktree from Orca without an agent of Bullpen's: its state is Orca's agent's
                // (even with a plain terminal open here).
                let status = (worktree.agentProfileID == nil ? orca?.status(for: worktree) : nil) ?? sessions.status(for: worktree)
                next[worktree.id] = status
                let old = statuses[worktree.id]?.state
                if old != nil, old != status.state { changed(worktree, in: office.project, to: status) }
            }
        }
        guard next != statuses else { return }
        statuses = next
        let waiting = next.values.filter { $0.state == .needsYou }.count
        let badge = waiting > 0 ? "\(waiting)" : nil
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
    }

    private func changed(_ worktree: Worktree, in project: Project, to status: AgentStatus) {
        // Each finished turn leaves a checkpoint to compare with or go back to (PLAN §11.3).
        if status.state == .done {
            Task.detached {
                let repo = try? await Repository.open(at: URL(fileURLWithPath: project.path))
                let time = Date().formatted(date: .omitted, time: .shortened)
                _ = try? await repo?.createCheckpoint(of: worktree.id, in: URL(fileURLWithPath: worktree.path), message: "Turno terminado · \(time)")
            }
        }
        let title: String
        switch status.state {
        case .needsYou: title = "\(worktree.branch) te necesita"
        case .done: title = "\(worktree.branch) ha terminado"
        case .error: title = "\(worktree.branch) ha fallado"
        default: return
        }
        guard notificationsEnabled, worktree.id != focusedWorktree || !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = project.name
        content.body = status.detail ?? ""
        content.threadIdentifier = worktree.id.uuidString
        content.sound = status.state == .needsYou ? .default : nil
        // Same identifier per worktree: a new state replaces the previous banner.
        let request = UNNotificationRequest(identifier: worktree.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func clear(_ worktree: UUID) {
        guard notificationsEnabled else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [worktree.uuidString])
    }
}
