import Foundation

/// Model APIs Bullpen can call for its own small jobs (PLAN §7.2): branch names, status
/// summaries, PR descriptions and judging fan-out results. Agents in worktrees don't use these.
public enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case anthropic, openai, gemini, openrouter, ollama, lmstudio

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        case .openrouter: "OpenRouter"
        case .ollama: "Ollama (local)"
        case .lmstudio: "LM Studio (local)"
        }
    }

    /// Local servers need no key.
    public var needsKey: Bool { self != .ollama && self != .lmstudio }

    public var defaultBaseURL: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com")!
        case .openai: URL(string: "https://api.openai.com/v1")!
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        case .openrouter: URL(string: "https://openrouter.ai/api/v1")!
        case .ollama: URL(string: "http://localhost:11434/v1")!
        case .lmstudio: URL(string: "http://localhost:1234/v1")!
        }
    }

    /// Suggestions for the model field; any id can be typed.
    public var suggestedModels: [String] {
        switch self {
        case .anthropic: ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
        default: []
        }
    }
}

/// Which provider and model to use for a kind of job.
public struct ModelChoice: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var model: String
    /// Only used by local/OpenAI-compatible servers on a non-default address.
    public var baseURL: URL?

    public init(provider: ProviderID, model: String, baseURL: URL? = nil) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
    }

    /// Quick, cheap jobs (branch names, one-line summaries).
    public static let quickDefault = ModelChoice(provider: .anthropic, model: "claude-haiku-5-5")
    /// Judging several agents' results: the most capable model.
    public static let judgeDefault = ModelChoice(provider: .anthropic, model: "claude-opus-5-5")
}

public struct CompletionRequest: Sendable {
    public var system: String?
    public var prompt: String
    public var maxTokens: Int
    /// Anthropic effort level (low/medium/high/xhigh/max); ignored by other providers.
    public var effort: String?

    public init(system: String? = nil, prompt: String, maxTokens: Int = 4096, effort: String? = nil) {
        self.system = system
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.effort = effort
    }
}

public struct ProviderError: Error, LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}
