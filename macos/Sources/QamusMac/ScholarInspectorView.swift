import AppKit
import SwiftUI

struct ScholarInspectorView: View {
    let webBridge: WebBridgeController
    @Bindable var ai: ScholarAIEngine
    @Bindable var scanDock: ScanDockStore

    @State private var manualPassage = ""
    @State private var customQuestion = ""
    @State private var showEngineSettings = false

    private var activePassageForQuestions: String {
        if !scanDock.surroundingContextText.isEmpty {
            return scanDock.surroundingContextText
        }
        if !scanDock.selectedLineText.isEmpty {
            return scanDock.selectedLineText
        }
        return manualPassage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    passageContextCard
                    structuredOutputSection
                    freeformOutputSection
                    secondaryToolsSection
                }
                .padding(14)
            }

            Divider()
            askBar
        }
        .background(.background)
        .onAppear {
            ai.refreshOllamaModels()
        }
    }

    // MARK: - Header

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 1) {
                Text("Context & Grammar")
                    .font(.headline)
                Text(engineSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                ai.refreshOllamaModels()
                showEngineSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Local AI Model & Engine Settings")
            .popover(isPresented: $showEngineSettings, arrowEdge: .bottom) {
                EngineSettingsPopoverView(ai: ai, scanDock: scanDock)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var engineSubtitle: String {
        if ai.backendMode == .appleOnDevice {
            return ai.appleAvailabilityLabel
        }
        let thinkTag = (ai.isReasoningModel && ai.enableGrammarReasoning) ? " · Reasoning" : ""
        return "Local · \(ai.localModelName)\(thinkTag)"
    }

    // MARK: - Immediate Passage / Scanned Line Card

    @ViewBuilder
    private var passageContextCard: some View {
        if !scanDock.selectedLineText.isEmpty {
            scannedLineCard
        } else {
            manualPassageCard
        }
    }

    private var scannedLineCard: some View {
        let word = scanDock.selectedWord.isEmpty ? webBridge.snapshot.displayTitle : scanDock.selectedWord
        let line = scanDock.selectedLineText
        let surrounding = scanDock.surroundingContextText.isEmpty ? line : scanDock.surroundingContextText
        let hasMultiLineContext = surrounding.contains("\n")

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("ACTIVE LINE", systemImage: "text.quote")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.teal)

                if hasMultiLineContext {
                    Text("+context")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .help("Surrounding lines are automatically included so wrapped sentences stay intact")
                }

                Spacer()

                Toggle("Auto", isOn: $scanDock.autoExplainOnTap)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption2)
                    .help("Automatically analyze clicked words in the Scanned Page dock")

                Button {
                    scanDock.clearSelection()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear active scanned line")
            }

            Text(highlightedLine(line: line, word: word))
                .font(.custom("Geeza Pro", size: 17))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)

            HStack {
                if !word.isEmpty {
                    Text(word)
                        .font(.custom("Geeza Pro", size: 15))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.16), in: Capsule())
                }
                Spacer()
                Button {
                    ai.run(
                        action: .analyzeInContext(word: word, line: line, surrounding: surrounding, bypassCache: true),
                        snapshot: webBridge.snapshot
                    )
                } label: {
                    Label("Analyze", systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .controlSize(.small)
                .disabled(word.isEmpty || ai.isGenerating)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.teal.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.teal.opacity(0.26), lineWidth: 1)
        )
    }

    private var manualPassageCard: some View {
        let snap = webBridge.snapshot
        let trimmedPassage = manualPassage.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetWord = snap.displayTitle

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("IMMEDIATE CONTEXT", systemImage: "text.alignright")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !trimmedPassage.isEmpty {
                    Button("Clear") {
                        manualPassage = ""
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            TextField("Paste an Arabic sentence or scan a PDF (⌘⇧V)…", text: $manualPassage, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .font(.custom("Geeza Pro", size: 15))
                .multilineTextAlignment(.trailing)

            HStack {
                if snap.hasLookup {
                    Text("Word: \(targetWord)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Look up a word or tap one in Scanned Page")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    ai.run(
                        action: .analyzeInContext(
                            word: targetWord,
                            line: trimmedPassage,
                            surrounding: trimmedPassage,
                            bypassCache: true
                        ),
                        snapshot: snap
                    )
                } label: {
                    Label("Analyze", systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .controlSize(.small)
                .disabled(!snap.hasLookup || trimmedPassage.isEmpty || ai.isGenerating)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: - Structured Word-in-Context Grammar Card

    @ViewBuilder
    private var structuredOutputSection: some View {
        if let err = ai.errorMessage {
            VStack(alignment: .leading, spacing: 6) {
                Label("Could not analyze", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        }

        if ai.isGenerating && ai.structuredAnalysis == nil && ai.outputText.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(ai.statusLabel.isEmpty ? "Analyzing…" : ai.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { ai.cancel() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(12)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
        }

        if let analysis = ai.structuredAnalysis {
            structuredCard(analysis)
        }
    }

    private func structuredCard(_ analysis: ContextualWordAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top bar: Morphology & vocalized headword
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(analysis.partOfSpeech)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.teal)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(analysis.arabicTag)
                        .font(.custom("Geeza Pro", size: 13))
                        .foregroundStyle(.secondary)
                    verificationBadge(for: analysis)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(analysis.vocalized)
                        .font(.custom("Geeza Pro", size: 24))
                        .fontWeight(.bold)
                        .textSelection(.enabled)
                    if let root = analysis.root, !root.isEmpty {
                        Text("Root · \(root)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.teal)
                    }
                }
            }

            Divider()

            // 1. Meaning Here
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("MEANING HERE")
                Text(analysis.meaningHere)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            // 2. Acting on It (العوامل والمتعلقات)
            if !analysis.actingOnIt.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("ACTING ON IT · العوامل")
                    ForEach(analysis.actingOnIt) { mod in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(mod.particle)
                                .font(.custom("Geeza Pro", size: 16))
                                .fontWeight(.semibold)
                                .foregroundStyle(.teal)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(mod.role)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(mod.effect)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(7)
                        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            // 3. Grammar & Syntactic Role (الإعراب)
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("GRAMMAR & ROLE · الإعراب")
                Text(analysis.syntaxRole)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !analysis.arguments.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(analysis.arguments) { arg in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(arg.relation)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(arg.arabic)
                                        .font(.custom("Geeza Pro", size: 16))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                                if let note = arg.note, !note.isEmpty {
                                    Text(note)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }

            // 4. Clause Translation & Context-Vocalized Line
            VStack(alignment: .leading, spacing: 6) {
                if let diac = analysis.diacritizedLine, !diac.isEmpty {
                    sectionLabel("VOCALIZED LINE · CAMeL")
                    Text(diac)
                        .font(.custom("Geeza Pro", size: 15))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                        .textSelection(.enabled)
                }
                sectionLabel("CLAUSE TRANSLATION")
                Text("“\(analysis.clauseTranslation)”")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            // 5. Cross-Check / Ambiguity Caution Notes
            if let alt = analysis.camelAlternative, !alt.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(alt)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if let note = analysis.ambiguityNote, !note.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            // Footer actions
            HStack {
                Text("Draft parse · verify subtle iʿrāb")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(analysis.plainTextSummary, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy structured summary")

                Button {
                    ai.clear()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Clear")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func verificationBadge(for analysis: ContextualWordAnalysis) -> some View {
        let pct = analysis.camelConfidence.map { Int(($0 * 100.0).rounded()) }
        switch analysis.camelAgreement {
        case "agreed":
            Label(
                pct.map { "CAMeL verified (\($0)%)" } ?? "CAMeL verified",
                systemImage: "checkmark.seal.fill"
            )
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Color.teal)
            .help("CAMeL Tools BERT Arabic parser and the local LLM agree on this parse")
        case "check":
            Label("Check parse · CAMeL vs AI", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.orange)
                .help("CAMeL Tools and the LLM disagreed — see the amber cross-check note below")
        case "split":
            Label(
                pct.map { "CAMeL split (\($0)%)" } ?? "CAMeL split",
                systemImage: "questionmark.circle.fill"
            )
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Color.orange)
            .help("CAMeL Tools found close competing parses — verify harakat in context")
        default:
            Label(
                analysis.morphVerified ? "Buckwalter verified" : "AI-inferred morphology",
                systemImage: analysis.morphVerified ? "checkmark.seal.fill" : "sparkles"
            )
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(analysis.morphVerified ? Color.teal : Color.secondary)
            .help(
                analysis.morphVerified
                    ? "Tense, voice, form, and root anchored to Qamus's deterministic Buckwalter analyzer"
                    : "Rare/unlisted word or override — morphology inferred directly by the model"
            )
        }
    }

    // MARK: - Freeform Output (TL;DR, Arabic Dicts, Flashcards, Follow-up Questions)

    @ViewBuilder
    private var freeformOutputSection: some View {
        if !ai.outputText.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(ai.activeTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.teal)
                    Spacer()
                    if ai.isGenerating {
                        ProgressView().controlSize(.mini)
                        Button("Stop") { ai.cancel() }
                            .buttonStyle(.link)
                            .font(.caption)
                    } else {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ai.outputText, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy response")

                        Button {
                            ai.clear()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear response")
                    }
                }

                Text(markdownAttributed(ai.outputText))
                    .font(.callout)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
    }

    // MARK: - Compact Dictionary Entry Tools

    @ViewBuilder
    private var secondaryToolsSection: some View {
        let snap = webBridge.snapshot
        if snap.hasLookup {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("ENTRY TOOLS · \(snap.displayTitle)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if !snap.roots.isEmpty {
                        Text(snap.roots.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.teal)
                    }
                }

                HStack(spacing: 6) {
                    toolButton("TL;DR", icon: "text.alignleft", disabled: ai.isGenerating) {
                        ai.run(action: .summarizeEntry, snapshot: snap)
                    }
                    toolButton("Arabic Dict", icon: "character.book.closed.ar", disabled: ai.isGenerating || !snap.hasArabicDicts) {
                        ai.run(action: .explainArabicDict, snapshot: snap)
                    }
                    toolButton("Flashcard", icon: "rectangle.on.rectangle.angled", disabled: ai.isGenerating) {
                        ai.run(action: .draftFlashcard, snapshot: snap)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func toolButton(_ title: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
    }

    // MARK: - Ask Bar

    private var askBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about this word or grammar…", text: $customQuestion)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onSubmit { submitQuestion() }

            Button {
                submitQuestion()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .tint(.teal)
            .disabled(customQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ai.isGenerating)
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func highlightedLine(line: String, word: String) -> AttributedString {
        var attr = AttributedString(line)
        if !word.isEmpty, let range = attr.range(of: word) {
            attr[range].foregroundColor = .teal
            attr[range].backgroundColor = Color.teal.opacity(0.16)
        }
        return attr
    }

    private func submitQuestion() {
        let q = customQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        customQuestion = ""
        ai.run(
            action: .customQuestion(question: q, passage: activePassageForQuestions),
            snapshot: webBridge.snapshot
        )
    }

    private func markdownAttributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Shared AI, CAMeL, OCR & auto-analyze settings popover (accessible from both the native titlebar and the inspector).
struct EngineSettingsPopoverView: View {
    @Bindable var ai: ScholarAIEngine
    @Bindable var scanDock: ScanDockStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On-Device AI Engine")
                .font(.headline)

            Picker("Engine", selection: $ai.backendMode) {
                ForEach(AIBackendMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if ai.backendMode == .appleOnDevice {
                VStack(alignment: .leading, spacing: 4) {
                    Label(ai.appleAvailabilityLabel, systemImage: ai.isAppleAvailable ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ai.isAppleAvailable ? .green : .orange)
                    Text("Uses Apple's built-in FoundationModels framework locally with zero downloads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect to local Ollama, LM Studio, or mlx_lm.server. Ollama uses strict JSON-schema decoding for zero-fluff grammar cards.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Endpoint URL", text: $ai.localEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    TextField("Model name (e.g. qwen3.5:9b or gemma3:12b)", text: $ai.localModelName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    if !ai.availableOllamaModels.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Installed Ollama models:")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 90), spacing: 6)],
                                alignment: .leading,
                                spacing: 6
                            ) {
                                ForEach(ai.availableOllamaModels, id: \.self) { name in
                                    Button {
                                        ai.localModelName = name
                                    } label: {
                                        Text(name)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(ai.localModelName == name ? .teal : nil)
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }

                    if ai.isReasoningModel {
                        Toggle("Grammar reasoning pass (<think>)", isOn: $ai.enableGrammarReasoning)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.caption)
                            .help("Lets Qwen3/3.5 verify passive vs. active voice and iʿrāb before emitting the card (slightly slower, sharper syntax).")
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Toggle("CAMeL Arabic Parser", isOn: Binding(
                        get: { ai.camelClient.isEnabled },
                        set: { ai.camelClient.isEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption.weight(.medium))

                    Spacer()

                    HStack(spacing: 4) {
                        Circle()
                            .fill(ai.camelClient.isReady ? Color.green : (ai.camelClient.isStarting ? Color.orange : Color.secondary.opacity(0.4)))
                            .frame(width: 6, height: 6)
                        Text(ai.camelClient.statusLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text("NYU Abu Dhabi BERT Arabic diacritizer & disambiguator (~1.2 GB RAM). Adds context harakat, case endings, and cross-check confidence.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Screenshot OCR Engine")
                    .font(.caption.weight(.semibold))
                Picker("OCR", selection: $scanDock.ocrMode) {
                    ForEach(OCREngineMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                Text(ocrModeHelpText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Auto-analyze on word click", isOn: $scanDock.autoExplainOnTap)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption.weight(.medium))
                    .help("Automatically run Grammar-in-Context when clicking or stepping through words")

                if ai.cachedEntryCount > 0 {
                    HStack {
                        Text("\(ai.cachedEntryCount) cached word \(ai.cachedEntryCount == 1 ? "parse" : "parses") in memory")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear Cache") {
                            ai.clearCache()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.teal)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var ocrModeHelpText: String {
        switch scanDock.ocrMode {
        case .hybridVisual:
            return "Best accuracy: 2× Apple Vision baseline + \(ai.visionModelName) visually checks the image for ornate brackets & harakat."
        case .fastProofread:
            return "Zero model swap: 2× Apple Vision (0.2s) + fast Arabic text proofread using your loaded \(ai.localModelName)."
        case .appleVision:
            return "Pure 2× Lanczos-upscaled Apple Vision. Instant (~0.2s), zero LLM overhead."
        case .aiVision:
            return "Pure multimodal image-to-text via \(ai.visionModelName) (no Apple Vision baseline)."
        }
    }
}
