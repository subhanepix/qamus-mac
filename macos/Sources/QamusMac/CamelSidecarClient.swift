import Foundation
import Observation

struct CamelParse: Codable, Equatable, Sendable, Identifiable {
    var id: Int { rank }
    let rank: Int
    let confidence: Double
    let rawScore: Double
    let diac: String
    let lex: String
    let pos: String
    let aspect: String?
    let voice: String?
    let grammaticalCase: String?
    let mood: String?
    let englishLabel: String
    let arabicLabel: String
    let caseArabic: String?
    let caseEnglish: String?
    let clitics: [String]
    let gloss: String

    enum CodingKeys: String, CodingKey {
        case rank, confidence, rawScore, diac, lex, pos, aspect, voice, mood
        case grammaticalCase = "case"
        case englishLabel, arabicLabel, caseArabic, caseEnglish, clitics, gloss
    }

    var confidencePercent: Int {
        Int((confidence * 100.0).rounded())
    }
}

struct CamelToken: Codable, Equatable, Sendable {
    let word: String
    let diac: String
    let pos: String
    let englishLabel: String
    let arabicLabel: String
    let caseArabic: String?
    let caseEnglish: String?
    let voice: String?
    let aspect: String?
    let confidence: Double
    let isTarget: Bool
}

struct CamelAnalysisResponse: Codable, Equatable, Sendable {
    let model: String?
    let diacritizedSentence: String
    let targetWordMatched: String?
    let targetParses: [CamelParse]
    let tokens: [CamelToken]

    /// Formats CAMeL's context-aware diacritization, target probabilities, and neighbor case endings
    /// cleanly for the LLM prompt (omitting CAMeL's modern MSA English glosses so classical meaning stays grounded in Qamus).
    func promptBlock(for targetWord: String) -> String {
        var lines: [String] = []
        lines.append("CAMeL Context-Vocalized Sentence (NYU Abu Dhabi BERT Arabic Parser):")
        lines.append(diacritizedSentence)

        if !targetParses.isEmpty {
            lines.append("\nCAMeL Top Context-Disambiguated Parses for \"\(targetWord)\":")
            for p in targetParses.prefix(3) {
                let ar = p.arabicLabel.isEmpty ? "" : " | \(p.arabicLabel)"
                lines.append("- [\(p.confidencePercent)%] \(p.diac) — \(p.englishLabel)\(ar)")
            }
        }

        // Include neighboring tokens' case endings & POS around the target word (window of +/- 6 words)
        if let tIdx = tokens.firstIndex(where: \.isTarget) {
            let lo = max(0, tIdx - 5)
            let hi = min(tokens.count - 1, tIdx + 6)
            let neighborSummaries = tokens[lo...hi].map { tok -> String in
                let marker = tok.isTarget ? "★" : ""
                let caseTag = tok.caseArabic.map { " (\($0))" } ?? ""
                return "\(marker)\(tok.diac) [\(tok.englishLabel)\(caseTag)]"
            }
            lines.append("\nNeighboring Words (CAMeL harakat & case endings):")
            lines.append(neighborSummaries.joined(separator: " · "))
        }

        return lines.joined(separator: "\n")
    }
}

@MainActor
@Observable
final class CamelSidecarClient {
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "qamus.mac.camel.enabled")
            if isEnabled {
                startIfNeeded()
            } else {
                stop()
            }
        }
    }

    var isReady = false
    var isStarting = false
    var modelName = ""
    var statusLabel = "Off"
    var lastError: String?

    let port: Int = 41933
    private var childProcess: Process?
    private var startupTask: Task<Void, Never>?

    var baseURL: String { "http://127.0.0.1:\(port)" }

    init() {
        if UserDefaults.standard.object(forKey: "qamus.mac.camel.enabled") != nil {
            self.isEnabled = UserDefaults.standard.bool(forKey: "qamus.mac.camel.enabled")
        } else {
            self.isEnabled = true
        }
        self.statusLabel = isEnabled ? "Checking…" : "Off"
    }

    func startIfNeeded() {
        guard isEnabled else {
            statusLabel = "Off"
            return
        }
        startupTask?.cancel()
        startupTask = Task {
            // 1. Check if sidecar is already running externally or from an earlier boot
            if let health = await fetchHealth() {
                applyHealth(health)
                if health.ready { return }
            }

            // 2. Locate camel_sidecar/.venv/bin/python + server.py
            guard let (pythonURL, scriptURL) = Self.locateSidecar() else {
                isReady = false
                isStarting = false
                statusLabel = "Not installed"
                lastError = "Run sh macos/camel_sidecar/setup-camel.sh to install CAMeL Tools."
                return
            }

            // 3. Spawn managed sidecar process if not already alive
            if childProcess == nil || childProcess?.isRunning == false {
                isStarting = true
                statusLabel = "Loading CAMeL…"
                lastError = nil

                let proc = Process()
                proc.executableURL = pythonURL
                proc.arguments = [scriptURL.path, "--host", "127.0.0.1", "--port", "\(port)"]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                do {
                    try proc.run()
                    self.childProcess = proc
                } catch {
                    isStarting = false
                    statusLabel = "Launch failed"
                    lastError = error.localizedDescription
                    return
                }
            }

            // 4. Poll /health cleanly until CAMeL BERT finishes loading (~3–10s)
            for _ in 0..<45 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, isEnabled else { return }
                if let health = await fetchHealth() {
                    applyHealth(health)
                    if health.ready || health.error != nil {
                        return
                    }
                }
            }
            isStarting = false
            if !isReady {
                statusLabel = "Timed out"
            }
        }
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        if let proc = childProcess, proc.isRunning {
            proc.terminate()
        }
        childProcess = nil
        isReady = false
        isStarting = false
        statusLabel = isEnabled ? "Stopped" : "Off"
    }

    func analyze(sentence: String, targetWord: String) async -> CamelAnalysisResponse? {
        guard isEnabled else { return nil }
        let trimmedSent = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSent.isEmpty else { return nil }

        // If sidecar hasn't reported ready yet, check health quickly once
        if !isReady {
            if let h = await fetchHealth(), h.ready {
                applyHealth(h)
            } else {
                return nil
            }
        }

        guard let url = URL(string: "\(baseURL)/analyze") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 4.0

        let payload: [String: String] = [
            "sentence": trimmedSent,
            "targetWord": targetWord
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        req.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(CamelAnalysisResponse.self, from: data)
        } catch {
            return nil
        }
    }

    private struct HealthResponse: Decodable {
        let ok: Bool
        let ready: Bool
        let loading: Bool?
        let model: String?
        let error: String?
    }

    private func fetchHealth() async -> HealthResponse? {
        guard let url = URL(string: "\(baseURL)/health") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        return try? JSONDecoder().decode(HealthResponse.self, from: data)
    }

    private func applyHealth(_ h: HealthResponse) {
        self.isReady = h.ready
        self.isStarting = !h.ready && (h.loading ?? false)
        self.modelName = h.model ?? ""
        self.lastError = h.error
        if h.ready {
            self.statusLabel = "Ready · \(h.model ?? "CAMeL")"
        } else if let err = h.error {
            self.statusLabel = "Error"
            self.lastError = err
        } else {
            self.statusLabel = "Loading CAMeL…"
        }
    }

    /// Locates `camel_sidecar/.venv/bin/python` and `server.py` whether launched from
    /// `/Applications/Qamus.app` (installed via Install Qamus.command), `macos/build/Qamus.app`, or `swift run`.
    private static func locateSidecar() -> (python: URL, script: URL)? {
        let fm = FileManager.default
        let bundledScript = Bundle.main.resourceURL?
            .appendingPathComponent("camel_sidecar/server.py")
        let hasBundledScript = bundledScript.map { fm.fileExists(atPath: $0.path) } ?? false

        var candidateDirs: [URL] = []

        // 1. Standard per-user Application Support path (used by Install Qamus.command on any Mac)
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidateDirs.append(appSupport.appendingPathComponent("Qamus/camel_sidecar"))
        }

        // 2. Baked-in dev path in Info.plist (local development builds)
        if let plistDir = Bundle.main.object(forInfoDictionaryKey: "QamusCamelSidecarDir") as? String,
           !plistDir.isEmpty {
            candidateDirs.append(URL(fileURLWithPath: plistDir))
        }

        // 3. Relative to macos/build/Qamus.app -> macos/camel_sidecar
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        candidateDirs.append(bundleParent.deletingLastPathComponent().appendingPathComponent("camel_sidecar"))

        // 4. Relative to current working directory
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidateDirs.append(cwd.appendingPathComponent("camel_sidecar"))
        candidateDirs.append(cwd.appendingPathComponent("macos/camel_sidecar"))

        for dir in candidateDirs {
            let py = dir.appendingPathComponent(".venv/bin/python")
            guard fm.isExecutableFile(atPath: py.path) else { continue }
            if hasBundledScript, let bundledScript {
                return (py, bundledScript)
            }
            let localScript = dir.appendingPathComponent("server.py")
            if fm.fileExists(atPath: localScript.path) {
                return (py, localScript)
            }
        }
        return nil
    }
}
