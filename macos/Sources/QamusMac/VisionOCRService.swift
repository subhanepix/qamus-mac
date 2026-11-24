import AppKit
import CoreImage
import Foundation
import Observation
import Vision

enum OCREngineMode: String, CaseIterable, Identifiable, Codable {
    case hybridVisual = "Hybrid Visual (Vision + gemma3:12b)"
    case fastProofread = "Fast Proofread (Vision + active AI)"
    case appleVision = "Apple Vision (Instant)"
    case aiVision = "Multimodal Vision Only (gemma3:12b)"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .hybridVisual: return "Hybrid Visual"
        case .fastProofread: return "Fast Proofread"
        case .appleVision: return "Apple Vision"
        case .aiVision: return "AI Vision"
        }
    }
}

struct ScannedToken: Identifiable, Hashable, Sendable {
    let id: Int
    let text: String
    let isArabicWord: Bool
}

struct ScannedLine: Identifiable, Hashable, Sendable {
    let id: Int
    let text: String
    let tokens: [ScannedToken]
}

struct ScannedPage: Identifiable {
    let id = UUID()
    let createdAt = Date()
    let image: NSImage
    var fullText: String
    var lines: [ScannedLine]
    var engineLabel: String
}

enum VisionOCRError: LocalizedError {
    case invalidImage
    case noTextFound
    case aiServerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Could not read image data."
        case .noTextFound: return "No readable Arabic text was detected in the image."
        case .aiServerUnavailable(let msg): return msg
        }
    }
}

@MainActor
@Observable
final class ScanDockStore {
    var pages: [ScannedPage] = []
    var activePageIndex: Int = 0
    var selectedLineId: Int?
    var selectedTokenId: Int?
    var selectedWord: String = ""
    var selectedLineText: String = ""
    var surroundingContextText: String = ""

    var ocrMode: OCREngineMode {
        didSet { UserDefaults.standard.set(ocrMode.rawValue, forKey: "qamus.mac.ocr.mode") }
    }
    var autoExplainOnTap: Bool {
        didSet { UserDefaults.standard.set(autoExplainOnTap, forKey: "qamus.mac.ocr.autoExplain") }
    }
    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "qamus.mac.ocr.fontSize") }
    }

    var isScanning = false
    var showSourceImage = false
    var isEditingText = false
    var errorMessage: String?

    init() {
        let savedMode = UserDefaults.standard.string(forKey: "qamus.mac.ocr.mode")
        self.ocrMode = OCREngineMode(rawValue: savedMode ?? "") ?? .hybridVisual
        if UserDefaults.standard.object(forKey: "qamus.mac.ocr.autoExplain") != nil {
            self.autoExplainOnTap = UserDefaults.standard.bool(forKey: "qamus.mac.ocr.autoExplain")
        } else {
            self.autoExplainOnTap = true
        }
        let fs = UserDefaults.standard.double(forKey: "qamus.mac.ocr.fontSize")
        self.fontSize = fs >= 14 ? fs : 22
    }

    var activePage: ScannedPage? {
        guard pages.indices.contains(activePageIndex) else { return nil }
        return pages[activePageIndex]
    }

    /// Returns a 3-line passage window (previous + target + next line) so wrapped clauses
    /// never get truncated mid-sentence when analyzing a clicked word.
    func surroundingPassage(forLineId lineId: Int) -> String {
        guard let lines = activePage?.lines,
              let idx = lines.firstIndex(where: { $0.id == lineId }) else {
            return selectedLineText
        }
        let lo = max(0, idx - 1)
        let hi = min(lines.count - 1, idx + 1)
        return lines[lo...hi].map(\.text).joined(separator: "\n")
    }

    func selectWord(token: ScannedToken, in line: ScannedLine) {
        selectedLineId = line.id
        selectedTokenId = token.id
        selectedWord = token.text
        selectedLineText = line.text
        surroundingContextText = surroundingPassage(forLineId: line.id)
    }

    func clearSelection() {
        selectedLineId = nil
        selectedTokenId = nil
        selectedWord = ""
        selectedLineText = ""
        surroundingContextText = ""
    }

    func updateActiveText(_ newText: String) {
        guard pages.indices.contains(activePageIndex) else { return }
        pages[activePageIndex].fullText = newText
        pages[activePageIndex].lines = VisionOCRService.parseLines(from: newText)
        selectedLineId = nil
        selectedTokenId = nil
    }

    func scan(image: NSImage, ollamaBaseURL: String, activeModel: String, activeModelSupportsVision: Bool, visionFallbackModel: String) {
        isScanning = true
        errorMessage = nil
        isEditingText = false
        let mode = ocrMode

        Task {
            do {
                let (text, label) = try await VisionOCRService.recognize(
                    image: image,
                    mode: mode,
                    ollamaBaseURL: ollamaBaseURL,
                    activeModel: activeModel,
                    activeModelSupportsVision: activeModelSupportsVision,
                    visionFallbackModel: visionFallbackModel
                )
                let parsed = VisionOCRService.parseLines(from: text)
                let page = ScannedPage(image: image, fullText: text, lines: parsed, engineLabel: label)
                pages.insert(page, at: 0)
                if pages.count > 8 { pages.removeLast() }
                activePageIndex = 0
                clearSelection()
            } catch {
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
    }

    func rescanActive(ollamaBaseURL: String, activeModel: String, activeModelSupportsVision: Bool, visionFallbackModel: String) {
        guard let img = activePage?.image else { return }
        isScanning = true
        errorMessage = nil
        let idx = activePageIndex
        let mode = ocrMode

        Task {
            do {
                let (text, label) = try await VisionOCRService.recognize(
                    image: img,
                    mode: mode,
                    ollamaBaseURL: ollamaBaseURL,
                    activeModel: activeModel,
                    activeModelSupportsVision: activeModelSupportsVision,
                    visionFallbackModel: visionFallbackModel
                )
                if pages.indices.contains(idx) {
                    pages[idx].fullText = text
                    pages[idx].lines = VisionOCRService.parseLines(from: text)
                    pages[idx].engineLabel = label
                }
                selectedLineId = nil
                selectedTokenId = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
    }
}

enum VisionOCRService {
    /// Recognizes Arabic text using either local multimodal AI Vision (Gemma 3 12B via Ollama —
    /// dramatically better on classical print, harakat, and ligatures) or enhanced Apple Vision.
    static func recognize(
        image: NSImage,
        mode: OCREngineMode,
        ollamaBaseURL: String,
        activeModel: String,
        activeModelSupportsVision: Bool,
        visionFallbackModel: String
    ) async throws -> (text: String, engineLabel: String) {
        guard let cg = preprocessForArabicOCR(image) else {
            throw VisionOCRError.invalidImage
        }

        switch mode {
        case .hybridVisual:
            // Best accuracy: 2× Apple Vision gives exact classical spelling baseline, then multimodal
            // gemma3:12b visually checks the actual pixels to fix ornate brackets (﴿أَلَمْ تَرَ﴾) & harakat!
            let visionDraft = try? await recognizeWithAppleVision(cgImage: cg)
            let vModel = activeModelSupportsVision ? activeModel : visionFallbackModel
            let keepAlive = (vModel == activeModel) ? "30m" : "2m"
            do {
                let verified = try await recognizeWithOllama(
                    cgImage: cg,
                    ollamaBaseURL: ollamaBaseURL,
                    model: vModel,
                    ocrDraft: (visionDraft?.isEmpty == false) ? visionDraft : nil,
                    keepAlive: keepAlive
                )
                return (verified, "Hybrid Visual · \(vModel)")
            } catch {
                if let draft = visionDraft, !draft.isEmpty {
                    return (draft, "Apple Vision 2× (AI offline)")
                }
                throw error
            }

        case .fastProofread:
            // Zero model swap: 2× Apple Vision (~0.2s) + fast text proofreading on the already-loaded model.
            let visionDraft = try? await recognizeWithAppleVision(cgImage: cg)
            do {
                if let draft = visionDraft, !draft.isEmpty {
                    let verified = try await recognizeWithOllama(
                        cgImage: activeModelSupportsVision ? cg : nil,
                        ollamaBaseURL: ollamaBaseURL,
                        model: activeModel,
                        ocrDraft: draft,
                        keepAlive: "30m"
                    )
                    return (verified, "Apple Vision + \(activeModel)")
                } else {
                    let vModel = activeModelSupportsVision ? activeModel : visionFallbackModel
                    let text = try await recognizeWithOllama(
                        cgImage: cg,
                        ollamaBaseURL: ollamaBaseURL,
                        model: vModel,
                        ocrDraft: nil,
                        keepAlive: (vModel == activeModel) ? "30m" : "2m"
                    )
                    return (text, "AI Vision · \(vModel)")
                }
            } catch {
                if let draft = visionDraft, !draft.isEmpty {
                    return (draft, "Apple Vision 2× (AI offline)")
                }
                throw error
            }

        case .aiVision:
            let vModel = activeModelSupportsVision ? activeModel : visionFallbackModel
            do {
                let text = try await recognizeWithOllama(
                    cgImage: cg,
                    ollamaBaseURL: ollamaBaseURL,
                    model: vModel,
                    ocrDraft: nil,
                    keepAlive: (vModel == activeModel) ? "30m" : "2m"
                )
                return (text, "AI Vision · \(vModel)")
            } catch {
                if let fallback = try? await recognizeWithAppleVision(cgImage: cg), !fallback.isEmpty {
                    return (fallback, "Apple Vision 2× (AI unavailable)")
                }
                throw error
            }

        case .appleVision:
            let text = try await recognizeWithAppleVision(cgImage: cg)
            return (text, "Apple Vision (2× Enhanced)")
        }
    }

    /// 2× Lanczos upscale (for small textbook screenshots) + subtle contrast & sharpen boost.
    private static func preprocessForArabicOCR(_ image: NSImage) -> CGImage? {
        guard let rawCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        var ci = CIImage(cgImage: rawCG)
        let width = ci.extent.width

        // Upscale smaller screenshots so Arabic dots (نقاط) and harakat are crisp
        if width < 1400 && width > 10 {
            let scale = min(2.2, 1600.0 / width)
            if let lanczos = CIFilter(name: "CILanczosScaleTransform") {
                lanczos.setValue(ci, forKey: kCIInputImageKey)
                lanczos.setValue(scale, forKey: kCIInputScaleKey)
                lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
                if let out = lanczos.outputImage { ci = out }
            }
        }

        // Mild contrast + sharpen to separate ink from aged/gray PDF page backgrounds
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(ci, forKey: kCIInputImageKey)
            controls.setValue(1.12, forKey: kCIInputContrastKey)
            controls.setValue(0.02, forKey: kCIInputBrightnessKey)
            if let out = controls.outputImage { ci = out }
        }
        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(ci, forKey: kCIInputImageKey)
            sharpen.setValue(0.45, forKey: kCIInputSharpnessKey)
            if let out = sharpen.outputImage { ci = out }
        }

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(ci, from: ci.extent) ?? rawCG
    }

    private static func recognizeWithOllama(
        cgImage: CGImage?,
        ollamaBaseURL: String,
        model: String,
        ocrDraft: String?,
        keepAlive: String = "30m"
    ) async throws -> String {
        var b64Image: String?
        if let cgImage {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                throw VisionOCRError.invalidImage
            }
            b64Image = pngData.base64EncodedString()
        }

        // Derive native Ollama /api/chat URL from OpenAI endpoint or base URL
        let base = ollamaBaseURL
            .replacingOccurrences(of: "/v1/chat/completions", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/api/chat") else {
            throw VisionOCRError.aiServerUnavailable("Invalid Ollama URL.")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 90

        let prompt: String
        if let ocrDraft, !ocrDraft.isEmpty, b64Image != nil {
            prompt = """
            You are proofreading an Arabic OCR transcript against its source image.
            Fix ONLY clear OCR character errors (such as missing/wrong letter dots like ص/ض, ع/غ, ف/ق, ب/ت/ث/ن/ي, د/ذ, ر/ز, or broken classical ligatures) so every word matches the image and valid classical Arabic spelling.
            STRICT RULES:
            - NEVER add new words, delete real words, translate, or paraphrase.
            - Keep exact line breaks and printed harakat.
            - Output ONLY the corrected Arabic text (no explanations, no code fences).

            OCR transcript to verify:
            \(ocrDraft)
            """
        } else if let ocrDraft, !ocrDraft.isEmpty {
            prompt = """
            You are proofreading a classical Arabic OCR transcript.
            Fix ONLY obvious OCR typos (such as swapped Arabic letter dots like ص/ض, ع/غ, ف/ق, ب/ت/ث/ن/ي, د/ذ, ر/ز, broken split words, or stray OCR noise symbols).
            STRICT RULES:
            - NEVER add new words, rewrite valid classical Arabic phrases, modernize spelling, translate, or explain.
            - If a word is already valid Arabic, leave it completely untouched.
            - Keep exact line breaks and printed harakat.
            - Output ONLY the cleaned Arabic text (no explanations, no code fences).

            OCR transcript:
            \(ocrDraft)
            """
        } else {
            prompt = """
            Transcribe ALL Arabic text visible in this textbook screenshot verbatim, line by line.
            Strict rules:
            - Output ONLY the exact transcribed Arabic text (preserve line breaks, exact spelling, hamzas, and any clearly printed harakat/diacritics).
            - Do NOT translate, explain, summarize, add bullet points, or wrap in code fences.
            - Pay close attention to Arabic letter dots (ب ت ث ن ي، ف ق، ج ح خ، ع غ) and classical print ligatures.
            """
        }

        var userMsg: [String: Any] = [
            "role": "user",
            "content": prompt
        ]
        if let b64Image {
            userMsg["images"] = [b64Image]
        }

        var payload: [String: Any] = [
            "model": model,
            "stream": false,
            "keep_alive": keepAlive,
            "options": [
                "temperature": 0.0
            ],
            "messages": [userMsg]
        ]
        let lower = model.lowercased()
        if lower.contains("qwen3") && !lower.contains("instruct") {
            payload["think"] = false
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Ollama vision error"
            throw VisionOCRError.aiServerUnavailable("Ollama Vision (\(model)) failed: \(msg.prefix(200))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              var content = message["content"] as? String else {
            throw VisionOCRError.noTextFound
        }

        // Clean any accidental markdown fences
        content = content
            .replacingOccurrences(of: "```arabic", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if content.isEmpty { throw VisionOCRError.noTextFound }
        return content
    }

    private static func recognizeWithAppleVision(cgImage: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = ["ar-SA", "ar"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if joined.isEmpty { throw VisionOCRError.noTextFound }
            return joined
        }.value
    }

    /// Parses raw transcribed text into line-by-line interactive Arabic tokens
    /// while preserving exact reading order and punctuation.
    static func parseLines(from rawText: String) -> [ScannedLine] {
        let rawLines = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let regex = try? NSRegularExpression(
            pattern: "([\\u0621-\\u063A\\u0641-\\u064A\\u064B-\\u065F\\u0670\\u0640]+)|([^\\u0621-\\u063A\\u0641-\\u064A\\u064B-\\u065F\\u0670\\u0640\\s]+)"
        )

        var tokenCounter = 0
        return rawLines.enumerated().map { (lineIdx, lineStr) in
            var tokens: [ScannedToken] = []
            if let regex {
                let ns = lineStr as NSString
                let matches = regex.matches(in: lineStr, range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    let isAr = m.range(at: 1).location != NSNotFound
                    let piece = ns.substring(with: m.range)
                    tokens.append(ScannedToken(id: tokenCounter, text: piece, isArabicWord: isAr))
                    tokenCounter += 1
                }
            }
            return ScannedLine(id: lineIdx, text: lineStr, tokens: tokens)
        }
    }
}
