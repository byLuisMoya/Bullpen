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
    /// Agents that look stuck mid-turn (and the user hasn't dismissed).
    private(set) var stalls: [UUID: Stall] = [:]
    /// Stalls the user said to leave alone, by their start: a new hook ends them anyway.
    @ObservationIgnored private var ignoredStalls: [UUID: Date] = [:]
    /// Stalls already announced, so each one makes a single notification.
    @ObservationIgnored private var announcedStalls: [UUID: Date] = [:]

    static let stallMinutesKey = "stall.minutes"
    static var stallMinutes: Int {
        UserDefaults.standard.object(forKey: stallMinutesKey) == nil ? 10 : UserDefaults.standard.integer(forKey: stallMinutesKey)
    }
    @ObservationIgnored private var notificationsEnabled = false
    /// Worktree being looked at: no banner for it.
    @ObservationIgnored var focusedWorktree: UUID? {
        didSet { if let focusedWorktree { clear(focusedWorktree) } }
    }

    /// Orca's agents, for the worktrees that came from Orca (set by the app).
    @ObservationIgnored var orca: OrcaCenter?
    /// A worktree's agent has just finished (reviews start from here).
    @ObservationIgnored var onFinished: ((Worktree) -> Void)?

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
        var nextStalls: [UUID: Stall] = [:]
        let threshold = TimeInterval(Self.stallMinutes * 60)
        for office in store.offices {
            for worktree in office.worktrees {
                if worktree.agentProfileID != nil,
                   let stall = StatusEngine.stall(of: sessions.infos[SessionManager.sessionID(for: worktree)], after: threshold),
                   ignoredStalls[worktree.id] != stall.since {
                    nextStalls[worktree.id] = stall
                    if announcedStalls[worktree.id] != stall.since {
                        announcedStalls[worktree.id] = stall.since
                        stalled(worktree, in: office.project, stall)
                    }
                }
                // A worktree from Orca without an agent of Bullpen's: its state is Orca's agent's
                // (even with a plain terminal open here).
                let status = (worktree.agentProfileID == nil ? orca?.status(for: worktree) : nil) ?? sessions.status(for: worktree)
                next[worktree.id] = status
                let old = statuses[worktree.id]?.state
                if old != nil, old != status.state { changed(worktree, in: office.project, to: status) }
            }
        }
        if nextStalls != stalls { stalls = nextStalls }
        guard next != statuses else { return }
        statuses = next
        let waiting = next.values.filter { $0.state == .needsYou }.count
        let badge = waiting > 0 ? "\(waiting)" : nil
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
    }

    private func changed(_ worktree: Worktree, in project: Project, to status: AgentStatus) {
        // Each finished turn leaves a checkpoint to compare with or go back to (PLAN §11.3).
        if status.state == .done {
            onFinished?(worktree)
            Task.detached {
                let repo = try? await Repository.open(at: URL(fileURLWithPath: project.path))
                let time = Date().formatted(date: .omitted, time: .shortened)
                _ = try? await repo?.createCheckpoint(of: worktree.id, in: URL(fileURLWithPath: worktree.path), message: "Turno terminado · \(time)")
            }
        }
        let title: String, event: AlertSounds.Event
        switch status.state {
        case .needsYou: title = "\(worktree.branch) te necesita"; event = .needsYou
        case .done: title = "\(worktree.branch) ha terminado"; event = .done
        case .error: title = "\(worktree.branch) ha fallado"; event = .error
        default: return
        }
        // Reviewers finishing are not news (the review's verdict is).
        let quietReviewer = worktree.review != nil && event == .done
        let looking = worktree.id == focusedWorktree && NSApp.isActive
        // Played here rather than by the banner: it sounds with notifications off, and the sound is the user's choice.
        if !quietReviewer, !looking || UserDefaults.standard.bool(forKey: AlertSounds.whileLookingKey) { AlertSounds.play(event) }
        guard notificationsEnabled, !looking else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = project.name
        content.body = status.detail ?? ""
        content.threadIdentifier = worktree.id.uuidString
        // Same identifier per worktree: a new state replaces the previous banner.
        let request = UNNotificationRequest(identifier: worktree.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func stalled(_ worktree: Worktree, in project: Project, _ stall: Stall) {
        let looking = worktree.id == focusedWorktree && NSApp.isActive
        if !looking || UserDefaults.standard.bool(forKey: AlertSounds.whileLookingKey) { AlertSounds.play(.stuck) }
        guard notificationsEnabled, !looking else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(worktree.branch) parece atascado"
        content.subtitle = project.name
        content.body = "\(stall.description().prefix(1).uppercased())\(stall.description().dropFirst()). Ábrelo para interrumpirlo o dejarlo seguir."
        content.threadIdentifier = worktree.id.uuidString
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: worktree.id.uuidString, content: content, trigger: nil))
    }

    /// "Let it be": no banner until it moves on and gets stuck again.
    func ignoreStall(of worktree: UUID) {
        guard let stall = stalls[worktree] else { return }
        ignoredStalls[worktree] = stall.since
        stalls[worktree] = nil
    }

    func clear(_ worktree: UUID) {
        guard notificationsEnabled else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [worktree.uuidString])
    }
}
