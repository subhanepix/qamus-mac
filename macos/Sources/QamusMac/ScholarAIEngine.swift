import Foundation
import FoundationModels
import Observation

enum AIBackendMode: String, CaseIterable, Identifiable, Codable {
    case appleOnDevice = "Apple On-Device"
    case localOpenAI = "Local MLX / Ollama"

    var id: String { rawValue }
}

@MainActor
@Observable
final class ScholarAIEngine {
    var backendMode: AIBackendMode {
        didSet { UserDefaults.standard.set(backendMode.rawValue, forKey: "qamus.mac.ai.backend") }
    }
    var localEndpoint: String {
        didSet { UserDefaults.standard.set(localEndpoint, forKey: "qamus.mac.ai.endpoint") }
    }
    var localModelName: String {
        didSet { UserDefaults.standard.set(localModelName, forKey: "qamus.mac.ai.model") }
    }
    var enableGrammarReasoning: Bool {
        didSet { UserDefaults.standard.set(enableGrammarReasoning, forKey: "qamus.mac.ai.reasoning") }
    }

    var availableOllamaModels: [String] = []
    var isGenerating = false
    var structuredAnalysis: ContextualWordAnalysis?
    var outputText = ""
    var activeTitle = ""
    var statusLabel = ""
    var errorMessage: String?

    /// Bounded in-memory LRU cache so stepping back & forth (`← / →`) over already-parsed words returns in 0 ms.
    private static let maxCacheEntries = 120
    private var analysisCache: [String: ContextualWordAnalysis] = [:]
    private var analysisCacheOrder: [String] = []
    private(set) var cachedEntryCount: Int = 0

    private var currentTask: Task<Void, Never>?
    let morphAnalyzer = BuckwalterAnalyzer()
    let camelClient = CamelSidecarClient()

    func loadMorphology(from webRootURL: URL) {
        let analyzer = morphAnalyzer
        Task.detached(priority: .utility) {
            await analyzer.load(from: webRootURL)
        }
        camelClient.startIfNeeded()
    }

    init() {
        let savedMode = UserDefaults.standard.string(forKey: "qamus.mac.ai.backend")
        self.backendMode = AIBackendMode(rawValue: savedMode ?? "") ?? .localOpenAI
        self.localEndpoint = UserDefaults.standard.string(forKey: "qamus.mac.ai.endpoint") ?? "http://127.0.0.1:11434/v1/chat/completions"
        self.localModelName = UserDefaults.standard.string(forKey: "qamus.mac.ai.model") ?? "gemma3:12b"
        if UserDefaults.standard.object(forKey: "qamus.mac.ai.reasoning") != nil {
            self.enableGrammarReasoning = UserDefaults.standard.bool(forKey: "qamus.mac.ai.reasoning")
        } else {
            self.enableGrammarReasoning = false
        }
    }

    // MARK: - In-Memory Analysis Cache

    func analysisCacheKey(word: String, line: String, surrounding: String) -> String {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = surrounding.trimmingCharacters(in: .whitespacesAndNewlines)
        let camelActive = camelClient.isEnabled && camelClient.isReady
        let modelKey = backendMode == .appleOnDevice ? "apple" : localModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasonKey = (backendMode == .localOpenAI && isReasoningModel && enableGrammarReasoning) ? "1" : "0"
        return "\(backendMode.rawValue)|\(modelKey)|r\(reasonKey)|c\(camelActive ? "1" : "0")|\(w)|\(l)|\(s)"
    }

    func cachedAnalysis(word: String, line: String, surrounding: String) -> ContextualWordAnalysis? {
        let key = analysisCacheKey(word: word, line: line, surrounding: surrounding)
        guard let hit = analysisCache[key] else { return nil }
        if let idx = analysisCacheOrder.firstIndex(of: key) {
            analysisCacheOrder.remove(at: idx)
            analysisCacheOrder.append(key)
        }
        return hit
    }

    private func storeCachedAnalysis(_ analysis: ContextualWordAnalysis, forKey key: String) {
        analysisCache[key] = analysis
        if let idx = analysisCacheOrder.firstIndex(of: key) {
            analysisCacheOrder.remove(at: idx)
        }
        analysisCacheOrder.append(key)
        while analysisCacheOrder.count > Self.maxCacheEntries {
            let evicted = analysisCacheOrder.removeFirst()
            analysisCache.removeValue(forKey: evicted)
        }
        cachedEntryCount = analysisCache.count
    }

    func clearCache() {
        analysisCache.removeAll()
        analysisCacheOrder.removeAll()
        cachedEntryCount = 0
    }

    // MARK: - Backend & Model Capabilities

    var appleAvailabilityLabel: String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return "Apple Intelligence Ready"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in System Settings"
        case .unavailable(.modelNotReady):
            return "Apple on-device model is still preparing…"
        case .unavailable(.deviceNotEligible):
            return "Device not eligible for Apple Intelligence"
        @unknown default:
            return "Apple Intelligence unavailable"
        }
    }

    var isAppleAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var isReasoningModel: Bool {
        let lower = localModelName.lowercased()
        // Instruct-only checkpoints (e.g. qwen3:30b-a3b-instruct-2507) do NOT support Ollama's `think` parameter.
        if lower.contains("instruct") { return false }
        return lower.contains("qwen3") || lower.contains("deepseek-r1")
    }

    /// Base Ollama server URL derived from `localEndpoint`.
    var ollamaBaseURL: String {
        let trimmed = localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
                .replacingOccurrences(of: "/v1/chat/completions", with: "")
                .replacingOccurrences(of: "/api/chat", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "http://127.0.0.1:11434"
    }

    /// True if `localEndpoint` looks like an Ollama server (port 11434 or `/api/chat`).
    var isOllamaEndpoint: Bool {
        let lower = localEndpoint.lowercased()
        return lower.contains("11434") || lower.contains("/api/chat")
    }

    /// True when the active Ollama model supports native image input (e.g. gemma3, qwen3.5, llava).
    /// Text-only models like `qwen3:30b-a3b-instruct-2507` return false so Fast Proofread runs text-only
    /// on the already-loaded model with ZERO Ollama model-swap.
    var activeModelSupportsVision: Bool {
        let lower = localModelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visionHints = ["gemma3", "vision", "vl", "llava", "minicpm", "pixtral", "qwen3.5"]
        return !lower.isEmpty && visionHints.contains(where: { lower.contains($0) })
    }

    /// Multimodal vision model used when Hybrid Visual or Multimodal Vision OCR is selected.
    var visionModelName: String {
        let trimmed = localModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return activeModelSupportsVision ? trimmed : "gemma3:12b"
    }

    func refreshOllamaModels() {
        guard let url = URL(string: "\(ollamaBaseURL)/api/tags") else { return }
        Task {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 3
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = json["models"] as? [[String: Any]] else { return }
                let names = models.compactMap { $0["name"] as? String }
                if !names.isEmpty {
                    self.availableOllamaModels = names
                }
            } catch {
                // Silent if Ollama isn't running
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isGenerating = false
        statusLabel = ""
    }

    func clear() {
        cancel()
        structuredAnalysis = nil
        outputText = ""
        activeTitle = ""
        errorMessage = nil
    }

    // MARK: - Action Execution

    func run(action: ScholarAction, snapshot: CurrentLookupSnapshot) {
        cancel()
        activeTitle = action.title
        outputText = ""
        errorMessage = nil

        switch action {
        case .analyzeInContext(let word, let line, let surrounding, let bypassCache):
            let cacheKey = analysisCacheKey(word: word, line: line, surrounding: surrounding)
            if !bypassCache, let cached = cachedAnalysis(word: word, line: line, surrounding: surrounding) {
                structuredAnalysis = cached
                isGenerating = false
                statusLabel = ""
                return
            }

            isGenerating = true
            structuredAnalysis = nil
            statusLabel = (backendMode == .localOpenAI && isReasoningModel && enableGrammarReasoning)
                ? "Parsing grammar & context (\(localModelName))…"
                : "Analyzing word in context…"

            let instructions = ScholarPrompts.structuredSystemInstructions()
            let analyzer = morphAnalyzer
            let camel = camelClient
            let activeBackend = backendMode
            let camelSentence = surrounding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? line : surrounding

            currentTask = Task {
                do {
                    async let bwTask = analyzer.analyze(word)
                    async let camelTask = camel.analyze(sentence: camelSentence, targetWord: word)
                    let candidates = await bwTask
                    let camelResult = await camelTask

                    let prompt = ScholarPrompts.structuredPrompt(
                        word: word,
                        line: line,
                        surrounding: surrounding,
                        snapshot: snapshot,
                        backendMode: activeBackend,
                        morphCandidates: candidates,
                        camelResult: camelResult
                    )
                    let rawResult: ContextualWordAnalysis
                    switch activeBackend {
                    case .appleOnDevice:
                        rawResult = try await callAppleStructured(instructions: instructions, prompt: prompt)
                    case .localOpenAI:
                        rawResult = try await callLocalStructured(instructions: instructions, prompt: prompt)
                    }
                    try Task.checkCancellation()
                    let checked = rawResult.crossChecked(with: candidates, camel: camelResult)
                    self.storeCachedAnalysis(checked, forKey: cacheKey)
                    self.structuredAnalysis = checked
                } catch is CancellationError {
                    // Cancelled cleanly
                } catch {
                    self.errorMessage = error.localizedDescription
                }
                self.isGenerating = false
                self.statusLabel = ""
            }

        default:
            isGenerating = true
            structuredAnalysis = nil
            statusLabel = "Generating…"
            let instructions = ScholarPrompts.freeformSystemInstructions()
            let prompt = ScholarPrompts.freeformPrompt(action: action, snapshot: snapshot, backendMode: backendMode)

            currentTask = Task {
                do {
                    switch backendMode {
                    case .appleOnDevice:
                        try await streamAppleOnDevice(instructions: instructions, prompt: prompt)
                    case .localOpenAI:
                        try await streamLocalOpenAIEndpoint(instructions: instructions, prompt: prompt)
                    }
                } catch is CancellationError {
                    // Cancelled cleanly
                } catch {
                    self.errorMessage = error.localizedDescription
                }
                self.isGenerating = false
                self.statusLabel = ""
            }
        }
    }

    // MARK: - Structured JSON-Schema Analysis

    private func callLocalStructured(instructions: String, prompt: String) async throws -> ContextualWordAnalysis {
        if isOllamaEndpoint {
            return try await callOllamaStructuredChat(instructions: instructions, prompt: prompt)
        } else {
            return try await callGenericOpenAIStructured(instructions: instructions, prompt: prompt)
        }
    }

    private func callOllamaStructuredChat(instructions: String, prompt: String) async throws -> ContextualWordAnalysis {
        guard let url = URL(string: "\(ollamaBaseURL)/api/chat") else {
            throw NSError(domain: "QamusAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama URL."])
        }

        let useThinking = isReasoningModel && enableGrammarReasoning
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = useThinking ? 240 : 120

        let finalPrompt: String
        if useThinking {
            finalPrompt = """
            \(prompt)

            Keep your thinking VERY short (2–3 sentences max), then return ONLY a single valid JSON object (no markdown fences) with English explanations and these exact keys:
            {"selectedParseIndex":integer|null,"vocalized":string,"partOfSpeech":string,"arabicTag":string,"root":string|null,"meaningHere":string,"actingOnIt":[{"particle":string,"role":string,"effect":string}],"syntaxRole":string,"arguments":[{"relation":string,"arabic":string,"note":string|null}],"clauseTranslation":string,"ambiguityNote":string|null}
            """
        } else {
            finalPrompt = prompt
        }

        var options: [String: Any] = ["temperature": 0.1]
        if !useThinking {
            options["num_predict"] = 700
        }

        var body: [String: Any] = [
            "model": localModelName,
            "stream": false,
            "keep_alive": "30m",
            "options": options,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": finalPrompt]
            ]
        ]
        if isReasoningModel {
            body["think"] = enableGrammarReasoning
        }
        // Ollama's grammar-constrained `format` conflicts with `think: true` (can yield empty content).
        // Use constrained `format` when thinking is off, and forgiving JSON extraction after </think> when thinking is on.
        if !useThinking {
            body["format"] = ScholarPrompts.analysisJSONSchema()
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "QamusAI", code: 3, userInfo: [NSLocalizedDescriptionKey: "No HTTP response from Ollama."])
        }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "QamusAI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Ollama error (\(http.statusCode)): \(text.prefix(240))"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            throw NSError(domain: "QamusAI", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unexpected empty response from Ollama."])
        }

        let content = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            let thinking = (message["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !thinking.isEmpty {
                if let recovered = try? decodeAnalysis(from: thinking) {
                    return recovered
                }
                throw NSError(
                    domain: "QamusAI",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "\(localModelName) finished thinking without outputting a JSON card. Try turning off 'Grammar reasoning pass' for fast schema-guaranteed output."]
                )
            }
            throw NSError(domain: "QamusAI", code: 4, userInfo: [NSLocalizedDescriptionKey: "Ollama returned an empty response."])
        }

        return try decodeAnalysis(from: content)
    }

    private func callGenericOpenAIStructured(instructions: String, prompt: String) async throws -> ContextualWordAnalysis {
        guard let url = URL(string: localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "QamusAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid local endpoint URL."])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        let body: [String: Any] = [
            "model": localModelName,
            "temperature": 0.1,
            "stream": false,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "contextual_word_analysis",
                    "strict": true,
                    "schema": ScholarPrompts.analysisJSONSchema()
                ]
            ],
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "QamusAI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Local LLM error: \(text.prefix(240))"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "QamusAI", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unexpected response from local server."])
        }

        return try decodeAnalysis(from: content)
    }

    private func callAppleStructured(instructions: String, prompt: String) async throws -> ContextualWordAnalysis {
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        guard case .available = model.availability else {
            throw NSError(
                domain: "QamusAI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(appleAvailabilityLabel). Switch to Local MLX / Ollama in Engine Settings."]
            )
        }

        let schema = try ScholarPrompts.buildAppleGenerationSchema()
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            schema: schema,
            options: GenerationOptions(temperature: 0.15)
        )
        try Task.checkCancellation()
        return try decodeAnalysis(from: response.content.jsonString)
    }

    // MARK: - JSON Extraction & Sanitization

    private func decodeAnalysis(from raw: String) throws -> ContextualWordAnalysis {
        let cleaned = stripThinkTags(raw)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates = Self.extractBalancedJSONObjects(from: cleaned)
        var lastError: Error?
        for candidate in candidates.reversed() {
            let sanitized = Self.removeTrailingCommas(in: candidate)
            if let data = sanitized.data(using: .utf8) {
                do {
                    return try JSONDecoder().decode(ContextualWordAnalysis.self, from: data)
                } catch {
                    lastError = error
                }
            }
        }

        let detail = lastError?.localizedDescription ?? "No JSON object found"
        throw NSError(
            domain: "QamusAI",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Could not parse structured output (\(detail)).\nRaw: \(cleaned.prefix(260))"]
        )
    }

    /// Extracts all top-level balanced `{ ... }` JSON object substrings while respecting quoted strings & escapes.
    private static func extractBalancedJSONObjects(from text: String) -> [String] {
        var results: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var startIdx: String.Index?

        for idx in text.indices {
            let ch = text[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 { startIdx = idx }
                depth += 1
            } else if ch == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let s = startIdx {
                        results.append(String(text[s...idx]))
                        startIdx = nil
                    }
                }
            }
        }
        return results
    }

    private static func removeTrailingCommas(in json: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: ",\\s*([\\]\\}])") else { return json }
        let range = NSRange(json.startIndex..<json.endIndex, in: json)
        return regex.stringByReplacingMatches(in: json, options: [], range: range, withTemplate: "$1")
    }

    // MARK: - Freeform Streaming (Secondary Tools & Custom Questions)

    private func streamAppleOnDevice(instructions: String, prompt: String) async throws {
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        guard case .available = model.availability else {
            throw NSError(
                domain: "QamusAI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(appleAvailabilityLabel). Switch to Local MLX / Ollama in Engine Settings."]
            )
        }

        let session = LanguageModelSession(model: model, instructions: instructions)
        let stream = session.streamResponse(
            to: prompt,
            options: GenerationOptions(temperature: 0.25)
        )
        for try await partial in stream {
            try Task.checkCancellation()
            self.outputText = partial.content
        }
    }

    private func streamLocalOpenAIEndpoint(instructions: String, prompt: String) async throws {
        guard let url = URL(string: localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "QamusAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid local endpoint URL."])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        var body: [String: Any] = [
            "model": localModelName,
            "temperature": 0.25,
            "stream": true,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ]
        ]
        if isOllamaEndpoint {
            body["keep_alive"] = "30m"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "QamusAI", code: 3, userInfo: [NSLocalizedDescriptionKey: "No HTTP response from local model server."])
        }
        guard (200...299).contains(http.statusCode) else {
            var errData = Data()
            for try await b in bytes {
                errData.append(b)
                if errData.count > 1024 { break }
            }
            let text = String(data: errData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "QamusAI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Local LLM server error (\(http.statusCode)): \(text.prefix(240))"])
        }

        var rawAccumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let token = delta["content"] as? String else { continue }
            rawAccumulated += token
            self.outputText = stripThinkTags(rawAccumulated)
        }
    }

    private func stripThinkTags(_ s: String) -> String {
        var text = s
        while let start = text.range(of: "<think>") {
            if let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                text = String(text[..<start.lowerBound])
                break
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
