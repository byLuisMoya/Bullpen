import AppKit
import Foundation
import os

/// Watches the main thread from a thread of its own. When it stops answering for over a second
/// while the app is in front, samples the app (`/usr/bin/sample`) into ~/Library/Logs/Bullpen/,
/// so the cause of an occasional freeze can be read afterwards. One report every 10 minutes at most.
enum HangReporter {
    static let threshold: TimeInterval = 1
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Bullpen", isDirectory: true)
    }

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
            let sent = DispatchTime.now()
            DispatchQueue.main.async { answered.signal() }
            guard answered.wait(timeout: sent + threshold) == .timedOut else { continue }
            var file: URL?
            if Date().timeIntervalSince(lastReport) > 600 {
                lastReport = Date()
                file = sample()
            }
            answered.wait()
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1e9
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
