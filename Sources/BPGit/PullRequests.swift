import Foundation

/// A pull request as Bullpen shows it next to a worktree (same states and glyphs as Orca).
public struct PullRequest: Equatable, Sendable {
    public enum State: String, Sendable { case open, draft, merged, closed }
    public enum Checks: String, Sendable { case none, pending, success, failure }

    public var number: Int
    public var state: State
    public var checks: Checks
    public var url: URL?
    public var branch: String

    public init(number: Int, state: State, checks: Checks, url: URL?, branch: String) {
        self.number = number
        self.state = state
        self.checks = checks
        self.url = url
        self.branch = branch
    }
}

/// An open pull request, to start a worktree on its branch.
public struct OpenPullRequest: Hashable, Sendable {
    public var number: Int
    public var title: String
    public var branch: String
    public var url: URL?
    public var isDraft: Bool

    public init(number: Int, title: String, branch: String, url: URL?, isDraft: Bool) {
        self.number = number
        self.title = title
        self.branch = branch
        self.url = url
        self.isDraft = isDraft
    }
}

/// Reads pull requests through the GitHub CLI (`gh`), which the user already has signed in.
public struct GitHubCLI: Sendable {
    public var executable: URL

    public init(executable: URL) { self.executable = executable }

    /// Finds `gh` in the usual places (a Finder-launched app has a minimal PATH).
    public static func locate() -> GitHubCLI? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/gh").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { GitHubCLI(executable: URL(fileURLWithPath: $0)) }
    }

    /// Latest PR per head branch for the repository at `directory` (one call per project).
    public func pullRequests(in directory: URL, limit: Int = 100) async throws -> [String: PullRequest] {
        let git = Git(executable: executable)  // same process runner; it is just another CLI
        let json = try await git.run([
            "pr", "list", "--state", "all", "--limit", "\(limit)",
            "--json", "number,headRefName,state,isDraft,url,statusCheckRollup",
        ], in: directory)
        return try Self.parse(Data(json.utf8))
    }

    /// Open pull requests of the repository at `directory`, newest first.
    public func openPullRequests(in directory: URL, limit: Int = 50) async throws -> [OpenPullRequest] {
        let git = Git(executable: executable)
        let json = try await git.run([
            "pr", "list", "--state", "open", "--limit", "\(limit)", "--json", "number,title,headRefName,url,isDraft",
        ], in: directory)
        return try Self.parseOpen(Data(json.utf8))
    }

    static func parseOpen(_ data: Data) throws -> [OpenPullRequest] {
        struct Item: Decodable { var number: Int; var title: String; var headRefName: String; var url: String; var isDraft: Bool }
        return try JSONDecoder().decode([Item].self, from: data).map {
            OpenPullRequest(number: $0.number, title: $0.title, branch: $0.headRefName, url: URL(string: $0.url), isDraft: $0.isDraft)
        }
    }

    static func parse(_ data: Data) throws -> [String: PullRequest] {
        struct Item: Decodable {
            var number: Int
            var headRefName: String
            var state: String
            var isDraft: Bool
            var url: String
            var statusCheckRollup: [Check]?
        }
        struct Check: Decodable {
            var status: String?
            var conclusion: String?
            var state: String?
        }
        var result: [String: PullRequest] = [:]
        // `gh pr list` is newest first: keep the first PR seen for each branch.
        for item in try JSONDecoder().decode([Item].self, from: data) where result[item.headRefName] == nil {
            let state: PullRequest.State = switch item.state {
            case "MERGED": .merged
            case "CLOSED": .closed
            default: item.isDraft ? .draft : .open
            }
            result[item.headRefName] = PullRequest(
                number: item.number, state: state,
                checks: rollup(item.statusCheckRollup?.map { ($0.status, $0.conclusion, $0.state) } ?? []),
                url: URL(string: item.url), branch: item.headRefName
            )
        }
        return result
    }

    /// Any failure wins, then anything still running, then success.
    static func rollup(_ checks: [(status: String?, conclusion: String?, state: String?)]) -> PullRequest.Checks {
        guard !checks.isEmpty else { return .none }
        var pending = false
        for check in checks {
            let value = (check.conclusion?.isEmpty == false ? check.conclusion : nil) ?? check.state ?? ""
            switch value.uppercased() {
            case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": return .failure
            case "SUCCESS", "NEUTRAL", "SKIPPED": continue
            default: pending = true   // PENDING, EXPECTED, or a run without conclusion yet
            }
        }
        return pending ? .pending : .success
    }
}

public extension GitHubCLI {
    /// `gh pr create` from the worktree; returns the new PR's URL.
    func createPullRequest(in directory: URL, base: String, head: String, title: String, body: String, draft: Bool) async throws -> URL? {
        let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent("bullpen-pr-\(UUID().uuidString).md")
        try body.write(to: bodyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        var args = ["pr", "create", "--base", base, "--head", head, "--title", title, "--body-file", bodyFile.path]
        if draft { args.append("--draft") }
        let output = try await Git(executable: executable).run(args, in: directory)
        return output.split(separator: "\n").last.flatMap { URL(string: String($0).trimmingCharacters(in: .whitespaces)) }
    }
}
