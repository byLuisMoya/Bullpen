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
        let choice = choice(for: job)
        return try await ModelClient(choice: choice, apiKey: keys.key(for: choice.provider)).complete(request)
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
