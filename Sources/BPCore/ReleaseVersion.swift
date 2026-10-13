import Foundation

/// A release version like `0.1.6` (tags are `v0.1.6`), compared number by number.
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let core = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let parts = core.split(separator: "-").first?.split(separator: ".").map { Int($0) } ?? []
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: Self, b: Self) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Self, b: Self) -> Bool { !(a < b) && !(b < a) }

    /// The hash for `file` in a `shasum -a 256` listing (`<hex>  <name>` per line).
    public static func sha256(for file: String, in sums: String) -> String? {
        for line in sums.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2, fields.last.map({ String($0).trimmingCharacters(in: CharacterSet(charactersIn: "*")) }) == file {
                return String(fields[0]).lowercased()
            }
        }
        return nil
    }
}
