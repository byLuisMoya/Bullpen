import BPAgents
import BPCore
import BPWorkspace
import Foundation
import Observation
import SwiftUI

/// Token usage per worktree from Claude Code transcripts, plus today's total (PLAN §7.3).
@MainActor
@Observable
final class UsageCenter {
    private(set) var usage: [UUID: UsageTotals] = [:]
    private(set) var today = UsageTotals()
    /// The main agent's plan usage (PlanUsageBadge), refreshed every couple of minutes.
    private(set) var plan: PlanUsage?
    private(set) var planUpdated: Date?
    @ObservationIgnored private let reader = TranscriptUsageReader()

    func start(store: BuildingStore, sessions: SessionManager) async {
        while !Task.isCancelled {
            await refresh(store: store, sessions: sessions)
            if Date().timeIntervalSince(planUpdated ?? .distantPast) >= 120 { await refreshPlan() }
            await Pacing.pause(active: 20, background: 60)
        }
    }

    func refreshPlan() async {
        plan = await PlanUsageService.fetch(agent: PrimaryAgent.id, claudeTokensToday: today)
        planUpdated = Date()
    }

    func refresh(store: BuildingStore, sessions: SessionManager) async {
        let paths = store.offices.flatMap(\.worktrees).compactMap { wt -> (UUID, String)? in
            sessions.infos[Workspace.sessionID(for: wt)]?.agentActivity?.transcriptPath.map { (wt.id, $0) }
        }
        let reader = self.reader
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let result = await offPool {
            paths.map { id, path in (id, reader.totals(for: path), reader.totals(for: path, since: startOfDay)) }
        }
        let nextUsage = Dictionary(result.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        if nextUsage != usage { usage = nextUsage }
        let nextToday = result.reduce(UsageTotals()) { $0 + $1.2 }
        if nextToday != today { today = nextToday }
    }
}

enum Limits {
    /// 0 = no limit.
    static var maxAgents: Int { UserDefaults.standard.integer(forKey: "limits.maxAgents") }
    /// 0 = no limit. Estimated at API prices.
    static var dailyBudget: Double { UserDefaults.standard.double(forKey: "limits.dailyBudget") }
}

struct UsageWindow: View {
    @Environment(BuildingStore.self) private var store
    @Environment(UsageCenter.self) private var usage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Hoy: \(Self.money(usage.today.costUSD))").font(.title2.bold())
                if Limits.dailyBudget > 0 {
                    Text("de \(Self.money(Limits.dailyBudget))").foregroundStyle(.secondary)
                    ProgressView(value: min(usage.today.costUSD / Limits.dailyBudget, 1)).frame(width: 140)
                }
                Spacer()
                Text("\(Self.tokens(usage.today.totalTokens)) tokens").foregroundStyle(.secondary)
            }
            Table(rows) {
                TableColumn("Worktree") { Text($0.branch) }
                TableColumn("Proyecto") { Text($0.project) }
                TableColumn("Mensajes") { Text("\($0.usage.messages)").monospacedDigit() }
                TableColumn("Entrada") { Text(Self.tokens($0.usage.input + $0.usage.cacheWrite)).monospacedDigit() }
                TableColumn("Caché") { Text(Self.tokens($0.usage.cacheRead)).monospacedDigit() }
                TableColumn("Salida") { Text(Self.tokens($0.usage.output)).monospacedDigit() }
                TableColumn("Coste est.") { Text(Self.money($0.usage.costUSD)).monospacedDigit() }
            }
            Text("Estimación a precios de API a partir de las transcripciones de Claude Code. Con suscripción no pagas por token; sirve como referencia. Codex y otros agentes aún no se cuentan.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 720, minHeight: 360)
    }

    private struct Row: Identifiable {
        var id: UUID
        var branch: String
        var project: String
        var usage: UsageTotals
    }

    private var rows: [Row] {
        store.offices.flatMap { office in
            office.worktrees.compactMap { wt in
                usage.usage[wt.id].map { Row(id: wt.id, branch: wt.branch, project: office.project.name, usage: $0) }
            }
        }
        .sorted { $0.usage.costUSD > $1.usage.costUSD }
    }

    static func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }
}
