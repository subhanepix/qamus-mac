import AppKit
import SwiftUI

private struct PendingContextAnalysis: Equatable {
    let id: UUID
    let word: String
    let line: String
    let surrounding: String
    let bypassCache: Bool
}

struct ContentView: View {
    let serverURL: URL
    let webBridge: WebBridgeController
    @Bindable var ai: ScholarAIEngine
    @Bindable var scanDock: ScanDockStore

    @Binding var showInspector: Bool
    @Binding var showScanDock: Bool

    @State private var pendingAnalysis: PendingContextAnalysis?
    @State private var pendingFallbackTask: Task<Void, Never>?
    /// Word whose analysis should be handed back to the Desk's inspector when the AI finishes.
    @State private var deskAnalysisWord: String?
    /// Tracks the last Desk (word, sentence) auto-analyzed so duplicate lookup events don't re-run.
    @State private var lastDeskAutoKey: String = ""
    @State private var showEngineSettingsPopover = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                // In Reading Desk mode, scanned pages open straight into the Desk reader —
                // only show a slim status strip while OCR is actively running or reporting an error.
                if webBridge.isDesk && (scanDock.isScanning || scanDock.errorMessage != nil) {
                    deskOCRStatusBanner
                    Divider()
                }

                VSplitView {
                    if !webBridge.isDesk && showScanDock {
                        ScanDockView(
                            scanDock: scanDock,
                            ai: ai,
                            onTapWord: { word, line, surrounding in
                                handleScannedWordTap(word: word, line: line, surrounding: surrounding)
                            },
                            onClose: {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    showScanDock = false
                                }
                            }
                        )
                        .frame(minHeight: 165, idealHeight: 240, maxHeight: 460)
                    }

                    QamusWebView(url: serverURL, controller: webBridge)
                        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

            if showInspector {
                ScholarInspectorView(
                    webBridge: webBridge,
                    ai: ai,
                    scanDock: scanDock
                )
                .frame(minWidth: 340, idealWidth: 400, maxWidth: 500, maxHeight: .infinity)
            }
        }
        .onChange(of: webBridge.snapshot) { _, newSnap in
            // 1. Classic mode pending auto-analysis after clicking a word in the Scan Dock
            if let pending = pendingAnalysis {
                let wordMatches =
                    Self.arabicLooselyMatches(newSnap.query, pending.word) ||
                    Self.arabicLooselyMatches(newSnap.heroWord, pending.word)
                let hasDictData =
                    !newSnap.hansWehrText.isEmpty ||
                    !newSnap.particlesText.isEmpty ||
                    !newSnap.laneText.isEmpty ||
                    !newSnap.arabicDictsText.isEmpty ||
                    !newSnap.wiktionaryText.isEmpty

                if wordMatches && hasDictData {
                    triggerContextAnalysis(pending, snapshot: newSnap)
                }
                return
            }

            // 2. Reading Desk mode: sync every reader click into the AI harness & auto-analyze
            if webBridge.isDesk {
                let sentence = newSnap.deskContextSentence.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawSurrounding = newSnap.deskContextSurrounding.trimmingCharacters(in: .whitespacesAndNewlines)
                let surrounding = rawSurrounding.isEmpty ? sentence : rawSurrounding
                let word = (newSnap.deskContextWord.isEmpty ? newSnap.displayTitle : newSnap.deskContextWord)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !sentence.isEmpty, !word.isEmpty else { return }

                // Keep the native panel synced with the Desk's active word, sentence & surrounding passage
                scanDock.selectedWord = word
                scanDock.selectedLineText = sentence
                scanDock.surroundingContextText = surrounding

                let key = "\(Self.normalizeArabic(word))|\(sentence)|\(surrounding)"
                if scanDock.autoExplainOnTap && key != lastDeskAutoKey {
                    lastDeskAutoKey = key
                    let req = PendingContextAnalysis(
                        id: UUID(),
                        word: word,
                        line: sentence,
                        surrounding: surrounding,
                        bypassCache: false
                    )
                    triggerContextAnalysis(req, snapshot: newSnap)
                }
            }
        }
        // Desk: clicking "Explain" / "Re-run" in the web inspector explicitly runs the analyzer (bypassing cache on Re-run).
        .onChange(of: webBridge.analyzeRequest) { _, req in
            guard let req else { return }
            let surrounding = req.surrounding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? req.sentence
                : req.surrounding
            scanDock.selectedWord = req.word
            scanDock.selectedLineText = req.sentence
            scanDock.surroundingContextText = surrounding
            lastDeskAutoKey = "\(Self.normalizeArabic(req.word))|\(req.sentence)|\(surrounding)"
            let r = PendingContextAnalysis(
                id: UUID(),
                word: req.word,
                line: req.sentence,
                surrounding: surrounding,
                bypassCache: req.force
            )
            triggerContextAnalysis(r, snapshot: webBridge.snapshot)
        }
        // Hand the finished analysis back to the Desk's web inspector.
        .onChange(of: ai.isGenerating) { _, generating in
            guard !generating, let word = deskAnalysisWord else { return }
            deskAnalysisWord = nil
            if let analysis = ai.structuredAnalysis,
               let data = try? JSONEncoder().encode(analysis),
               let json = String(data: data, encoding: .utf8) {
                webBridge.showAnalysis(json: json, word: word)
            } else {
                let msg = ai.errorMessage ?? "The analysis was cancelled."
                let encoded = (try? JSONEncoder().encode(["error": msg])).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                webBridge.showAnalysis(json: encoded, word: word)
            }
        }
        // Desk: a finished OCR scan opens straight as a text in the reader.
        .onChange(of: scanDock.pages.first?.id) { _, newID in
            guard webBridge.isDesk, newID != nil, let page = scanDock.pages.first else { return }
            webBridge.openPassage(page.fullText, source: "scan")
            showScanDock = false
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    pasteAndScanFromClipboard()
                } label: {
                    Label("Paste & Scan", systemImage: "doc.viewfinder")
                }
                .disabled(scanDock.isScanning)
                .help(
                    webBridge.isDesk
                        ? "Paste Arabic text or a PDF screenshot into the Reading Desk (⌘⇧V)"
                        : "Paste screenshot from clipboard & transcribe with OCR (⌘⇧V)"
                )

                if !webBridge.isDesk {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showScanDock.toggle()
                        }
                    } label: {
                        Label(
                            scanDock.activePage == nil ? "Scanned Page" : "Scanned Page (\(scanDock.pages.count))",
                            systemImage: showScanDock ? "rectangle.topthird.inset.filled" : "text.viewfinder"
                        )
                    }
                    .tint(showScanDock || scanDock.activePage != nil ? .teal : nil)
                    .help("Show or hide persistent Scanned Page dock (⌘⇧O)")
                }

                Button {
                    ai.refreshOllamaModels()
                    showEngineSettingsPopover.toggle()
                } label: {
                    Label("AI & OCR Settings", systemImage: "slider.horizontal.3")
                }
                .help("Configure local AI model, OCR engine, CAMeL parser & auto-analyze")
                .popover(isPresented: $showEngineSettingsPopover, arrowEdge: .bottom) {
                    EngineSettingsPopoverView(ai: ai, scanDock: scanDock)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showInspector.toggle()
                    }
                } label: {
                    Label("Context & Grammar", systemImage: "sidebar.right")
                }
                .help("Toggle Context & Grammar & AI Settings Panel (⌘I)")
            }
        }
    }

    private var deskOCRStatusBanner: some View {
        HStack(spacing: 8) {
            if scanDock.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text(
                    scanDock.ocrMode == .appleVision
                        ? "Scanning screenshot with 2× Apple Vision…"
                        : (scanDock.ocrMode == .hybridVisual
                            ? "Scanning & visually proofreading with Vision + \(ai.visionModelName)…"
                            : (scanDock.ocrMode == .fastProofread
                                ? "Scanning screenshot with Vision + \(ai.localModelName)…"
                                : "Scanning screenshot with AI Vision (\(ai.visionModelName))…"))
                )
                .font(.caption.weight(.medium))
            } else if let err = scanDock.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.caption)
                    .lineLimit(2)
            }
            Spacer()
            if !scanDock.isScanning && scanDock.errorMessage != nil {
                Button {
                    scanDock.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(scanDock.errorMessage != nil && !scanDock.isScanning ? Color.orange.opacity(0.10) : Color.teal.opacity(0.08))
    }

    private func pasteAndScanFromClipboard() {
        let shouldShowDock = scanDock.pasteFromClipboard(ai: ai, webBridge: webBridge)
        if shouldShowDock && !webBridge.isDesk {
            withAnimation(.easeInOut(duration: 0.16)) { showScanDock = true }
        }
    }

    private func handleScannedWordTap(word: String, line: String, surrounding: String) {
        webBridge.lookupInContext(word, sentence: line)
        if !showInspector && !webBridge.isDesk {
            showInspector = true
        }

        pendingFallbackTask?.cancel()
        pendingFallbackTask = nil
        pendingAnalysis = nil

        guard scanDock.autoExplainOnTap else { return }

        let req = PendingContextAnalysis(
            id: UUID(),
            word: word,
            line: line,
            surrounding: surrounding,
            bypassCache: false
        )
        let currentSnap = webBridge.snapshot
        let alreadyLoaded =
            (Self.arabicLooselyMatches(currentSnap.query, word) || Self.arabicLooselyMatches(currentSnap.heroWord, word)) &&
            (!currentSnap.hansWehrText.isEmpty || !currentSnap.particlesText.isEmpty || !currentSnap.laneText.isEmpty || !currentSnap.arabicDictsText.isEmpty)

        if alreadyLoaded {
            triggerContextAnalysis(req, snapshot: currentSnap)
            return
        }

        pendingAnalysis = req
        pendingFallbackTask = Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            if pendingAnalysis?.id == req.id {
                triggerContextAnalysis(req, snapshot: webBridge.snapshot)
            }
        }
    }

    private func triggerContextAnalysis(_ req: PendingContextAnalysis, snapshot: CurrentLookupSnapshot) {
        pendingAnalysis = nil
        pendingFallbackTask?.cancel()
        pendingFallbackTask = nil

        // 0 ms instant cache hit when stepping back & forth (← / →) over previously analyzed words
        if !req.bypassCache,
           let cached = ai.cachedAnalysis(word: req.word, line: req.line, surrounding: req.surrounding) {
            ai.cancel()
            ai.activeTitle = ScholarAction.analyzeInContext(
                word: req.word,
                line: req.line,
                surrounding: req.surrounding
            ).title
            ai.outputText = ""
            ai.errorMessage = nil
            ai.structuredAnalysis = cached
            if webBridge.isDesk {
                deskAnalysisWord = nil
                if let data = try? JSONEncoder().encode(cached),
                   let json = String(data: data, encoding: .utf8) {
                    webBridge.showAnalysis(json: json, word: req.word)
                }
            }
            return
        }

        ai.run(
            action: .analyzeInContext(
                word: req.word,
                line: req.line,
                surrounding: req.surrounding,
                bypassCache: req.bypassCache
            ),
            snapshot: snapshot
        )
        if webBridge.isDesk {
            deskAnalysisWord = req.word
            webBridge.showAnalysis(json: "\"pending\"", word: req.word)
        }
    }

    /// Strips harakat, tatweel, and whitespace so vocalized scanned words match Qamus's normalized query/heroWord.
    private static func arabicLooselyMatches(_ a: String, _ b: String) -> Bool {
        let na = normalizeArabic(a)
        let nb = normalizeArabic(b)
        return !na.isEmpty && na == nb
    }

    private static func normalizeArabic(_ s: String) -> String {
        let filtered = s.unicodeScalars.filter { scalar in
            let v = scalar.value
            if (0x064B...0x065F).contains(v) || v == 0x0670 || v == 0x0640 {
                return false
            }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        return String(String.UnicodeScalarView(filtered))
            .replacingOccurrences(of: "أ", with: "ا")
            .replacingOccurrences(of: "إ", with: "ا")
            .replacingOccurrences(of: "آ", with: "ا")
            .replacingOccurrences(of: "ى", with: "ي")
            .replacingOccurrences(of: "ة", with: "ه")
    }
}

extension ScanDockStore {
    /// ⌘⇧V, shared by the menu and the toolbar. A screenshot is OCR'd; on the Desk, copied Arabic
    /// text opens straight in the reader. Returns true when the classic scan dock should be shown.
    @discardableResult
    func pasteFromClipboard(ai: ScholarAIEngine, webBridge: WebBridgeController) -> Bool {
        let pb = NSPasteboard.general
        if let img = pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            scan(
                image: img,
                ollamaBaseURL: ai.ollamaBaseURL,
                activeModel: ai.localModelName,
                activeModelSupportsVision: ai.activeModelSupportsVision,
                visionFallbackModel: ai.visionModelName
            )
            return !webBridge.isDesk
        }
        if webBridge.isDesk, let text = pb.string(forType: .string),
           text.range(of: "\\p{Arabic}", options: .regularExpression) != nil {
            errorMessage = nil
            webBridge.openPassage(text, source: "paste")
            return false
        }
        errorMessage = webBridge.isDesk
            ? "Clipboard has no screenshot or Arabic text. Capture a screenshot (⌃⌘⇧4) or copy Arabic text, then press ⌘⇧V."
            : "No image in clipboard. Capture a screenshot to clipboard (⌃⌘⇧4) or drop an image below."
        return !webBridge.isDesk
    }
}
