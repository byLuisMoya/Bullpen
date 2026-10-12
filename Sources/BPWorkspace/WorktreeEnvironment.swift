import BPAgents
import BPCore
import BPEnv
import Foundation

/// `.bullpen.toml` applied to one worktree: its environment for every terminal, its setup and
/// teardown commands, and its repository prompt.
public struct WorktreeEnvironment: Sendable {
    public var config: BullpenConfig
    public var environment: [String: String]

    public static func variables(project: Project, worktree: Worktree) -> [String: String] {
        PromptComposer.variables(
            projectName: project.name, branch: worktree.branch, baseRef: worktree.baseRef,
            path: worktree.path, task: worktree.taskDescription
        )
    }

    /// Reads the config from the worktree (it is versioned) or, failing that, the main checkout.
    public static func load(project: Project, worktree: Worktree) throws -> WorktreeEnvironment {
        let inWorktree = URL(fileURLWithPath: worktree.path)
        let source = FileManager.default.fileExists(atPath: inWorktree.appendingPathComponent(BullpenConfig.fileName).path)
            ? inWorktree : URL(fileURLWithPath: project.path)
        let config = try BullpenConfig.load(from: source)
        var env = try config.resolvedEnvironment(ports: worktree.ports ?? [:], variables: variables(project: project, worktree: worktree))
        for (name, port) in worktree.ports ?? [:] {
            env["BULLPEN_PORT_\(name.uppercased().replacingOccurrences(of: "-", with: "_"))"] = String(port)
        }
        env["BULLPEN_WORKTREE"] = worktree.branch
        return WorktreeEnvironment(config: config, environment: env)
    }
}
