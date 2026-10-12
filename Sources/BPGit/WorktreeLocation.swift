import Foundation

/// Where Bullpen puts worktrees: `~/Bullpen/worktrees/<project>/<branch>` (PLAN §6.1),
/// outside the repo so editors and file watchers on the main checkout are not disturbed.
public enum WorktreeLocation {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Bullpen/worktrees", isDirectory: true)
    }

    public static func path(project: String, branch: String, root: URL = defaultRoot) -> URL {
        root.appendingPathComponent(slug(project), isDirectory: true)
            .appendingPathComponent(slug(branch), isDirectory: true)
    }

    /// `luis/Fix login!` → `luis-fix-login`
    public static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = s.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
