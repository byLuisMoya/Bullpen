import BPCore
import BPEnv
import Foundation

public extension Workspace {
    /// The page this worktree's browser tab opens: `[browser] url` from `.bullpen.toml` with its
    /// ports filled in, or `http://localhost:<preview port>`, a port reserved for this worktree.
    /// Ports it lacks (worktrees older than the config, or from Orca) are reserved and saved now.
    func browserURL(for worktree: Worktree, in project: Project) throws -> String {
        let inWorktree = URL(fileURLWithPath: worktree.path)
        let source = FileManager.default.fileExists(atPath: inWorktree.appendingPathComponent(BullpenConfig.fileName).path)
            ? inWorktree : URL(fileURLWithPath: project.path)
        let config = (try? BullpenConfig.load(from: source)) ?? BullpenConfig()
        let needed = config.browserURL == nil ? ["preview"] : config.portNames
        var current = worktree
        let missing = needed.filter { current.ports?[$0] == nil }
        if !missing.isEmpty {
            let taken = Set(try database.offices().flatMap(\.worktrees).flatMap { Array(($0.ports ?? [:]).values) })
            var ports = current.ports ?? [:]
            ports.merge(PortAllocator.allocate(names: missing, taken: taken)) { old, _ in old }
            current.ports = ports
            try database.save(current)
        }
        let ports = current.ports ?? [:]
        if let url = try config.resolvedBrowserURL(ports: ports, variables: WorktreeEnvironment.variables(project: project, worktree: current)) {
            return url
        }
        return "http://localhost:\(ports["preview"] ?? 3000)"
    }
}
