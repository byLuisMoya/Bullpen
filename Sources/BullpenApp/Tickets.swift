import BPAgents
import BPCore
import BPEnv
import BPGit
import BPIntegrations
import SwiftUI

/// Ticket sources for a project and the follow-ups on their state (PLAN §11.5).
enum Tickets {
    static var linearKey: String? { ModelService.keys.secret("linear") }
    static var updateLinear: Bool { UserDefaults.standard.object(forKey: "tickets.updateLinear") as? Bool ?? true }

    static func load(project: Project) async -> (tickets: [Ticket], problems: [String]) {
        var tickets: [Ticket] = [], problems: [String] = []
        let config = (try? BullpenConfig.load(from: URL(fileURLWithPath: project.path))) ?? BullpenConfig()
        if let gh = GitHubCLI.locate() {
            do {
                tickets += try await GitHubIssues(gh: gh.executable).openIssues(in: URL(fileURLWithPath: project.path))
            } catch {
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                // Issues switched off in the repo is a setting, not a failure: the PRs still show.
                if !message.contains("disabled issues") { problems.append("GitHub: " + message) }
            }
        }
        if let key = linearKey {
            do {
                tickets += try await LinearClient(apiKey: key).myOpenIssues(team: config.linearTeam)
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        return (tickets, problems)
    }

    /// The task text for a ticket, from `[prompt.sources.<source>] template` or the default.
    static func task(for ticket: Ticket, project: Project) -> String {
        let config = (try? BullpenConfig.load(from: URL(fileURLWithPath: project.path))) ?? BullpenConfig()
        let key = ticket.source == .github ? "github_issue" : "linear"
        let template = config.sourceTemplates[key] ?? Ticket.defaultTemplate
        let text = (try? PromptComposer.render(template, variables: ticket.variables))
            ?? (try? PromptComposer.render(Ticket.defaultTemplate, variables: ticket.variables)) ?? ticket.title
        // Without comments, `{{ticket.comments}}` leaves an empty last line.
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func started(_ ref: TicketRef) async throws {
        guard ref.source == "linear", updateLinear, let key = linearKey else { return }
        try await LinearClient(apiKey: key).markInProgress(Ticket(ref: ref))
    }

    static func pullRequestOpened(_ ref: TicketRef, url: URL?) async throws {
        guard ref.source == "linear", updateLinear, let key = linearKey else { return }
        let client = LinearClient(apiKey: key)
        try await client.markInReview(Ticket(ref: ref))
        if let url { try await client.comment(on: Ticket(ref: ref), "PR abierta desde Bullpen: \(url.absoluteString)") }
    }

    /// Closes the GitHub issue when the PR merges.
    static func pullRequestBodySuffix(_ ref: TicketRef?) -> String {
        guard let ref, ref.source == "github" else { return "" }
        return "\n\nCloses \(ref.key)\n"
    }
}

struct TicketPicker: View {
    let project: Project
    var onPick: (Ticket) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tickets: [Ticket] = []
    @State private var problems: [String] = []
    @State private var loading = true
    @State private var search = ""

    private var filtered: [Ticket] {
        search.isEmpty ? tickets : tickets.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.key.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tickets de \(project.name)").font(.headline)
                Spacer()
                TextField("Buscar", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if filtered.isEmpty {
                ContentUnavailableView("Sin tickets", systemImage: "tray",
                                       description: Text(Tickets.linearKey == nil ? "Añade tu clave de Linear en Ajustes › Integraciones para ver tus tickets." : "No hay tickets abiertos asignados."))
                    .frame(minHeight: 200)
            } else {
                List(filtered) { ticket in
                    Button {
                        onPick(ticket)
                        dismiss()
                    } label: {
                        HStack {
                            Text(ticket.key).font(.callout.monospaced()).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                            Text(ticket.title).lineLimit(1)
                            Spacer()
                            if let state = ticket.state { Text(state).font(.caption).foregroundStyle(.secondary) }
                            Image(systemName: ticket.source == .github ? "chevron.left.forwardslash.chevron.right" : "line.3.horizontal.decrease")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 260)
            }
            ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            HStack { Spacer(); Button("Cancelar") { dismiss() } }
        }
        .padding()
        .frame(width: 620)
        .task {
            (tickets, problems) = await Tickets.load(project: project)
            loading = false
        }
    }
}
