import Foundation

/// `.bullpen.toml` at the repository root: how to prepare, run and check every worktree
/// (PLAN §6.2, §6.5). Versioned with the code, so the whole team shares it.
public struct BullpenConfig: Equatable, Sendable {
    public static let fileName = ".bullpen.toml"

    /// Ignored files copied from the main checkout (`.env`…).
    public var copy: [String] = []
    /// Folders cloned from the main checkout with APFS copy-on-write (`node_modules`…): instant, no extra disk.
    public var clone: [String] = []
    /// Commands run in the worktree's terminal before the agent starts.
    public var setup: [String] = []
    /// Environment for every terminal of the worktree; values may use `{{port:name}}` and worktree variables.
    public var env: [String: String] = [:]
    /// Commands run before the worktree is removed.
    public var teardown: [String] = []
    /// Checks for "is this done?" (tests, typecheck…).
    public var verify: [String] = []
    /// Prompt sent to agents in this repo, between the global and the project prompt.
    public var prompt: String?
    /// Extra prompt per agent id (`[prompt.agents.claude] append = "…"`).
    public var agentPrompts: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool { self == BullpenConfig() }

    public init(toml text: String) throws {
        let root = try TOML.parse(text)
        copy = root["setup"]?["copy"]?.strings ?? []
        clone = root["setup"]?["clone"]?.strings ?? []
        setup = root["setup"]?["run"]?.strings ?? []
        teardown = root["teardown"]?["run"]?.strings ?? []
        verify = root["verify"]?["run"]?.strings ?? []
        prompt = root["prompt"]?["default"]?.string
        for (key, value) in root["env"]?.table ?? [:] {
            switch value {
            case let .string(s): env[key] = s
            case let .int(n): env[key] = String(n)
            case let .bool(b): env[key] = String(b)
            default: break
            }
        }
        for (agent, value) in root["prompt"]?["agents"]?.table ?? [:] {
            if let text = value["append"]?.string { agentPrompts[agent] = text }
        }
    }

    /// Reads `.bullpen.toml` from `directory`; a missing file is an empty config.
    public static func load(from directory: URL) throws -> BullpenConfig {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return BullpenConfig() }
        return try BullpenConfig(toml: String(contentsOf: url, encoding: .utf8))
    }

    /// Port names referenced as `{{port:name}}` in `env`.
    public var portNames: [String] {
        let regex = try! NSRegularExpression(pattern: #"\{\{\s*port:([A-Za-z0-9_-]+)\s*\}\}"#)
        var names: [String] = []
        for value in env.values.sorted() {
            let ns = value as NSString
            for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    /// Fills `{{port:name}}` and `{{variables}}` in `env`. Unknown names are an error.
    public func resolvedEnvironment(ports: [String: Int], variables: [String: String]) throws -> [String: String] {
        var all = variables
        for (name, port) in ports { all["port:\(name)"] = String(port) }
        return try env.mapValues { try Template.render($0, variables: all) }
    }
}

public struct TemplateError: Error, LocalizedError, Equatable {
    public var unknown: [String]
    public var errorDescription: String? { "Variables desconocidas: " + unknown.map { "{{\($0)}}" }.joined(separator: ", ") }
}

enum Template {
    static func render(_ text: String, variables: [String: String]) throws -> String {
        let regex = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_.:-]+)\s*\}\}"#)
        let ns = text as NSString
        var out = "", cursor = 0, unknown: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = ns.substring(with: match.range(at: 1))
            if let value = variables[name] { out += value } else { unknown.append(name) }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        if !unknown.isEmpty { throw TemplateError(unknown: unknown) }
        return out
    }
}
