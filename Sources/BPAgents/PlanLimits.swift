import Foundation

/// One rate-limit window of a subscription plan: how much of it is used and when it starts over.
public struct LimitWindow: Equatable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Length of the window (300 = the 5-hour session window, 10080 = the weekly one).
    public var minutes: Int

    public init(usedPercent: Double, resetsAt: Date?, minutes: Int) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.minutes = minutes
    }

    /// "3h 24m", "1d 4h", "12m" until the reset; nil when unknown or already past.
    public func remaining(from now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let seconds = Int(resetsAt.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }
}

/// What the main agent's account has used: plan windows for subscriptions, tokens for API keys.
public enum PlanUsage: Equatable, Sendable {
    /// Subscription (Claude Pro/Max, ChatGPT plans): the 5-hour session and the weekly window.
    case plan(session: LimitWindow?, weekly: LimitWindow?)
    /// Paid per token: today's tokens and estimated cost.
    case tokens(today: Int, costUSD: Double?)
    /// Prepaid account (DeepSeek, OpenRouter): what is left, and what was spent if known.
    case balance(remaining: Double, currency: String, spent: Double?)
    /// The agent's CLI isn't signed in, or Bullpen can't read its usage.
    case unavailable(String)
}

public enum PlanLimits {
    /// `GET https://api.anthropic.com/api/oauth/usage` (the endpoint Claude Code's /usage reads).
    /// `utilization` is a percentage; `resets_at` an ISO date.
    public static func parseClaude(_ data: Data) -> PlanUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String, minutes: Int) -> LimitWindow? {
            guard let w = json[key] as? [String: Any] else { return nil }
            guard let used = number(w["utilization"]) ?? number(w["used_percentage"]) else { return nil }
            return LimitWindow(usedPercent: used, resetsAt: date(w["resets_at"]), minutes: minutes)
        }
        let session = window("five_hour", minutes: 300), weekly = window("seven_day", minutes: 10080)
        guard session != nil || weekly != nil else { return nil }
        return .plan(session: session, weekly: weekly)
    }

    /// `GET https://chatgpt.com/backend-api/wham/usage` (what Codex shows in /status).
    public static func parseCodex(_ data: Data) -> PlanUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["rate_limit"] as? [String: Any] else { return nil }
        func window(_ key: String, fallback: Int) -> LimitWindow? {
            guard let w = limits[key] as? [String: Any], let used = number(w["used_percent"]) else { return nil }
            let seconds = number(w["limit_window_seconds"]).map { Int($0) } ?? fallback * 60
            return LimitWindow(usedPercent: used, resetsAt: date(w["reset_at"]), minutes: max(seconds / 60, 1))
        }
        let primary = window("primary_window", fallback: 300), secondary = window("secondary_window", fallback: 10080)
        guard primary != nil || secondary != nil else { return nil }
        // The shorter window is the session one, whichever slot it comes in.
        let windows = [primary, secondary].compactMap { $0 }.sorted { $0.minutes < $1.minutes }
        return windows.count == 2 ? .plan(session: windows[0], weekly: windows[1])
            : windows[0].minutes >= 10080 ? .plan(session: nil, weekly: windows[0]) : .plan(session: windows[0], weekly: nil)
    }

    /// `GET https://api.deepseek.com/user/balance`: `{"balance_infos": [{"currency", "total_balance"}]}`.
    public static func parseDeepSeekBalance(_ data: Data) -> PlanUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = json["balance_infos"] as? [[String: Any]], !infos.isEmpty else { return nil }
        let info = infos.first { $0["currency"] as? String == "USD" } ?? infos[0]
        guard let total = number(info["total_balance"]) else { return nil }
        return .balance(remaining: total, currency: info["currency"] as? String ?? "USD", spent: nil)
    }

    /// `GET https://openrouter.ai/api/v1/credits`: `{"data": {"total_credits", "total_usage"}}` in USD.
    public static func parseOpenRouterCredits(_ data: Data) -> PlanUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credits = json["data"] as? [String: Any],
              let total = number(credits["total_credits"]), let used = number(credits["total_usage"]) else { return nil }
        return .balance(remaining: total - used, currency: "USD", spent: used)
    }

    /// Claude Code's sign-in, as stored in the Keychain item "Claude Code-credentials" or
    /// `~/.claude/.credentials.json`: `{"claudeAiOauth": {"accessToken": …}}`.
    public static func claudeAccessToken(fromCredentials data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    /// Codex's sign-in in `~/.codex/auth.json`: ChatGPT tokens, or an API key (paid per token).
    public enum CodexAuth: Equatable, Sendable {
        case chatGPT(accessToken: String, accountID: String?)
        case apiKey
    }

    public static func codexAuth(from data: Data) -> CodexAuth? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let tokens = json["tokens"] as? [String: Any], let access = tokens["access_token"] as? String, !access.isEmpty {
            return .chatGPT(accessToken: access, accountID: tokens["account_id"] as? String)
        }
        if let key = json["OPENAI_API_KEY"] as? String, !key.isEmpty { return .apiKey }
        return nil
    }

    /// Tokens of a Codex session log (`~/.codex/sessions/…/rollout-*.jsonl`): its last
    /// `token_count` event carries the running total.
    public static func codexSessionTokens(_ log: String) -> Int {
        var total = 0
        for line in log.split(separator: "\n") where line.contains("token_count") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any],
                  let tokens = number(usage["total_tokens"]) else { continue }
            total = Int(tokens)
        }
        return total
    }

    /// `opencode stats --days 1`: a table with "Total Cost $0.01", "Input 11.7K", "Output 12",
    /// "Cache Read 0", "Cache Write 0" (K/M suffixes).
    public static func parseOpenCodeStats(_ text: String) -> PlanUsage? {
        func value(_ label: String) -> String? {
            for line in text.split(separator: "\n") {
                let row = line.trimmingCharacters(in: CharacterSet(charactersIn: "│| \t"))
                guard row.hasPrefix(label + " ") else { continue }
                return row.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        func tokens(_ label: String) -> Int? {
            guard var s = value(label)?.uppercased(), !s.isEmpty else { return nil }
            var factor = 1.0
            if s.hasSuffix("K") { factor = 1e3; s.removeLast() } else if s.hasSuffix("M") { factor = 1e6; s.removeLast() } else if s.hasSuffix("B") { factor = 1e9; s.removeLast() }
            return Double(s.replacingOccurrences(of: ",", with: "")).map { Int(($0 * factor).rounded()) }
        }
        let parts = ["Input", "Output", "Cache Read", "Cache Write"].compactMap(tokens)
        guard !parts.isEmpty else { return nil }
        let cost = value("Total Cost").flatMap { Double($0.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) }
        return .tokens(today: parts.reduce(0, +), costUSD: cost)
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// ISO 8601 (with or without fractions) or Unix seconds/milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let n = number(value), n > 0 { return Date(timeIntervalSince1970: n > 1e10 ? n / 1000 : n) }
        guard let s = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}
