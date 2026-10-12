/// Lifecycle of an agent session as reported by the StatusEngine (PLAN §8.1).
public enum AgentState: String, Codable, Sendable, CaseIterable {
    case starting
    case thinking
    case working
    case needsYou
    case done
    case idle
    case error
    case dead
    /// No reliable signal: never pretend the agent is working.
    case unknown

    /// Ordering used by the sidebar: what needs the human first.
    public var attentionRank: Int {
        switch self {
        case .needsYou: 0
        case .error: 1
        case .done: 2
        case .working, .thinking, .starting: 3
        case .idle: 4
        case .unknown: 5
        case .dead: 6
        }
    }
}
