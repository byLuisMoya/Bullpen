@testable import BPAgents
import Foundation
import Testing

@Suite struct ActivityDigestTests {
    func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func readsTheCurrentTurnOfAClaudeTranscript() {
        let transcript = [
            line(["type": "user", "message": ["role": "user", "content": "Primera tarea vieja"]]),
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Read", "input": ["file_path": "/a/old.ts"]]]]]),
            line(["type": "user", "message": ["role": "user", "content": "Arregla el timeout del login"]]),
            line(["type": "assistant", "message": ["content": [["type": "thinking", "thinking": "…"],
                                                               ["type": "tool_use", "name": "Edit", "input": ["file_path": "/repo/src/LoginForm.vue"]]]]]),
            line(["type": "user", "message": ["content": [["type": "tool_result", "content": "ok"]]]]),
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash",
                                                                 "input": ["command": "npm test", "description": "Ejecuta los tests"]]]]]),
            line(["type": "assistant", "message": ["content": [["type": "text", "text": "Listo. El timeout ya no salta."]]]]),
            "{no es json",
        ].joined(separator: "\n")
        let digest = ActivityDigest.fromClaudeTranscript(transcript)
        #expect(digest.request == "Arregla el timeout del login")
        #expect(digest.actions == ["Edita LoginForm.vue", "Ejecuta los tests"])
        #expect(digest.lastMessage == "Listo. El timeout ya no salta.")
        #expect(digest.quickSummary == "Ejecuta los tests")
        #expect(digest.modelPrompt.contains("Arregla el timeout del login"))
    }

    @Test func terminalOutputLosesEscapeCodes() {
        let digest = ActivityDigest.fromTerminal("\u{1B}[32m✓ compiled\u{1B}[0m\r\n\u{1B}]0;title\u{07}Running tests…\n--\n")
        #expect(digest.lastMessage == "✓ compiled\nRunning tests…")
        #expect(digest.quickSummary == "✓ compiled Running tests…")
    }

    @Test func emptyInputsGiveNothing() {
        #expect(ActivityDigest.fromClaudeTranscript("").isEmpty)
        #expect(ActivityDigest.fromTerminal("\u{1B}[2J").quickSummary == nil)
    }
}
