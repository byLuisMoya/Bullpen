import BPEnv
import Foundation
import Testing

@Suite struct SetupScriptTests {
    @Test func blankScriptAddsNoStep() {
        #expect(WorktreeSetup.scriptStep(nil) == nil)
        #expect(WorktreeSetup.scriptStep("  \n ") == nil)
    }

    /// The step runs the whole multi-line script, quotes included, and stops at the first failure.
    @Test func scriptRunsInTheShellAndStopsOnFailure() throws {
        func run(_ script: String) throws -> (String, Int32) {
            let step = try #require(WorktreeSetup.scriptStep(script))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", step]
            process.environment = ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            process.waitUntilExit()
            return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), process.terminationStatus)
        }
        let ok = try run("echo 'it''s'\necho \"two\"")
        #expect(ok.0 == "its\ntwo\n")
        #expect(ok.1 == 0)
        let failing = try run("echo one\nfalse\necho never")
        #expect(failing.0 == "one\n")
        #expect(failing.1 != 0)
    }
}
