# Qamus for macOS

A native macOS Arabic Reading Desk paired with 100% on-device Arabic grammar analysis, hybrid visual OCR for scanned PDFs/books, Buckwalter + CAMeL Tools morphological cross-checking, and two-way flashcard sync with [alqamus.pages.dev](https://alqamus.pages.dev).

## Download & Install (macOS 26+, Apple Silicon)

1. **[Download Qamus-macOS.zip (Latest Release)](https://github.com/subhanepix/qamus-mac/releases/latest/download/Qamus-macOS.zip)** and unzip it.
2. **Right-click `Install Qamus.command` → Open → Open** (required once for macOS Gatekeeper), then press **Enter**.

The installer automatically:
- Installs `Qamus.app` into `/Applications` and clears quarantine (`xattr -cr`)
- Installs/starts **Ollama** and pulls the optimal local Arabic models for your Mac’s RAM:
  - **24 GB+ RAM:** `qwen3:30b-a3b-instruct-2507-q4_K_M` (~18 GB) + `gemma3:12b` (~8.2 GB)
  - **16–23 GB RAM:** `gemma3:12b` (~8.2 GB, handles both grammar & Hybrid Visual OCR)
  - **8–15 GB RAM:** `qwen3:4b` (~2.6 GB) + instant Apple Vision OCR
- Sets up the **NYU Abu Dhabi CAMeL Tools** BERT Arabic parser (`morphology-db-msa-r13` + `disambig-bert-unfactored-msa`) in an isolated Python 3.12 environment at `~/Library/Application Support/Qamus/camel_sidecar` via `uv` (no Homebrew or Xcode required)
- Pre-configures Qamus and launches it

> **Lite / Zero-Download Option:** If you only want the dictionary, Reading Desk, Apple Vision OCR, and Apple On-Device Intelligence (`FoundationModels`) with zero model downloads, drag `Qamus.app` into `/Applications`, run `xattr -cr /Applications/Qamus.app`, and switch the titlebar settings (`⚙`) to **Apple On-Device** + **Apple Vision**.

## Features

- **Reading Desk (`redesign/`):** Paste Arabic passages or scan screenshots straight from PDFs (`⌘⇧V`), click any word or step through with `← / →` for instant dictionary lookup + Grammar-in-Context (*ḥāshiyah*) under the reader.
- **On-Device Grammar & Morphology Stack:** Local Ollama / Apple Intelligence grounded in Hans Wehr, Particles, Wiktionary, deterministic Buckwalter parsing (`morph.json`), and CAMeL Tools BERT context diacritization + agreement badges.
- **Instant Step Cache:** Revisiting any analyzed word on a page switches in `0 ms` (click **Re-run** to force a fresh parse).
- **Hybrid Visual OCR:** Combines 2× Lanczos-upscaled Apple Vision with `gemma3:12b` visual proofreading for crisp Classical Arabic & Quranic bracket/harakat accuracy.
- **1-Click Contextual Vocabulary & Phone Sync:** Press `S` (or click **Save**) to save the word with its exact contextual meaning and highlighted sentence, synced live to your phone via [alqamus.pages.dev](https://alqamus.pages.dev).

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌘⇧V` | Paste Arabic text or a PDF screenshot (runs OCR straight into the reader) |
| `←` / `→` | Step word-by-word through a passage |
| `S` | 1-click save word + contextual meaning + highlighted sentence |
| `⌘K` | Quick dictionary & command search |
| `⌘N` | New text |
| `⌘I` | Toggle optional native SwiftUI side panel (entry TL;DR, classical Arabic dicts, Q&A) |

## Building from Source

`Qamus.app` bundles the web dictionary engine and lexicon shards (`engine.js`, `merge.js`, `sync.js`, `data/`) from [subhanepix/qamus](https://github.com/subhanepix/qamus). Place `macos/` and `redesign/` inside a checkout of `subhanepix/qamus` and run:

```sh
sh macos/build-app.sh          # Local dev build -> macos/build/Qamus.app
sh macos/package-release.sh    # Portable zip    -> macos/build/Qamus-macOS.zip
```
