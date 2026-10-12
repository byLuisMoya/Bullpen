import BPCore
import BPEnv
import BPGit
import Foundation

/// What the judge sees about one candidate.
public struct Candidate: Sendable {
    public var branch: String
    public var agent: String
    public var diff: String
    public var verify: [CommandResult]?

    public init(branch: String, agent: String, diff: String, verify: [CommandResult]?) {
        self.branch = branch
        self.agent = agent
        self.diff = diff
        self.verify = verify
    }
}

/// Builds the request for the judge model (PLAN §11.2). Its answer is an opinion shown to the
/// user, never acted on automatically.
public enum RunJudge {
    public static let system = """
    Eres un revisor de código senior. Varios agentes han resuelto la misma tarea en ramas distintas. \
    Compáralos con criterio: corrección, que resuelvan la tarea pedida, riesgos, calidad y tamaño del cambio. \
    Los resultados de las verificaciones (tests, typecheck) pesan mucho. Responde en español, en Markdown: \
    primero una clasificación (mejor primero) con una frase por candidato, luego riesgos concretos, \
    y por último qué combinarías de cada uno si tiene sentido.
    """

    /// Per-candidate diff budget in characters; larger diffs are cut and the judge is told so.
    public static let diffBudget = 60_000

    public static func prompt(task: String, candidates: [Candidate]) -> String {
        var text = "## Tarea\n\n\(task)\n"
        for (i, c) in candidates.enumerated() {
            text += "\n## Candidato \(i + 1): rama `\(c.branch)` (\(c.agent))\n\n"
            if let verify = c.verify {
                text += verify.isEmpty ? "Verificación: sin comandos.\n" : "Verificación:\n" + verify.map {
                    "- `\($0.command)` → \($0.succeeded ? "OK" : "FALLA (\($0.exitCode))")" + ($0.succeeded ? "" : "\n```\n\($0.output.suffix(1500))\n```")
                }.joined(separator: "\n") + "\n"
            } else {
                text += "Verificación: no ejecutada.\n"
            }
            if c.diff.isEmpty {
                text += "\nSin cambios.\n"
            } else if c.diff.count > diffBudget {
                text += "\nDiff (MUY LARGO: se muestran los primeros \(diffBudget) de \(c.diff.count) caracteres; tenlo en cuenta):\n```diff\n\(c.diff.prefix(diffBudget))\n```\n"
            } else {
                text += "\nDiff:\n```diff\n\(c.diff)\n```\n"
            }
        }
        return text
    }
}

public extension Repository {
    /// Raw unified diff of a worktree against its base (committed, dirty and untracked).
    func rawDiff(in path: URL, baseRef: String) async throws -> String {
        let files = try await changes(in: path, baseRef: baseRef)
        return files.map { file in
            "--- \(file.oldPath ?? file.path)\n+++ \(file.path)\n" + file.hunks.map { hunk in
                hunk.header + "\n" + hunk.lines.map { line in
                    (line.kind == .added ? "+" : line.kind == .removed ? "-" : " ") + line.text
                }.joined(separator: "\n")
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
