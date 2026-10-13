import Foundation

/// GitHub issues through the `gh` CLI the user is already signed into.
public struct GitHubIssues: Sendable {
    public var gh: URL

    public init(gh: URL) { self.gh = gh }

    public func openIssues(in directory: URL, limit: Int = 50) async throws -> [Ticket] {
        let output = try await CLI.run(gh, ["issue", "list", "--state", "open", "--limit", "\(limit)",
                                            "--json", "number,title,body,url,labels,comments"], in: directory)
        return try Self.parse(Data(output.utf8))
    }

    static func parse(_ data: Data) throws -> [Ticket] {
        struct Issue: Decodable {
            struct Label: Decodable { var name: String }
            var number: Int
            var title: String
            var body: String?
            var url: String
            var labels: [Label]?
            var comments: [Comment]?
        }
        struct Comment: Decodable {
            struct Author: Decodable { var login: String }
            var author: Author?
            var body: String
            var createdAt: Date?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Issue].self, from: data).map {
            var ticket = Ticket(source: .github, trackerID: String($0.number), key: "#\($0.number)", title: $0.title,
                                body: $0.body ?? "", url: URL(string: $0.url), labels: $0.labels?.map(\.name) ?? [])
            ticket.comments = ($0.comments ?? []).map { .init(author: $0.author?.login ?? "?", body: $0.body, date: $0.createdAt) }
            return ticket
        }
    }
}

/// Minimal process runner (stdout or an error with stderr).
enum CLI {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func run(_ executable: URL, _ arguments: [String], in directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }
            let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
            process.terminationHandler = { p in
                Task {
                    let o = String(decoding: await stdout.value, as: UTF8.self)
                    let e = String(decoding: await stderr.value, as: UTF8.self)
                    if p.terminationStatus == 0 { continuation.resume(returning: o) }
                    else { continuation.resume(throwing: Failure(message: e.isEmpty ? "exit \(p.terminationStatus)" : e)) }
                }
            }
            do { try process.run() } catch {
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }
}
