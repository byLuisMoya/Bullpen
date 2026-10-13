import BPCore
import Foundation
import Observation
import UserNotifications

/// "No molestar": for a while or every day at set hours, Bullpen makes no sound and shows no
/// banners. What arrives meanwhile is kept and summed up in one notification when it ends.
/// The Dock badge and the sidebar keep telling the truth all along.
@MainActor
@Observable
final class DoNotDisturb {
    static let shared = DoNotDisturb()

    static let untilKey = "dnd.until"
    static let scheduleKey = "dnd.schedule"
    static let fromKey = "dnd.from"
    static let toKey = "dnd.to"

    /// Silenced by hand until then (`.distantFuture`: until switched off).
    private(set) var until: Date?
    /// Refreshed by `start()`, for the menus.
    private(set) var isActive = false
    /// Titles of what was held back, for the summary.
    @ObservationIgnored private var held: [String] = []

    private init() {
        let stored = UserDefaults.standard.double(forKey: Self.untilKey)
        until = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        isActive = computeActive()
    }

    static var schedule: QuietHours? {
        guard UserDefaults.standard.bool(forKey: scheduleKey) else { return nil }
        let defaults = UserDefaults.standard
        return QuietHours(from: defaults.object(forKey: fromKey) as? Int ?? 21 * 60, to: defaults.object(forKey: toKey) as? Int ?? 8 * 60)
    }

    /// Right now, not as of the last refresh.
    var silencedNow: Bool { computeActive() }

    private func computeActive(_ now: Date = Date()) -> Bool {
        if let until, until > now { return true }
        return Self.schedule?.contains(now) ?? false
    }

    /// When the current quiet period ends (nil: not quiet, or until switched off).
    var endsAt: Date? {
        let now = Date()
        let manual = until.flatMap { $0 > now && $0 != .distantFuture ? $0 : nil }
        let scheduled = Self.schedule?.end(after: now)
        if until == .distantFuture { return nil }
        return [manual, scheduled].compactMap { $0 }.max()
    }

    func silence(until date: Date) {
        until = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.untilKey)
        refresh()
    }

    /// Ends the manual silence (a schedule in progress goes on).
    func resume() {
        until = nil
        UserDefaults.standard.removeObject(forKey: Self.untilKey)
        refresh()
    }

    /// Every notification goes through here: shown now, or kept for the summary.
    func deliver(_ request: UNNotificationRequest) {
        if computeActive() {
            held.append(request.content.title)
            return
        }
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .authorized else { return }
            try? await center.add(request)
        }
    }

    func start() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private func refresh() {
        let active = computeActive()
        if isActive, !active { summarize() }
        if active != isActive { isActive = active }
    }

    private func summarize() {
        guard !held.isEmpty else { return }
        let shown = held.prefix(4).joined(separator: " · ")
        let rest = held.count > 4 ? " y \(held.count - 4) más" : ""
        let content = UNMutableNotificationContent()
        content.title = held.count == 1 ? "Mientras no molestabas: 1 aviso" : "Mientras no molestabas: \(held.count) avisos"
        content.body = shown + rest
        held = []
        deliver(UNNotificationRequest(identifier: "dnd-summary", content: content, trigger: nil))
    }
}

import SwiftUI

/// "No molestar" in the menu bar and the app menu: for a while, until tomorrow, or off.
struct DoNotDisturbMenu: View {
    private var dnd: DoNotDisturb { .shared }

    var body: some View {
        Menu(dnd.isActive ? "No molestar: \(Self.describe(dnd.endsAt))" : "No molestar") {
            if dnd.until.map({ $0 > Date() }) == true {
                Button("Desactivar") { dnd.resume() }
                Divider()
            }
            Button("Durante 1 hora") { dnd.silence(until: Date().addingTimeInterval(3600)) }
            Button("Durante 2 horas") { dnd.silence(until: Date().addingTimeInterval(7200)) }
            Button("Hasta mañana a las 8:00") { dnd.silence(until: Self.tomorrow(at: 8)) }
            Button("Hasta que lo desactive") { dnd.silence(until: .distantFuture) }
        }
    }

    static func describe(_ end: Date?) -> String {
        guard let end else { return "activado" }
        let time = end.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(end) ? "hasta las \(time)" : "hasta mañana a las \(time)"
    }

    static func tomorrow(at hour: Int) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        return calendar.date(byAdding: .hour, value: hour, to: tomorrow)!
    }
}
