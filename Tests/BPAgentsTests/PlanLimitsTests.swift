@testable import BPAgents
import Foundation
import Testing

@Suite struct PlanLimitsTests {
    @Test func parsesClaudeUsage() throws {
        let json = #"{"five_hour":{"utilization":5.0,"resets_at":"2026-10-13T18:00:00.000000+00:00"},"seven_day":{"utilization":15,"resets_at":"2026-10-15T10:00:00+00:00"},"seven_day_opus":null}"#
        guard case let .plan(session, weekly)? = PlanLimits.parseClaude(Data(json.utf8)) else { Issue.record("no plan"); return }
        #expect(session?.usedPercent == 5)
        #expect(session?.minutes == 300)
        #expect(weekly?.usedPercent == 15)
        let reset = try #require(session?.resetsAt)
        #expect(reset == ISO8601DateFormatter().date(from: "2026-10-13T18:00:00Z"))
        #expect(PlanLimits.parseClaude(Data("{}".utf8)) == nil)
    }

    @Test func parsesCodexUsage() {
        let json = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_at":1760380000},"secondary_window":{"used_percent":7,"limit_window_seconds":604800,"reset_at":1760900000}}}"#
        guard case let .plan(session, weekly)? = PlanLimits.parseCodex(Data(json.utf8)) else { Issue.record("no plan"); return }
        #expect(session?.usedPercent == 42)
        #expect(session?.minutes == 300)
        #expect(weekly?.minutes == 10080)
        #expect(weekly?.resetsAt == Date(timeIntervalSince1970: 1760900000))
    }

    @Test func remainingTime() {
        let now = Date(timeIntervalSince1970: 0)
        func w(_ seconds: Double) -> LimitWindow { LimitWindow(usedPercent: 1, resetsAt: Date(timeIntervalSince1970: seconds), minutes: 300) }
        #expect(w(3 * 3600 + 24 * 60 + 5).remaining(from: now) == "3h 24m")
        #expect(w(86_400 + 4 * 3600 + 60).remaining(from: now) == "1d 4h")
        #expect(w(30).remaining(from: now) == "1m")
        #expect(w(-5).remaining(from: now) == nil)
    }

    @Test func readsSignIns() {
        #expect(PlanLimits.claudeAccessToken(fromCredentials: Data(#"{"claudeAiOauth":{"accessToken":"abc","refreshToken":"r"}}"#.utf8)) == "abc")
        #expect(PlanLimits.claudeAccessToken(fromCredentials: Data("{}".utf8)) == nil)
        #expect(PlanLimits.codexAuth(from: Data(#"{"tokens":{"access_token":"t","account_id":"acc"}}"#.utf8)) == .chatGPT(accessToken: "t", accountID: "acc"))
        #expect(PlanLimits.codexAuth(from: Data(#"{"OPENAI_API_KEY":"sk-x","tokens":null}"#.utf8)) == .apiKey)
    }

    @Test func codexSessionTokensUseTheLastTotal() {
        let log = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}
        {"type":"event_msg","payload":{"type":"agent_message"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250}}}}
        """
        #expect(PlanLimits.codexSessionTokens(log) == 250)
    }
}

@Suite struct BalanceTests {
    @Test func readsPrepaidBalances() {
        let deepseek = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"80.00"},{"currency":"USD","total_balance":"12.34","granted_balance":"0.00","topped_up_balance":"12.34"}]}"#
        #expect(PlanLimits.parseDeepSeekBalance(Data(deepseek.utf8)) == .balance(remaining: 12.34, currency: "USD", spent: nil))
        let openrouter = #"{"data":{"total_credits":20,"total_usage":7.5}}"#
        #expect(PlanLimits.parseOpenRouterCredits(Data(openrouter.utf8)) == .balance(remaining: 12.5, currency: "USD", spent: 7.5))
        #expect(PlanLimits.parseDeepSeekBalance(Data("{}".utf8)) == nil)
    }

    @Test func guessesTheAccountFromNameOrCommand() {
        #expect(AgentProfile(id: "x", name: "DeepSeek", executable: "ds").effectiveUsageSource == "deepseek")
        #expect(AgentProfile(id: "y", name: "Mío", executable: "aider", arguments: ["--model", "openrouter/qwen"]).effectiveUsageSource == "openrouter")
        #expect(AgentProfile(id: "z", name: "DeepSeek", executable: "ds", usageSource: "none").effectiveUsageSource == nil)
        #expect(AgentProfile.gemini.effectiveUsageSource == nil)
    }
}
