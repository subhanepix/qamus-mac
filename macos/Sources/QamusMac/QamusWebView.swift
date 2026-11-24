import AppKit
import Foundation
import Observation
import SwiftUI
import WebKit

struct CurrentLookupSnapshot: Equatable, Sendable {
    var query: String = ""
    var heroWord: String = ""
    var translit: String = ""
    var roots: [String] = []
    var particlesText: String = ""
    var hansWehrText: String = ""
    var wiktionaryText: String = ""
    var laneText: String = ""
    var arabicDictsText: String = ""
    var viewKind: String = "home"
    var theme: String = "paper"
    var deskContextWord: String = ""
    var deskContextSentence: String = ""
    var deskContextSurrounding: String = ""

    var hasLookup: Bool {
        !heroWord.isEmpty || !query.isEmpty
    }

    var displayTitle: String {
        if !heroWord.isEmpty { return heroWord }
        return query
    }

    var hasArabicDicts: Bool {
        !arabicDictsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasLane: Bool {
        !laneText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Compact grounded context string sized safely for on-device context windows.
    func groundedContext(maxChars: Int = 4200) -> String {
        var chunks: [String] = []
        if !heroWord.isEmpty {
            chunks.append("Headword: \(heroWord)\(translit.isEmpty ? "" : " (\(translit))")")
        } else if !query.isEmpty {
            chunks.append("Query: \(query)")
        }
        if !roots.isEmpty {
            chunks.append("Root(s): \(roots.joined(separator: ", "))")
        }
        if !particlesText.isEmpty {
            chunks.append("[Particles & Grammar]\n\(particlesText.prefix(1200))")
        }
        if !hansWehrText.isEmpty {
            chunks.append("[Hans Wehr]\n\(hansWehrText.prefix(2400))")
        }
        if !wiktionaryText.isEmpty {
            chunks.append("[Wiktionary]\n\(wiktionaryText.prefix(600))")
        }
        if !laneText.isEmpty {
            chunks.append("[Lane's Lexicon]\n\(laneText.prefix(1200))")
        }
        if !arabicDictsText.isEmpty {
            chunks.append("[Classical Arabic Dictionaries (al-Mufradāt / Mukhtār)]\n\(arabicDictsText.prefix(1200))")
        }
        let joined = chunks.joined(separator: "\n\n")
        return String(joined.prefix(maxChars))
    }
}

/// Which web front end the shell loads: the reading-first Desk (`redesign/`) or the classic dictionary.
enum QamusUI: String, CaseIterable, Identifiable {
    case desk
    case classic

    var id: String { rawValue }
    var title: String { self == .desk ? "Reading Desk" : "Classic Dictionary" }

    static var saved: QamusUI {
        QamusUI(rawValue: UserDefaults.standard.string(forKey: "qamus.mac.ui") ?? "") ?? .desk
    }
}

/// An "Explain" / "Re-run" request from the Desk's inspector: analyze `word` inside `sentence` (and `surrounding` passage).
struct DeskAnalyzeRequest: Equatable {
    let id = UUID()
    let word: String
    let sentence: String
    let surrounding: String
    let force: Bool
}

@MainActor
@Observable
final class WebBridgeController {
    var snapshot = CurrentLookupSnapshot()
    var isLoaded = false
    var ui: QamusUI = QamusUI.saved
    var analyzeRequest: DeskAnalyzeRequest?
    var baseURL: URL?
    weak var webView: WKWebView?

    var isDesk: Bool { ui == .desk }

    /// The page for the current UI. The Desk lives in `redesign/` and shares engine.js and data/ with the classic app.
    var currentURL: URL? {
        guard let baseURL else { return nil }
        return isDesk ? baseURL.appendingPathComponent("redesign/") : baseURL
    }

    func setUI(_ newUI: QamusUI) {
        guard newUI != ui else { return }
        ui = newUI
        UserDefaults.standard.set(newUI.rawValue, forKey: "qamus.mac.ui")
        snapshot = CurrentLookupSnapshot()
        if let url = currentURL { webView?.load(URLRequest(url: url)) }
    }

    private func js(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let s = String(data: data, encoding: .utf8) else { return "\"\"" }
        return s
    }

    private func run(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    func search(_ word: String) {
        lookupInContext(word, sentence: "")
    }

    /// Looks a word up. On the Desk the sentence travels with it, so saving keeps the context.
    func lookupInContext(_ word: String, sentence: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isDesk {
            run("window.qamus && window.qamus.lookup(\(js(trimmed)), \(js(sentence)));")
            return
        }
        run("""
        (function() {
          const w = \(js(trimmed));
          const inp = document.getElementById('q');
          if (inp) inp.value = w;
          window.location.hash = '#' + new URLSearchParams({ q: w }).toString();
        })();
        """)
    }

    /// Opens text (pasted or OCR'd) as a new text in the Desk's reader.
    func openPassage(_ text: String, source: String, title: String = "") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDesk, !trimmed.isEmpty else { return }
        run("window.qamus && window.qamus.openPassage(\(js(trimmed)), { source: \(js(source)), title: \(js(title)) });")
    }

    func newText() {
        if isDesk { run("location.hash = '#/new';") }
    }

    /// Hands a ContextualWordAnalysis (as JSON), 'pending', or an error to the Desk's inspector for `word`.
    func showAnalysis(json: String, word: String) {
        guard isDesk else { return }
        run("window.qamus && window.qamus.showAnalysis(\(json), \(js(word)));")
    }

    func focusSearch() {
        if isDesk {
            run("document.getElementById('open-palette')?.click();")
            return
        }
        run("const el = document.getElementById('q'); if (el) { el.focus(); el.select(); }")
    }

    func navigateHash(_ hash: String) {
        guard let webView else { return }
        if let encoded = try? JSONEncoder().encode(hash),
           let json = String(data: encoded, encoding: .utf8) {
            webView.evaluateJavaScript("window.location.hash = \(json);", completionHandler: nil)
        }
    }

    func reload() {
        webView?.reload()
    }
}

struct QamusWebView: NSViewRepresentable {
    let url: URL
    let controller: WebBridgeController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "qamusNative")

        // Non-invasive observer injected ONLY inside the macOS app container.
        // Leaves the website files completely untouched while giving the native AI Scholar
        // live grounded visibility into the currently displayed dictionary entries.
        let bridgeScript = WKUserScript(
            source: Self.observerJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(bridgeScript)
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")

        controller.webView = webView
        controller.baseURL = url
        webView.load(URLRequest(url: controller.currentURL ?? url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Keep WKWebView stable across SwiftUI state updates
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let controller: WebBridgeController

        init(controller: WebBridgeController) {
            self.controller = controller
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "qamusNative",
                  let dict = message.body as? [String: Any] else { return }

            // The Desk posts typed messages with a structured lookup: no DOM scraping needed.
            if let type = dict["type"] as? String {
                switch type {
                case "lookup":
                    guard let lookup = dict["lookup"] as? [String: Any] else { return }
                    let snap = Self.snapshot(fromDesk: lookup)
                    Task { @MainActor in
                        if self.controller.snapshot != snap { self.controller.snapshot = snap }
                    }
                case "analyze":
                    let word = dict["word"] as? String ?? ""
                    let sentence = dict["sentence"] as? String ?? ""
                    let rawSurrounding = dict["surrounding"] as? String ?? ""
                    let surrounding = rawSurrounding.isEmpty ? sentence : rawSurrounding
                    let force = dict["force"] as? Bool ?? false
                    guard !word.isEmpty else { return }
                    Task { @MainActor in
                        self.controller.analyzeRequest = DeskAnalyzeRequest(
                            word: word,
                            sentence: sentence,
                            surrounding: surrounding,
                            force: force
                        )
                    }
                default:
                    break
                }
                return
            }

            let snap = CurrentLookupSnapshot(
                query: dict["query"] as? String ?? "",
                heroWord: dict["heroWord"] as? String ?? "",
                translit: dict["translit"] as? String ?? "",
                roots: dict["roots"] as? [String] ?? [],
                particlesText: dict["particlesText"] as? String ?? "",
                hansWehrText: dict["hansWehrText"] as? String ?? "",
                wiktionaryText: dict["wiktionaryText"] as? String ?? "",
                laneText: dict["laneText"] as? String ?? "",
                arabicDictsText: dict["arabicDictsText"] as? String ?? "",
                viewKind: dict["viewKind"] as? String ?? "home",
                theme: dict["theme"] as? String ?? "paper"
            )
            Task { @MainActor in
                if self.controller.snapshot != snap {
                    self.controller.snapshot = snap
                }
            }
        }

        /// Maps the Desk's `window.qamus.current()` payload onto the snapshot the AI engine grounds itself in.
        static func snapshot(fromDesk l: [String: Any]) -> CurrentLookupSnapshot {
            var particles: [String] = [], hansWehr: [String] = [], wikt: [String] = []
            for a in l["answers"] as? [[String: Any]] ?? [] {
                let head = a["head"] as? String ?? ""
                let tr = a["tr"] as? String ?? ""
                let label = a["label"] as? String ?? ""
                let text = (a["text"] as? String ?? "").prefix(900)
                let line = "\(head)\(tr.isEmpty ? "" : " (\(tr))") [\(label)]: \(text)"
                switch a["source"] as? String ?? "" {
                case "particle": particles.append(line)
                case "wikt": wikt.append(line)
                default: hansWehr.append(line)
                }
            }
            let parses = (l["parses"] as? [[String: Any]] ?? []).compactMap { p -> String? in
                guard let gloss = p["gloss"] as? String else { return nil }
                let segs = (p["segments"] as? [[String: Any]] ?? []).compactMap { $0["ar"] as? String }.joined(separator: " + ")
                return "Parsed: \(segs) = \(gloss)"
            }
            let ctx = l["context"] as? [String: Any] ?? [:]
            let ctxWord = ctx["word"] as? String ?? ""
            let ctxSentence = ctx["sentence"] as? String ?? ""
            let rawSurrounding = ctx["surrounding"] as? String ?? ""
            let ctxSurrounding = rawSurrounding.isEmpty ? ctxSentence : rawSurrounding
            return CurrentLookupSnapshot(
                query: l["query"] as? String ?? "",
                heroWord: l["word"] as? String ?? "",
                translit: l["tr"] as? String ?? "",
                roots: (l["roots"] as? [[String: Any]] ?? []).compactMap { $0["letters"] as? String },
                particlesText: particles.joined(separator: "\n"),
                hansWehrText: (parses + hansWehr).joined(separator: "\n"),
                wiktionaryText: wikt.joined(separator: "\n"),
                laneText: "",
                arabicDictsText: "",
                viewKind: "result",
                theme: "desk",
                deskContextWord: ctxWord,
                deskContextSentence: ctxSentence,
                deskContextSurrounding: ctxSurrounding
            )
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                self.controller.isLoaded = true
            }
        }

        // Open target="_blank" links (Ejtaal, Qur'an Corpus, Shamela) in macOS default browser
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let targetURL = navigationAction.request.url,
               targetURL.scheme == "http" || targetURL.scheme == "https" {
                NSWorkspace.shared.open(targetURL)
            }
            return nil
        }
    }

    private static let observerJS = """
    (function() {
      if (window.__qamusMacObserver) return;
      window.__qamusMacObserver = true;
      // The Desk sends structured lookups itself; scraping it would only overwrite them with blanks.
      if (document.getElementById('desk')) return;

      function clean(el, limit) {
        if (!el) return '';
        return (el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, limit);
      }

      function collectHansWehr() {
        const sec = document.querySelector('section[data-sec="hw"]');
        if (!sec) return '';
        const parts = [];
        // Prioritize highlighted exact hits first, then ALL derived verb forms (I–X), then remaining entries
        const hits = sec.querySelectorAll('.entry-row.hit, .form-row.hit');
        hits.forEach(el => parts.push(clean(el, 450)));
        const forms = sec.querySelectorAll('.form-row:not(.hit)');
        for (let i = 0; i < Math.min(forms.length, 10); i++) {
          parts.push(clean(forms[i], 260));
        }
        const entries = sec.querySelectorAll('.entry-row:not(.hit)');
        for (let i = 0; i < Math.min(entries.length, 6); i++) {
          parts.push(clean(entries[i], 280));
        }
        return parts.filter(Boolean).join('\\n').slice(0, 3000);
      }

      function emit() {
        try {
          const p = new URLSearchParams(location.hash.slice(1));
          const q = p.get('q') || document.getElementById('q')?.value || '';
          const heroWord = clean(document.querySelector('.rh-word'), 120);
          const translit = clean(document.querySelector('.rh-tr'), 120);
          const roots = [...document.querySelectorAll('.root-chip [lang="ar"]')].map(el => clean(el, 30)).filter(Boolean);
          const particlesText = clean(document.querySelector('section[data-sec="particles"]'), 1600);
          const hansWehrText = collectHansWehr();
          const wiktionaryText = clean(document.querySelector('section[data-sec="wikt"]'), 900);
          const laneText = clean(document.querySelector('section[data-sec="lane"]'), 1600);
          const arNodes = [...document.querySelectorAll('section[data-sec="mufradat"], section[data-sec="mukhtar"]')];
          const arabicDictsText = arNodes.map(n => clean(n, 1000)).filter(Boolean).join('\\n\\n').slice(0, 1800);
          const viewKind = p.has('vocab') ? 'vocab' : p.get('folder') ? 'folder' : p.get('study') ? 'study'
            : p.has('history') ? 'history' : p.has('settings') ? 'settings'
            : (heroWord || q) ? 'result' : 'home';
          const theme = document.documentElement.dataset.theme || 'paper';

          window.webkit?.messageHandlers?.qamusNative?.postMessage({
            query: q,
            heroWord,
            translit,
            roots,
            particlesText,
            hansWehrText,
            wiktionaryText,
            laneText,
            arabicDictsText,
            viewKind,
            theme
          });
        } catch (e) {}
      }

      let timer = 0;
      const schedule = () => { clearTimeout(timer); timer = setTimeout(emit, 180); };
      window.addEventListener('hashchange', schedule);
      const main = document.getElementById('main');
      if (main) {
        new MutationObserver(schedule).observe(main, { childList: true, subtree: true });
      }
      new MutationObserver(schedule).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
      schedule();
    })();
    """
}
