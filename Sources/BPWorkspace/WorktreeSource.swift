import Foundation

/// What the "Crear desde" search box understands when creating a worktree: ticket keys and
/// URLs, remote branches, and free text turned into a branch name.
public enum WorktreeSource {
    /// `#123`, `123`, `ABC-123`, or a GitHub/Linear URL → the ticket key as the trackers write it.
    public static func ticketKey(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: t), let host = url.host {
            let parts = url.pathComponents
            if host.hasSuffix("github.com"), let i = parts.firstIndex(where: { $0 == "issues" || $0 == "pull" }), i + 1 < parts.count {
                return "#" + parts[i + 1]
            }
            if host.hasSuffix("linear.app"), let i = parts.firstIndex(of: "issue"), i + 1 < parts.count {
                return parts[i + 1].uppercased()
            }
            return nil
        }
        if t.range(of: #"^#?\d+$"#, options: .regularExpression) != nil { return t.hasPrefix("#") ? t : "#" + t }
        if t.range(of: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#, options: .regularExpression) != nil { return t.uppercased() }
        return nil
    }

    /// `origin/feature/x` → `feature/x`.
    public static func localName(_ remote: String) -> String {
        remote.split(separator: "/", maxSplits: 1).last.map(String.init) ?? remote
    }

    /// A typed name: used as is when it already looks like a branch, slugged when it's a phrase.
    public static func branchName(fromName name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.contains(" ") ? branchName(from: n) : n
    }

    /// "Arregla el timeout del login" → `arregla-timeout-login`: a few meaningful words, ASCII.
    public static func branchName(from task: String) -> String {
        let stop: Set<String> = ["el", "la", "los", "las", "de", "del", "en", "un", "una", "y", "a", "que", "the", "an", "of", "to", "and", "in", "for", "on", "con", "por", "para", "al"]
        let folded = task.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let chars: [Character] = folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : " "
        }
        let words: [String] = String(chars).split(separator: " ").map(String.init).filter { !stop.contains($0) }
        var name = ""
        for word in words.prefix(6) where name.count + word.count < 40 {
            name += name.isEmpty ? word : "-" + word
        }
        return name
    }
}
