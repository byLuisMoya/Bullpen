import BPProviders
import Foundation

/// Bullpen's own calls to model APIs (not the agents'): which model for which job, keys from the Keychain.
enum ModelJob: String { case quick, judge }

enum ModelService {
    static let keys = KeyStore()

    static func choice(for job: ModelJob) -> ModelChoice {
        guard let data = UserDefaults.standard.data(forKey: "model.\(job.rawValue)"),
              let choice = try? JSONDecoder().decode(ModelChoice.self, from: data) else {
            return job == .quick ? .quickDefault : .judgeDefault
        }
        return choice
    }

    static func setChoice(_ choice: ModelChoice, for job: ModelJob) {
        UserDefaults.standard.set(try? JSONEncoder().encode(choice), forKey: "model.\(job.rawValue)")
    }

    static func complete(_ job: ModelJob, _ request: CompletionRequest) async throws -> String {
        try await ModelClient(choice: effectiveChoice(for: job), apiKey: keys.key(for: effectiveChoice(for: job).provider)).complete(request)
    }

    /// The configured model, or the user's own Claude Code when that provider has no key yet:
    /// summaries and branch names then work out of the box with a Claude subscription.
    static func effectiveChoice(for job: ModelJob) -> ModelChoice {
        let configured = choice(for: job)
        let missingKey = configured.provider.needsKey && !keys.hasKey(for: configured.provider)
        guard missingKey, ClaudeCodeCLI.locate() != nil else { return configured }
        return ModelChoice(provider: .claudeCode, model: job == .quick ? "haiku" : "opus")
    }

    /// Something can answer: a key for the chosen provider, a local server, or Claude Code.
    static func available(for job: ModelJob) -> Bool {
        let choice = effectiveChoice(for: job)
        return !choice.provider.needsKey || keys.hasKey(for: choice.provider)
    }

    /// `fix/login-timeout` from a task description.
    static func suggestBranchName(for task: String, project: String) async throws -> String {
        let answer = try await complete(.quick, CompletionRequest(
            system: "Propones nombres de rama de git. Responde solo con el nombre, sin comillas ni explicación.",
            prompt: """
            Proyecto: \(project)
            Tarea: \(task)

            Nombre de rama corto en inglés, minúsculas y guiones, con prefijo feature/, fix/, chore/ o docs/ \
            según la tarea (por ejemplo fix/login-timeout). Máximo 40 caracteres.
            """,
            maxTokens: 2048, effort: "low"
        ))
        let line = answer.split(separator: "\n").first.map(String.init) ?? answer
        return line.trimmingCharacters(in: CharacterSet(charactersIn: " `\"'"))
    }
}
