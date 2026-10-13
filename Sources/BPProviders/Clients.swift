import Foundation

/// One request, one text answer, over plain HTTPS (URLSession, no SDKs).
public struct ModelClient: Sendable {
    public var choice: ModelChoice
    public var apiKey: String?
    public var session: URLSession

    public init(choice: ModelChoice, apiKey: String?, session: URLSession = .shared) {
        self.choice = choice
        self.apiKey = apiKey
        self.session = session
    }

    public func complete(_ request: CompletionRequest) async throws -> String {
        if choice.provider == .claudeCode { return try await ClaudeCodeCLI.complete(request, model: choice.model) }
        if choice.provider.needsKey, (apiKey ?? "").isEmpty {
            throw ProviderError("Falta la clave de \(choice.provider.name). Añádela en Ajustes › Modelos.")
        }
        let urlRequest = try makeRequest(request)
        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderError("\(choice.provider.name) respondió \(status): \(Self.errorMessage(data))")
        }
        return try parse(data)
    }

    func makeRequest(_ request: CompletionRequest) throws -> URLRequest {
        let base = choice.baseURL ?? choice.provider.defaultBaseURL
        var body: [String: Any]
        var url: URL
        var headers = ["content-type": "application/json"]

        switch choice.provider {
        case .anthropic:
            url = base.appendingPathComponent("v1/messages")
            headers["x-api-key"] = apiKey ?? ""
            headers["anthropic-version"] = "2023-06-01"
            body = [
                "model": choice.model,
                "max_tokens": request.maxTokens,
                "messages": [["role": "user", "content": request.prompt]],
            ]
            if let system = request.system { body["system"] = system }
            if let effort = request.effort { body["output_config"] = ["effort": effort] }
        case .gemini:
            url = base.appendingPathComponent("models/\(choice.model):generateContent")
            headers["x-goog-api-key"] = apiKey ?? ""
            body = [
                "contents": [["role": "user", "parts": [["text": request.prompt]]]],
                "generationConfig": ["maxOutputTokens": request.maxTokens],
            ]
            if let system = request.system { body["systemInstruction"] = ["parts": [["text": system]]] }
        case .claudeCode:
            throw ProviderError("Claude Code no usa HTTP")
        case .openai, .openrouter, .ollama, .lmstudio, .deepseek:
            url = base.appendingPathComponent("chat/completions")
            if let apiKey, !apiKey.isEmpty { headers["authorization"] = "Bearer \(apiKey)" }
            var messages: [[String: String]] = []
            if let system = request.system { messages.append(["role": "system", "content": system]) }
            messages.append(["role": "user", "content": request.prompt])
            body = ["model": choice.model, "messages": messages, "max_tokens": request.maxTokens]
        }

        var urlRequest = URLRequest(url: url, timeoutInterval: 120)
        urlRequest.httpMethod = "POST"
        headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    func parse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("Respuesta no válida de \(choice.provider.name)")
        }
        switch choice.provider {
        case .anthropic:
            // Check why it stopped before reading content; thinking blocks come first, keep only text.
            switch json["stop_reason"] as? String {
            case "refusal":
                let category = (json["stop_details"] as? [String: Any])?["category"] as? String
                throw ProviderError("El modelo ha rechazado la petición\(category.map { " (\($0))" } ?? "").")
            case "max_tokens":
                throw ProviderError("La respuesta se cortó por max_tokens.")
            default:
                break
            }
            let blocks = json["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw ProviderError("Respuesta vacía de Anthropic") }
            return text
        case .gemini:
            let candidate = (json["candidates"] as? [[String: Any]])?.first
            let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw ProviderError("Respuesta vacía de Gemini (\(candidate?["finishReason"] as? String ?? "?"))") }
            return text
        case .claudeCode:
            throw ProviderError("Claude Code no usa HTTP")
        case .openai, .openrouter, .ollama, .lmstudio, .deepseek:
            let choice = (json["choices"] as? [[String: Any]])?.first
            guard let text = (choice?["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else {
                throw ProviderError("Respuesta vacía de \(self.choice.provider.name)")
            }
            return text
        }
    }

    static func errorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = json["error"] as? String { return message }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}
