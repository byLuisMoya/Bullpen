@testable import BPProviders
import Foundation
import Testing

@Suite struct ModelClientTests {
    func body(_ r: URLRequest) throws -> [String: Any] {
        let data = try #require(r.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func anthropicRequestShape() throws {
        let client = ModelClient(choice: .judgeDefault, apiKey: "sk-test")
        let r = try client.makeRequest(CompletionRequest(system: "Eres juez.", prompt: "¿A o B?", maxTokens: 16000, effort: "high"))
        #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let b = try body(r)
        #expect(b["model"] as? String == "claude-opus-5-5")
        #expect(b["max_tokens"] as? Int == 16000)
        #expect(b["system"] as? String == "Eres juez.")
        #expect((b["output_config"] as? [String: String])?["effort"] == "high")
        #expect((b["messages"] as? [[String: String]])?.first?["content"] == "¿A o B?")
    }

    @Test func anthropicResponseSkipsThinkingAndChecksStopReason() throws {
        let client = ModelClient(choice: .quickDefault, apiKey: "k")
        let ok = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"luis/"},{"type":"text","text":"fix-login"}],"stop_reason":"end_turn"}"#
        #expect(try client.parse(Data(ok.utf8)) == "luis/fix-login")
        let refusal = #"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}"#
        #expect(throws: ProviderError("El modelo ha rechazado la petición (cyber).")) { try client.parse(Data(refusal.utf8)) }
        let cut = #"{"content":[{"type":"text","text":"a"}],"stop_reason":"max_tokens"}"#
        #expect(throws: ProviderError.self) { try client.parse(Data(cut.utf8)) }
    }

    @Test func openAICompatibleAndGeminiShapes() throws {
        let ollama = ModelClient(choice: ModelChoice(provider: .ollama, model: "llama3"), apiKey: nil)
        let r = try ollama.makeRequest(CompletionRequest(system: "s", prompt: "p"))
        #expect(r.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(r.value(forHTTPHeaderField: "authorization") == nil)
        #expect(try ollama.parse(Data(#"{"choices":[{"message":{"content":"hola"}}]}"#.utf8)) == "hola")

        let gemini = ModelClient(choice: ModelChoice(provider: .gemini, model: "gemini-pro"), apiKey: "g")
        let g = try gemini.makeRequest(CompletionRequest(prompt: "p"))
        #expect(g.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent")
        #expect(g.value(forHTTPHeaderField: "x-goog-api-key") == "g")
        #expect(try gemini.parse(Data(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#.utf8)) == "ok")
    }

    @Test func missingKeyFailsBeforeAnyNetwork() async {
        let client = ModelClient(choice: .quickDefault, apiKey: nil)
        await #expect(throws: ProviderError.self) { try await client.complete(CompletionRequest(prompt: "x")) }
    }

    @Test func errorBodiesAreReadable() {
        #expect(ModelClient.errorMessage(Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)) == "invalid x-api-key")
    }
}

@Suite struct KeyStoreTests {
    @Test func storesReplacesAndDeletes() throws {
        let store = KeyStore(service: "com.byluismoya.Bullpen.tests.\(UUID().uuidString)")
        try store.setKey("one", for: .openai)
        #expect(store.key(for: .openai) == "one")
        try store.setKey("two", for: .openai)
        #expect(store.key(for: .openai) == "two")
        try store.setKey(nil, for: .openai)
        #expect(store.key(for: .openai) == nil)
    }
}

@Suite struct NewProviderTests {
    @Test func claudeCodeRunsIsolatedWithoutTools() {
        let args = ClaudeCodeCLI.arguments(CompletionRequest(system: "Resume", prompt: "hola"), model: "")
        #expect(args.starts(with: ["-p", "--model", "haiku"]))
        for flag in ["--strict-mcp-config", "--safe-mode", "--no-session-persistence"] { #expect(args.contains(flag)) }
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "")
        #expect(args.last == "hola")
        #expect(!ProviderID.claudeCode.needsKey)
    }

    @Test func deepSeekSpeaksTheOpenAIFormat() throws {
        let client = ModelClient(choice: ModelChoice(provider: .deepseek, model: "deepseek-chat"), apiKey: "sk-x")
        let request = try client.makeRequest(CompletionRequest(prompt: "hola"))
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-x")
    }
}

@Suite struct LiveClaudeCodeTests {
    /// Calls the real `claude -p` (uses the subscription): `BULLPEN_LIVE=1 swift test --filter LiveClaudeCodeTests`.
    @Test func answersWithTheUsersClaudeCode() async throws {
        guard ProcessInfo.processInfo.environment["BULLPEN_LIVE"] == "1", ClaudeCodeCLI.locate() != nil else { return }
        let answer = try await ClaudeCodeCLI.complete(CompletionRequest(system: "Responde solo con la palabra pedida.", prompt: "Di: bullpen"), model: "haiku")
        #expect(answer.lowercased().contains("bullpen"))
    }
}
