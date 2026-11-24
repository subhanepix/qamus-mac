import AppKit
import SwiftUI

@main
struct QamusMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var webBridge = WebBridgeController()
    @State private var ai = ScholarAIEngine()
    @State private var scanDock = ScanDockStore()
    // The Desk has its own inspector (with the AI card); the native panel stays one ⌘I away for engine settings.
    @State private var showInspector = QamusUI.saved == .classic
    @State private var showScanDock = false

    private let server: LocalWebServer?
    private let serverURL: URL?
    private let webRootURL: URL?
    private let bootError: String?

    init() {
        let webDir = Self.locateWebRoot()
        self.webRootURL = webDir
        if let webDir {
            let srv = LocalWebServer(rootURL: webDir)
            do {
                let url = try srv.start(preferredPort: 41932)
                self.server = srv
                self.serverURL = url
                self.bootError = nil
            } catch {
                self.server = nil
                self.serverURL = nil
                self.bootError = "Failed to start local dictionary server: \(error.localizedDescription)"
            }
        } else {
            self.server = nil
            self.serverURL = nil
            self.bootError = "Could not locate bundled Qamus web assets. Rebuild via macos/build-app.sh."
        }
    }

    var body: some Scene {
        WindowGroup("Qamus") {
            Group {
                if let serverURL {
                    ContentView(
                        serverURL: serverURL,
                        webBridge: webBridge,
                        ai: ai,
                        scanDock: scanDock,
                        showInspector: $showInspector,
                        showScanDock: $showScanDock
                    )
                    .onAppear {
                        appDelegate.onTerminate = {
                            ai.camelClient.stop()
                        }
                        if let webRootURL {
                            ai.loadMorphology(from: webRootURL)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("Qamus Mac Setup Issue")
                            .font(.title2.weight(.semibold))
                        Text(bootError ?? "Unknown error")
                            .foregroundStyle(.secondary)
                    }
                    .padding(40)
                }
            }
            .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            // Single-window app: ⌘N makes a new text on the Desk rather than a second window.
            CommandGroup(replacing: .newItem) {
                Button("New Text") {
                    webBridge.newText()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!webBridge.isDesk)
            }

            CommandGroup(before: .toolbar) {
                Picker("Interface", selection: Binding(
                    get: { webBridge.ui },
                    set: { newUI in
                        webBridge.setUI(newUI)
                        showInspector = newUI == .classic
                    }
                )) {
                    ForEach(QamusUI.allCases) { ui in
                        Text(ui.title).tag(ui)
                    }
                }
                .pickerStyle(.inline)
                Divider()
            }

            CommandGroup(after: .textEditing) {
                Button("Look Up…") {
                    webBridge.focusSearch()
                }
                .keyboardShortcut("k", modifiers: .command)

                Button(webBridge.isDesk ? "Paste Text or Screenshot" : "Paste & Scan PDF Screenshot") {
                    if scanDock.pasteFromClipboard(ai: ai, webBridge: webBridge) && !webBridge.isDesk {
                        showScanDock = true
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                if !webBridge.isDesk {
                    Button(showScanDock ? "Hide Scanned Page Dock" : "Show Scanned Page Dock") {
                        showScanDock.toggle()
                    }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                }

                Divider()

                Button(showInspector ? "Hide Context & Grammar Panel" : "Show Context & Grammar Panel") {
                    showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Reload Dictionary View") {
                    webBridge.reload()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private static func locateWebRoot() -> URL? {
        let fm = FileManager.default
        // 1. Inside bundled Qamus.app/Contents/Resources/web
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("web"),
           fm.fileExists(atPath: resURL.appendingPathComponent("index.html").path) {
            return resURL
        }
        // 2. Development fallback: ../dist or ../ relative to macos/
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        for rel in ["dist", "../dist", ".."] {
            let candidate = cwd.appendingPathComponent(rel).standardizedFileURL
            if fm.fileExists(atPath: candidate.appendingPathComponent("index.html").path) &&
                fm.fileExists(atPath: candidate.appendingPathComponent("data/index.json").path) {
                return candidate
            }
        }
        return nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}
