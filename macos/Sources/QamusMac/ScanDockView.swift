import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScanDockView: View {
    @Bindable var scanDock: ScanDockStore
    let ai: ScholarAIEngine
    let onTapWord: (_ word: String, _ line: String, _ surrounding: String) -> Void
    let onClose: () -> Void

    @State private var editDraft = ""
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            dockHeader
            Divider()

            if let err = scanDock.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        scanDock.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.10))
                Divider()
            }

            dockBody
        }
        .background(.background)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isDropTargeted ? Color.teal : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var dockHeader: some View {
        HStack(spacing: 8) {
            Label("Scanned Page", systemImage: "text.viewfinder")
                .font(.subheadline.weight(.semibold))

            if let page = scanDock.activePage {
                Text(page.engineLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.teal.opacity(0.12), in: Capsule())
            }

            if scanDock.pages.count > 1 {
                HStack(spacing: 2) {
                    Button {
                        if scanDock.activePageIndex > 0 {
                            scanDock.activePageIndex -= 1
                            scanDock.isEditingText = false
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(scanDock.activePageIndex <= 0)

                    Text("\(scanDock.activePageIndex + 1)/\(scanDock.pages.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        if scanDock.activePageIndex + 1 < scanDock.pages.count {
                            scanDock.activePageIndex += 1
                            scanDock.isEditingText = false
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(scanDock.activePageIndex + 1 >= scanDock.pages.count)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.4), in: Capsule())
                .help("Switch between recent scans")
            }

            Spacer()

            // OCR Engine selector + Re-scan
            Menu {
                Picker("OCR Engine", selection: $scanDock.ocrMode) {
                    ForEach(OCREngineMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                if scanDock.activePage != nil {
                    Divider()
                    Button {
                        scanDock.rescanActive(
                            ollamaBaseURL: ai.ollamaBaseURL,
                            activeModel: ai.localModelName,
                            activeModelSupportsVision: ai.activeModelSupportsVision,
                            visionFallbackModel: ai.visionModelName
                        )
                    } label: {
                        Label("Re-scan Current Image", systemImage: "arrow.clockwise")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: scanDock.ocrMode == .appleVision ? "bolt.fill" : "sparkles")
                        .font(.caption2)
                    Text(scanDock.ocrMode.shortLabel)
                        .font(.caption)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose OCR Engine (Vision + Active AI proofreads with \(ai.localModelName) without swapping models)")

            if scanDock.activePage != nil {
                Button {
                    scanDock.rescanActive(
                        ollamaBaseURL: ai.ollamaBaseURL,
                        activeModel: ai.localModelName,
                        activeModelSupportsVision: ai.activeModelSupportsVision,
                        visionFallbackModel: ai.visionModelName
                    )
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(scanDock.isScanning)
                .help("Re-scan current image with \(scanDock.ocrMode.rawValue)")

                Divider().frame(height: 14)

                // Source image side-by-side toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        scanDock.showSourceImage.toggle()
                    }
                } label: {
                    Image(systemName: scanDock.showSourceImage ? "photo.fill" : "photo")
                        .foregroundStyle(scanDock.showSourceImage ? .teal : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Show/hide original screenshot alongside text")

                // Inline edit toggle
                Button {
                    if scanDock.isEditingText {
                        scanDock.updateActiveText(editDraft)
                        scanDock.isEditingText = false
                    } else {
                        editDraft = scanDock.activePage?.fullText ?? ""
                        scanDock.isEditingText = true
                    }
                } label: {
                    Image(systemName: scanDock.isEditingText ? "checkmark.circle.fill" : "pencil")
                        .foregroundStyle(scanDock.isEditingText ? .teal : .secondary)
                }
                .buttonStyle(.borderless)
                .help(scanDock.isEditingText ? "Apply text edits" : "Edit OCR text manually")

                // Font size controls
                HStack(spacing: 2) {
                    Button {
                        scanDock.fontSize = max(16, scanDock.fontSize - 2)
                    } label: {
                        Text("A−").font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Decrease Arabic text size")

                    Button {
                        scanDock.fontSize = min(34, scanDock.fontSize + 2)
                    } label: {
                        Text("A+").font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Increase Arabic text size")
                }
                .padding(.horizontal, 4)
            }

            Divider().frame(height: 14)

            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .controlSize(.small)
            .disabled(scanDock.isScanning)
            .help("Paste screenshot from clipboard & scan (⌘⇧V)")

            Button {
                pickImageFile()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .disabled(scanDock.isScanning)
            .help("Choose image file to scan…")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Hide Scanned Page dock (⌘⇧O)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    @ViewBuilder
    private var dockBody: some View {
        if scanDock.isScanning {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text(
                    scanDock.ocrMode == .hybridVisual
                        ? "Scanning & visually proofreading with Vision + \(ai.visionModelName)…"
                        : (scanDock.ocrMode == .fastProofread
                            ? "Scanning & proofreading with Vision + \(ai.localModelName)…"
                            : (scanDock.ocrMode == .aiVision
                                ? "Transcribing Arabic with AI Vision (\(ai.visionModelName))…"
                                : "Transcribing Arabic with 2× Apple Vision…"))
                )
                .font(.callout.weight(.medium))
                Text("Preserving exact spelling, letter dots, and line breaks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        } else if let page = scanDock.activePage {
            HStack(spacing: 0) {
                if scanDock.showSourceImage {
                    VStack(spacing: 4) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: page.image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 420)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                        }
                    }
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 380)
                    .background(.quaternary.opacity(0.2))

                    Divider()
                }

                if scanDock.isEditingText {
                    VStack(spacing: 8) {
                        TextEditor(text: $editDraft)
                            .font(.custom("Geeza Pro", size: max(18, scanDock.fontSize - 2)))
                            .multilineTextAlignment(.trailing)
                            .padding(6)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

                        HStack {
                            Text("Fix any misread letters or line breaks, then click Apply.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") {
                                scanDock.isEditingText = false
                            }
                            .controlSize(.small)
                            Button("Apply Edits") {
                                scanDock.updateActiveText(editDraft)
                                scanDock.isEditingText = false
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.teal)
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                } else {
                    interactiveLinesView(page: page)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyDropzone
        }
    }

    private func interactiveLinesView(page: ScannedPage) -> some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Text("Click any Arabic word to look it up in Qamus — this pane stays open while you read.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Auto-explain in line", isOn: $scanDock.autoExplainOnTap)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)

                ForEach(page.lines) { line in
                    let isLineSelected = scanDock.selectedLineId == line.id
                    RTLFlowLayout(horizontalSpacing: 5, verticalSpacing: 4) {
                        ForEach(line.tokens) { token in
                            if token.isArabicWord {
                                WordTokenButton(
                                    text: token.text,
                                    fontSize: scanDock.fontSize,
                                    isSelected: scanDock.selectedTokenId == token.id
                                ) {
                                    scanDock.selectWord(token: token, in: line)
                                    onTapWord(token.text, line.text, scanDock.surroundingContextText)
                                }
                            } else {
                                Text(token.text)
                                    .font(.system(size: max(14, scanDock.fontSize * 0.78)))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isLineSelected ? Color.teal.opacity(0.08) : Color.secondary.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isLineSelected ? Color.teal.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
                }
            }
            .padding(12)
        }
    }

    private var emptyDropzone: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 26))
                .foregroundStyle(.teal)
            Text("Paste a PDF screenshot (⌘⇧V) or drop an image here")
                .font(.callout.weight(.medium))
            Text("Scanned pages stay docked here so you can tap multiple words in order and get each word's meaning in its exact line.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isDropTargeted ? Color.teal.opacity(0.10) : Color.secondary.opacity(0.04))
                .padding(10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [6])
                )
                .foregroundStyle(isDropTargeted ? Color.teal : Color.secondary.opacity(0.3))
                .padding(10)
        )
    }

    private func pasteFromClipboard() {
        if let img = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            scanDock.scan(
                image: img,
                ollamaBaseURL: ai.ollamaBaseURL,
                activeModel: ai.localModelName,
                activeModelSupportsVision: ai.activeModelSupportsVision,
                visionFallbackModel: ai.visionModelName
            )
        } else {
            scanDock.errorMessage = "No image found in clipboard. Take a screenshot to clipboard (⌃⌘⇧4) first."
        }
    }

    private func pickImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            scanDock.scan(
                image: img,
                ollamaBaseURL: ai.ollamaBaseURL,
                activeModel: ai.localModelName,
                activeModelSupportsVision: ai.activeModelSupportsVision,
                visionFallbackModel: ai.visionModelName
            )
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let baseURL = ai.ollamaBaseURL
        let activeModel = ai.localModelName
        let supportsVision = ai.activeModelSupportsVision
        let fallbackModel = ai.visionModelName

        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                if let img = obj as? NSImage {
                    Task { @MainActor in
                        scanDock.scan(
                            image: img,
                            ollamaBaseURL: baseURL,
                            activeModel: activeModel,
                            activeModelSupportsVision: supportsVision,
                            visionFallbackModel: fallbackModel
                        )
                    }
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   let img = NSImage(contentsOf: url) {
                    Task { @MainActor in
                        scanDock.scan(
                            image: img,
                            ollamaBaseURL: baseURL,
                            activeModel: activeModel,
                            activeModelSupportsVision: supportsVision,
                            visionFallbackModel: fallbackModel
                        )
                    }
                }
            }
            return true
        }
        return false
    }
}

/// Interactive Arabic word token with crisp hover and active selection styling.
private struct WordTokenButton: View {
    let text: String
    let fontSize: Double
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.custom("Geeza Pro", size: fontSize))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isSelected
                                ? Color.teal.opacity(0.24)
                                : (isHovered ? Color.teal.opacity(0.12) : Color.clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isSelected ? Color.teal : (isHovered ? Color.teal.opacity(0.35) : Color.clear),
                            lineWidth: isSelected ? 1.5 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Deterministic Right-to-Left wrapping flow layout so Arabic lines always read naturally
/// from the right margin leftward and wrap downward without mirroring surprises.
struct RTLFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 5
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = max(100, proposal.width ?? 600)
        var rowW: CGFloat = 0
        var totalH: CGFloat = 0
        var rowH: CGFloat = 0

        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if rowW > 0 && rowW + horizontalSpacing + s.width > maxW {
                totalH += rowH + verticalSpacing
                rowW = s.width
                rowH = s.height
            } else {
                rowW = rowW == 0 ? s.width : rowW + horizontalSpacing + s.width
                rowH = max(rowH, s.height)
            }
        }
        totalH += rowH
        return CGSize(width: maxW, height: max(rowH, totalH))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Group into rows first so every item in a row aligns cleanly on vertical center
        var rows: [[(LayoutSubview, CGSize)]] = []
        var currentRow: [(LayoutSubview, CGSize)] = []
        var rowW: CGFloat = 0

        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if !currentRow.isEmpty && rowW + horizontalSpacing + s.width > bounds.width {
                rows.append(currentRow)
                currentRow = [(v, s)]
                rowW = s.width
            } else {
                currentRow.append((v, s))
                rowW = rowW == 0 ? s.width : rowW + horizontalSpacing + s.width
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        var y = bounds.minY
        for row in rows {
            let rowH = row.map(\.1.height).max() ?? 0
            var cursorRight = bounds.maxX
            for (v, s) in row {
                let x = cursorRight - s.width
                let itemY = y + (rowH - s.height) / 2.0
                v.place(at: CGPoint(x: x, y: itemY), proposal: ProposedViewSize(s))
                cursorRight = x - horizontalSpacing
            }
            y += rowH + verticalSpacing
        }
    }
}
