import Foundation

/// ~/Library/Logs/Bullpen/timings.log: one line per slow thing (a freeze, a terminal slow to open,
/// typing slow to show), to tell afterwards where a wait came from. Kept under 1 MB.
enum Diagnostics {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Bullpen", isDirectory: true)
    }
    static var file: URL { directory.appendingPathComponent("timings.log") }

    private static let queue = DispatchQueue(label: "bullpen.diagnostics", qos: .utility)
    /// Local date and time, to match what the user remembers and the hang-*.txt next to it.
    nonisolated(unsafe) private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func note(_ line: String) {
        let now = Date()
        queue.async {
            let text = stamp.string(from: now) + " " + line + "\n"
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 1_000_000 {
                let old = file.deletingPathExtension().appendingPathExtension("old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            // The throwing API: the old `write(_:)` raises an exception (a crash) on a full disk.
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(text.utf8))
                try? handle.close()
            } else {
                try? Data(text.utf8).write(to: file)
            }
        }
    }
}
