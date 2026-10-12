import ArgumentParser
import BPCore

@main
struct BP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bp",
        abstract: "Bullpen command line: manage projects, worktrees and agents.",
        version: Bullpen.version
    )
}
