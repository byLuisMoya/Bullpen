import Foundation

/// Linear through its GraphQL API with a personal API key (kept in the Keychain).
public struct LinearClient: Sendable {
    public var apiKey: String
    public var session: URLSession
    public static let endpoint = URL(string: "https://api.linear.app/graphql")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public struct Failure: Error, LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { "Linear: \(message)" }
    }

    /// Issues assigned to me that aren't finished, optionally only one team (by key, e.g. `FKPI`).
    public func myOpenIssues(team: String? = nil) async throws -> [Ticket] {
        let teamFilter = team.map { #", team: { key: { eq: "\#($0)" } }"# } ?? ""
        let query = """
        query { viewer { assignedIssues(first: 50, orderBy: updatedAt, filter: { state: { type: { nin: ["completed", "canceled"] } }\(teamFilter) }) {
          nodes { \(Self.issueFields) }
        } } }
        """
        return try Self.parseIssues(try await graphQL(query))
    }

    static let issueFields = """
    id identifier title description url branchName state { name } team { id } labels { nodes { name } }
    comments(first: 25) { nodes { body createdAt user { name displayName } botActor { name } } }
    """

    /// Any issue by its identifier (`FIT-3477`), whoever it's assigned to and whatever its state;
    /// nil when there is none.
    public func issue(_ identifier: String) async throws -> Ticket? {
        let query = "query($id: String!) { issue(id: $id) { \(Self.issueFields) } }"
        do {
            let data = try await graphQL(query, variables: ["id": identifier])
            return Self.parseNodes([data["issue"] as? [String: Any]].compactMap { $0 }).first
        } catch let failure as Failure where failure.message.localizedCaseInsensitiveContains("not found") {
            return nil
        }
    }

    /// Linear's own search (title, description, number) across the workspace.
    public func search(_ term: String, limit: Int = 8) async throws -> [Ticket] {
        let query = "query($term: String!, $first: Int!) { searchIssues(term: $term, first: $first) { nodes { \(Self.issueFields) } } }"
        let data = try await graphQL(query, variables: ["term": term, "first": limit])
        return Self.parseNodes(((data["searchIssues"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [])
    }

    /// Moves the issue to the team's first "started" state ("In Progress").
    public func markInProgress(_ ticket: Ticket) async throws {
        guard let team = ticket.teamID else { return }
        let states = try await workflowStates(team: team)
        guard let state = Self.state(in: states, matching: .inProgress) else { return }
        try await setState(issue: ticket.trackerID, state: state.id)
    }

    /// Moves to a started state named like "review", if the team has one.
    public func markInReview(_ ticket: Ticket) async throws {
        guard let team = ticket.teamID else { return }
        let states = try await workflowStates(team: team)
        guard let state = Self.state(in: states, matching: .inReview) else { return }
        try await setState(issue: ticket.trackerID, state: state.id)
    }

    public func comment(on ticket: Ticket, _ body: String) async throws {
        let mutation = "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }"
        _ = try await graphQL(mutation, variables: ["id": ticket.trackerID, "body": body])
    }

    struct WorkflowState: Equatable {
        var id: String
        var name: String
        var type: String
        var position: Double
    }

    enum Target { case inProgress, inReview }

    static func state(in states: [WorkflowState], matching target: Target) -> WorkflowState? {
        let started = states.filter { $0.type == "started" }.sorted { $0.position < $1.position }
        switch target {
        case .inProgress: return started.first { !$0.name.localizedCaseInsensitiveContains("review") } ?? started.first
        case .inReview: return started.first { $0.name.localizedCaseInsensitiveContains("review") }
        }
    }

    func workflowStates(team: String) async throws -> [WorkflowState] {
        let query = "query($id: String!) { team(id: $id) { states { nodes { id name type position } } } }"
        let data = try await graphQL(query, variables: ["id": team])
        let nodes = ((data["team"] as? [String: Any])?["states"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap { n in
            guard let id = n["id"] as? String, let name = n["name"] as? String, let type = n["type"] as? String else { return nil }
            return WorkflowState(id: id, name: name, type: type, position: (n["position"] as? Double) ?? 0)
        }
    }

    func setState(issue: String, state: String) async throws {
        let mutation = "mutation($id: String!, $state: String!) { issueUpdate(id: $id, input: { stateId: $state }) { success } }"
        _ = try await graphQL(mutation, variables: ["id": issue, "state": state])
    }

    func graphQL(_ query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            throw Failure(message: first["message"] as? String ?? "error")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let payload = json["data"] as? [String: Any] else {
            throw Failure(message: "respuesta \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return payload
    }

    static func parseComments(_ value: Any?) -> [Ticket.Comment] {
        let nodes = (value as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return nodes.compactMap { c -> Ticket.Comment? in
            guard let body = c["body"] as? String else { return nil }
            let user = c["user"] as? [String: Any], bot = c["botActor"] as? [String: Any]
            let author = (user?["displayName"] as? String) ?? (user?["name"] as? String) ?? (bot?["name"] as? String) ?? "?"
            return Ticket.Comment(author: author, body: body, date: (c["createdAt"] as? String).flatMap(iso.date(from:)))
        }
        .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    static func parseIssues(_ data: [String: Any]) throws -> [Ticket] {
        parseNodes((((data["viewer"] as? [String: Any])?["assignedIssues"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [])
    }

    static func parseNodes(_ nodes: [[String: Any]]) -> [Ticket] {
        nodes.compactMap { n in
            guard let id = n["id"] as? String, let key = n["identifier"] as? String, let title = n["title"] as? String else { return nil }
            let labels = ((n["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            return Ticket(
                source: .linear, trackerID: id, key: key, title: title, body: n["description"] as? String ?? "",
                url: (n["url"] as? String).flatMap(URL.init(string:)), branchName: n["branchName"] as? String,
                labels: labels, state: (n["state"] as? [String: Any])?["name"] as? String,
                teamID: (n["team"] as? [String: Any])?["id"] as? String,
                comments: parseComments(n["comments"])
            )
        }
    }
}

/// What to ask Linear for from the text typed in the new-worktree search: issues by identifier
/// (a URL, `FIT-3477`, `fit-3477`, or a bare number with each known team key) and a term for
/// Linear's search (a number or words), so tickets not assigned to me or closed are found too.
public struct LinearLookup: Equatable, Sendable {
    public var identifiers: [String] = []
    public var searchTerm: String?
    /// A bare number: search results only count when their number is this one.
    public var number: String?

    public static func parse(_ text: String, teams: [String]) -> LinearLookup {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lookup = LinearLookup()
        if let url = URL(string: t), let host = url.host {
            let parts = url.pathComponents
            if host.hasSuffix("linear.app"), let i = parts.firstIndex(of: "issue"), i + 1 < parts.count {
                lookup.identifiers = [parts[i + 1].uppercased()]
            }
            return lookup
        }
        if t.range(of: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#, options: .regularExpression) != nil {
            lookup.identifiers = [t.uppercased()]
        } else if let digits = t.range(of: #"^#?\d+$"#, options: .regularExpression).map({ String(t[$0].drop { $0 == "#" }) }) {
            lookup.identifiers = teams.map { "\($0.uppercased())-\(digits)" }
            lookup.searchTerm = digits
            lookup.number = digits
        } else if t.count >= 3 {
            lookup.searchTerm = t
        }
        return lookup
    }

    public var isEmpty: Bool { identifiers.isEmpty && searchTerm == nil }
}
