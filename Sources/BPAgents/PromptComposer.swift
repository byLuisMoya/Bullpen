import Foundation

public struct PromptError: Error, LocalizedError, Equatable {
    public var unknownVariables: [String]
    public var errorDescription: String? {
        "Variables desconocidas en el prompt: " + unknownVariables.map { "{{\($0)}}" }.joined(separator: ", ")
    }
}

/// Builds the first prompt sent to an agent when a worktree is created (PLAN §6.5):
/// global prompt + project prompt + the task the user typed, with `{{variables}}` filled in.
public enum PromptComposer {
    public static func compose(global: String?, project: String?, task: String?, variables: [String: String]) throws -> String? {
        let parts = [global, project, task]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return try render(parts.joined(separator: "\n\n"), variables: variables)
    }

    /// Replaces `{{name}}`. Unknown names are an error: a prompt is never sent with silent blanks.
    public static func render(_ template: String, variables: [String: String]) throws -> String {
        let pattern = try NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_.]+)\s*\}\}"#)
        let ns = template as NSString
        var result = ""
        var unknown: [String] = []
        var cursor = 0
        for match in pattern.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = ns.substring(with: match.range(at: 1))
            if let value = variables[name] {
                result += value
            } else {
                unknown.append(name)
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        guard unknown.isEmpty else { throw PromptError(unknownVariables: unknown) }
        return result
    }

    public static func variables(projectName: String, branch: String, baseRef: String, path: String, task: String?) -> [String: String] {
        [
            "project.name": projectName,
            "worktree.branch": branch,
            "worktree.baseRef": baseRef,
            "worktree.path": path,
            "task.description": task ?? "",
            "user.name": NSFullUserName(),
        ]
    }
}
