import Foundation
import os

public enum Bullpen {
    public static let version = "0.1.2"
    public static let bundleIdentifier = "com.byluismoya.Bullpen"

    /// `~/Library/Application Support/Bullpen`
    public static func supportDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("Bullpen", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

public extension Logger {
    static func bullpen(_ category: String) -> Logger {
        Logger(subsystem: Bullpen.bundleIdentifier, category: category)
    }
}
