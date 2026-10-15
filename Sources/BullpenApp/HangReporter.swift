import AppKit
import Foundation
import os

/// Watches the main thread from a thread of its own while the app is in front. Each stall over a
/// quarter of a second goes to Diagnostics with its length; one still going after `sampleAfter`
/// is also sampled (`/usr/bin/sample`, 3 s) into ~/Library/Logs/Bullpen/ — a real freeze, caught
/// while it lasts. One sample every 10 minutes at most, so short stalls don't use it up.
enum HangReporter {
    static let threshold: TimeInterval = 0.25
    static let sampleAfter: TimeInterval = 0.75
    static var directory: URL { Diagnostics.directory }

    private static let log = Logger.bullpen("hangs")
    private static let active = OSAllocatedUnfairLock(initialState: false)
    @MainActor private static var started = false

    @MainActor
    static func start() {
        guard !started else { return }
        started = true
        let isActive = NSApp.isActive
        active.withLock { $0 = isActive }
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in active.withLock { $0 = true } }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in active.withLock { $0 = false } }
        let thread = Thread { watch() }
        thread.name = "Bullpen hang reporter"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func watch() {
        var lastReport = Date.distantPast
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            // In the background the system may hold the app back on purpose (App Nap): not a hang.
            guard active.withLock({ $0 }) else { continue }
            let answered = DispatchSemaphore(value: 0)
            // When the main thread got to it: the sample below must not count as part of the stall.
            let answeredAt = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
            let sent = DispatchTime.now()
            DispatchQueue.main.async {
                answeredAt.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
                answered.signal()
            }
            guard answered.wait(timeout: sent + threshold) == .timedOut else { continue }
            var file: URL?
            if answered.wait(timeout: sent + sampleAfter) == .timedOut {
                if Date().timeIntervalSince(lastReport) > 600 {
                    lastReport = Date()
                    file = sample()
                }
                answered.wait()
            }
            let end = answeredAt.withLock { $0 } ?? DispatchTime.now().uptimeNanoseconds
            let seconds = Double(end - sent.uptimeNanoseconds) / 1e9
            Diagnostics.note(String(format: "hang: main thread blocked %.2f s", seconds) + (file.map { ", sample \($0.lastPathComponent)" } ?? ""))
            log.warning("Main thread blocked for \(seconds, format: .fixed(precision: 1), privacy: .public) s\(file.map { ", sample in \($0.path)" } ?? "", privacy: .public)")
        }
    }

    /// Three seconds of the app's threads while the main one is stuck.
    private static func sample() -> URL? {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let file = directory.appendingPathComponent("hang-\(stamp).txt")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = ["\(getpid())", "3", "-file", file.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            // This thread exists for this: waiting on it holds nobody else up.
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                log.error("Hang sample failed: sample exited with \(process.terminationStatus, privacy: .public)")
                return nil
            }
            return file
        } catch {
            log.error("Hang sample failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
