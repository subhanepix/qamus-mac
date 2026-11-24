# Qamus for macOS (Native Apple Silicon App)

A standalone native macOS app (`Qamus.app`) that bundles your existing Qamus dictionary untouched inside a fast SwiftUI + `WKWebView` shell and layers three native Apple Silicon features on top:

1. **Structured Context & Grammar Analyzer (Local Ollama/MLX + `FoundationModels`)**: Grounded in Qamus's retrieved entries (Hans Wehr + Verb Forms I–X, Particles, Wiktionary, Lane, al-Mufradāt, Mukhtār). Uses strict JSON-schema decoding to output zero-fluff structured cards showing vocalized form & morphology (`صرف`), contextual meaning, particles/prepositions acting on the word (`العوامل`), syntactic role & arguments (`الإعراب` — e.g. `فاعل`, `نائب فاعل`, `مفعول به`), and full clause translation.
2. **Persistent Scanned Page Dock + Hybrid Arabic OCR**: Press `⌘⇧V` to paste & scan a PDF screenshot (or `⌘⇧O` to toggle the dock). Uses **Hybrid OCR** (2× Lanczos-upscaled Apple Vision + multimodal AI proofreading), stays docked above Qamus while you click through multiple words line-by-line in natural RTL order, and passes a **3-line surrounding window** automatically so wrapped sentences stay intact.
3. **Quick Entry Tools & Follow-ups**: One-click TL;DR summaries, classical Arabic dictionary unpacking, flashcard drafts, and contextual Q&A.

## Interface: Reading Desk (default) or Classic Dictionary

**View → Interface** switches between the two. The choice is remembered.

- **Reading Desk** (`redesign/`, shipped only inside the app, never in `dist/` or the website): paste
  text or scan a page and it opens as a text in the reader. Click any word, use ← / → to step through
  words, and press S to save it with its sentence. **Explain** in the web inspector runs the
  on-device analyzer and shows the grammar card right there. The Desk sends structured lookups
  (`window.qamus`) instead of being scraped from the page. ⌘N makes a new text, and ⌘I still opens
  the native panel for AI engine settings.
- **Classic Dictionary**: the website UI with the native Context & Grammar panel, as before.

## Building & Running

```bash
sh macos/build-app.sh
open macos/build/Qamus.app
```

To install permanently in Applications:
```bash
cp -R macos/build/Qamus.app /Applications/
```

## Shortcuts
- `⌘K` — Look up (the Desk's palette, or the classic search bar)
- `⌘N` — New text (Reading Desk)
- `⌘I` — Toggle On-Device AI Scholar panel
- `⌘⇧V` — Paste a PDF screenshot to scan it (or, on the Desk, copied Arabic text to read it)
- `⌘⇧O` — Show/hide the persistent Scanned Page dock
- `⌘R` — Reload dictionary view

## Sync & Data
The bundled web app is served locally on `http://127.0.0.1:41932/` (with the website files untouched), so IndexedDB persists across launches and your existing Cloudflare Worker sync works automatically out of the box.
