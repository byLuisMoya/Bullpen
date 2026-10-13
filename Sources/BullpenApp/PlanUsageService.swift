import BPAgents
import BPHabitat
import Foundation
import SwiftUI

/// The agent the user works with most. Its plan usage sits next to Settings, and new worktrees
/// start with it.
enum PrimaryAgent {
    static let key = "primaryAgent"
    static var id: String { UserDefaults.standard.string(forKey: key) ?? AgentProfile.claude.id }
}

/// Reads how much of the main agent's plan is used, through the agent's own sign-in: the same
/// endpoints Claude Code's /usage and Codex's /status read. Nothing is stored; the token is read
/// on each refresh and only sent to the agent's own provider.
enum PlanUsageService {
    static func fetch(agent: String, claudeTokensToday: UsageTotals) async -> PlanUsage {
        switch agent {
        case AgentProfile.claude.id: await claude(tokensToday: claudeTokensToday)
        case AgentProfile.codex.id: await codex()
        default: .unavailable("Sin datos de uso para \(AgentProfile.named(agent)?.name ?? agent)")
        }
    }

    // MARK: Claude

    private static func claude(tokensToday: UsageTotals) async -> PlanUsage {
        guard let token = await claudeToken() else {
            // No subscription sign-in: an API key pays per token.
            return .tokens(today: tokensToday.totalTokens, costUSD: tokensToday.costUSD)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0 (Bullpen)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return .unavailable("Abre Claude Code para renovar la sesión") }
            guard status == 200, let usage = PlanLimits.parseClaude(data) else {
                return .unavailable("Claude no devolvió el uso (HTTP \(status))")
            }
            return usage
        } catch {
            return .unavailable("Sin conexión con Claude")
        }
    }

    /// Claude Code keeps its sign-in in the login Keychain (written with `security`, so reading
    /// it the same way doesn't prompt), or in ~/.claude/.credentials.json on some setups.
    private static func claudeToken() async -> String? {
        let fromKeychain = await Task.detached { () -> Data? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
        if let data = fromKeychain, let token = PlanLimits.claudeAccessToken(fromCredentials: data) { return token }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        return (try? Data(contentsOf: file)).flatMap(PlanLimits.claudeAccessToken(fromCredentials:))
    }

    // MARK: Codex

    private static var codexHome: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty { return URL(fileURLWithPath: home) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private static func codex() async -> PlanUsage {
        guard let data = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")),
              let auth = PlanLimits.codexAuth(from: data) else {
            return .unavailable("Inicia sesión en Codex (codex login)")
        }
        switch auth {
        case .apiKey:
            return .tokens(today: await codexTokensToday(), costUSD: nil)
        case let .chatGPT(token, account):
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 10)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
            if let account { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 { return .unavailable("Abre Codex para renovar la sesión") }
                guard status == 200, let usage = PlanLimits.parseCodex(data) else {
                    return .unavailable("Codex no devolvió el uso (HTTP \(status))")
                }
                return usage
            } catch {
                return .unavailable("Sin conexión con Codex")
            }
        }
    }

    /// Today's sessions live in ~/.codex/sessions/YYYY/MM/DD.
    private static func codexTokensToday() async -> Int {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dir = codexHome.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
        return await Task.detached {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "jsonl" }.reduce(0) { sum, file in
                sum + PlanLimits.codexSessionTokens((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            }
        }.value
    }
}

/// Next to the Settings button: "● 5% usado 3h 24m · 15% usado 1d 4h" for the main agent.
struct PlanUsageBadge: View {
    @Environment(UsageCenter.self) private var usage
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PrimaryAgent.key) private var agentID = AgentProfile.claude.id

    var body: some View {
        Button {
            openWindow(id: "usage")
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(rgb: CharacterLook.shirtColor(agent: agentID)))
                    .frame(width: 7, height: 7)
                ViewThatFits(in: .horizontal) {
                    Text(text(compact: false))
                    Text(text(compact: true))
                }
                .foregroundStyle(levelColor)
            }
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(help)
        .task(id: agentID) { await usage.refreshPlan() }
    }

    private func text(compact: Bool) -> String {
        switch usage.plan {
        case nil:
            return "…"
        case let .plan(session, weekly):
            func part(_ w: LimitWindow?) -> String? {
                guard let w else { return nil }
                let pct = "\(Int(w.usedPercent.rounded()))%"
                if compact { return pct }
                return ["\(pct) usado", w.remaining()].compactMap { $0 }.joined(separator: " ")
            }
            return [part(session), part(weekly)].compactMap { $0 }.joined(separator: " · ")
        case let .tokens(today, cost):
            let tokens = "\(UsageWindow.tokens(today)) tokens hoy"
            guard !compact, let cost, cost > 0 else { return tokens }
            return "\(tokens) · \(UsageWindow.money(cost))"
        case let .unavailable(reason):
            return compact ? "sin datos" : reason
        }
    }

    private var levelColor: Color {
        guard case let .plan(session, weekly) = usage.plan else { return .secondary }
        let worst = max(session?.usedPercent ?? 0, weekly?.usedPercent ?? 0)
        return worst >= 90 ? .red : worst >= 70 ? .orange : .secondary
    }

    private var help: String {
        let name = AgentProfile.named(agentID)?.name ?? agentID
        var lines = ["Uso de \(name) (agente principal)"]
        if case let .plan(session, weekly) = usage.plan {
            let date = Date.FormatStyle(date: .abbreviated, time: .shortened)
            if let session {
                lines.append("Sesión de 5 h: \(Int(session.usedPercent.rounded()))% usado"
                             + (session.resetsAt.map { ", se renueva \($0.formatted(date))" } ?? ""))
            }
            if let weekly {
                lines.append("Semana: \(Int(weekly.usedPercent.rounded()))% usado"
                             + (weekly.resetsAt.map { ", se renueva \($0.formatted(date))" } ?? ""))
            }
        }
        if let updated = usage.planUpdated { lines.append("Actualizado \(updated.formatted(date: .omitted, time: .shortened))") }
        lines.append("Cambia el agente principal en Ajustes › General. Clic: ventana de uso.")
        return lines.joined(separator: "\n")
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
