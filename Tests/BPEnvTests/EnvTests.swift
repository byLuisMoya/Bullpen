@testable import BPEnv
import Foundation
import Testing

@Suite struct TOMLTests {
    @Test func parsesTheConfigSubset() throws {
        let toml = #"""
        # Bullpen config
        [setup]
        copy = [".env", ".env.local"]   # comment after value
        clone = ["node_modules"]
        run = [
          "pnpm install --frozen-lockfile",
          'echo "ready"',
        ]

        [env]
        PORT = "{{port:web}}"
        DATABASE_URL = "postgres://localhost/app_{{worktree.slug}}"
        WORKERS = 3
        DEBUG = true

        [prompt]
        default = """
        Rama {{worktree.branch}}.
        Usa "pnpm".
        """

        [prompt.agents.codex]
        append = 'Commits pequeños.'
        """#
        let root = try TOML.parse(toml)
        #expect(root["setup"]?["copy"]?.strings == [".env", ".env.local"])
        #expect(root["setup"]?["run"]?.strings == ["pnpm install --frozen-lockfile", #"echo "ready""#])
        #expect(root["env"]?["WORKERS"] == .int(3))
        #expect(root["prompt"]?["default"]?.string == "Rama {{worktree.branch}}.\nUsa \"pnpm\".\n")
        #expect(root["prompt"]?["agents"]?["codex"]?["append"]?.string == "Commits pequeños.")

        let config = try BullpenConfig(toml: toml)
        #expect(config.clone == ["node_modules"])
        #expect(config.env["DEBUG"] == "true")
        #expect(config.agentPrompts["codex"] == "Commits pequeños.")
        #expect(config.portNames == ["web"])
    }

    @Test func reportsUnsupportedOrBrokenSyntaxWithLineNumbers() {
        #expect(throws: TOMLError.self) { try TOML.parse("[[servers]]\nname = 'a'") }
        #expect(throws: TOMLError(line: 2, message: "las tablas en línea ({…}) no están soportadas")) {
            try TOML.parse("[env]\nX = { a = 1 }")
        }
        #expect(throws: TOMLError.self) { try TOML.parse("a = 1\na = 2") }
        #expect(throws: TOMLError.self) { try TOML.parse("x = \"sin cerrar") }
    }

    @Test func resolvesEnvironmentWithPortsAndVariables() throws {
        var config = BullpenConfig()
        config.env = ["PORT": "{{port:web}}", "API": "http://localhost:{{port:api}}", "DB": "app_{{worktree.slug}}"]
        #expect(Set(config.portNames) == ["web", "api"])
        let env = try config.resolvedEnvironment(ports: ["web": 4100, "api": 4101], variables: ["worktree.slug": "luis-fix"])
        #expect(env == ["PORT": "4100", "API": "http://localhost:4101", "DB": "app_luis-fix"])
        #expect(throws: TemplateError.self) { try config.resolvedEnvironment(ports: [:], variables: [:]) }
    }
}

@Suite struct SetupTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bp-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func copiesAndClonesOnlyWhatIsMissing() throws {
        let main = try tempDir(), worktree = try tempDir()
        try "SECRET=1\n".write(to: main.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: main.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try "x".write(to: main.appendingPathComponent("node_modules/pkg/index.js"), atomically: true, encoding: .utf8)
        try "keep".write(to: worktree.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)

        var config = BullpenConfig()
        config.copy = [".env", ".env.local", ".missing"]
        config.clone = ["node_modules"]
        let report = try WorktreeSetup.prepare(config: config, from: main, to: worktree)
        #expect(report.copied == [".env"])
        #expect(report.cloned == ["node_modules"])
        #expect(report.missing == [".env.local", ".missing"])
        #expect(try String(contentsOf: worktree.appendingPathComponent("node_modules/pkg/index.js"), encoding: .utf8) == "x")
        // Clones are independent copies: changing one side leaves the other alone.
        try "y".write(to: worktree.appendingPathComponent("node_modules/pkg/index.js"), atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: main.appendingPathComponent("node_modules/pkg/index.js"), encoding: .utf8) == "x")
    }

    @Test func setupCommandGatesTheAgent() {
        #expect(WorktreeSetup.command(setup: [], then: "claude") == "claude")
        let cmd = WorktreeSetup.command(setup: ["pnpm i", "make db"], then: "claude; exec \"$SHELL\" -l")
        #expect(cmd?.hasPrefix("{ pnpm i && make db; } || {") == true)
        #expect(cmd?.hasSuffix("claude; exec \"$SHELL\" -l") == true)
    }

    @Test func allocatesFreeDistinctPorts() {
        let busy: Set<Int> = [4101]
        let ports = PortAllocator.allocate(names: ["web", "api"], taken: [4100], range: 4100...4110) { !busy.contains($0) }
        #expect(ports == ["web": 4102, "api": 4103])
        #expect(PortAllocator.allocate(names: ["a", "b"], taken: [], range: 4100...4100) { _ in true } == ["a": 4100])
    }

    @Test func runsCommandsWithEnvironmentAndStopsOnFailure() async throws {
        let dir = try tempDir()
        let results = await CommandRunner.run(["echo \"port=$PORT\"", "exit 3", "echo nunca"], in: dir, environment: ["PORT": "4100"])
        #expect(results.count == 2)
        #expect(results[0].output.contains("port=4100") && results[0].succeeded)
        #expect(results[1].exitCode == 3)
    }
}
