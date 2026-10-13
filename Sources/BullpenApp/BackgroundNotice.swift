import Foundation
import os
import UserNotifications

/// What Bullpen did (or failed to do) on its own: a notification, never an alert that stops the
/// user over something they didn't ask for. Logged too, for when notifications are off.
enum BackgroundNotice {
    private static let log = Logger.bullpen("notice")

    static func post(id: String, title: String, body: String, failure: Bool = false) {
        if failure {
            log.error("\(title, privacy: .public): \(body, privacy: .public)")
        } else {
            log.info("\(title, privacy: .public): \(body, privacy: .public)")
        }
        // UNUserNotificationCenter needs a real app bundle (not `swift run`).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        Task { @MainActor in DoNotDisturb.shared.deliver(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
    }
}
