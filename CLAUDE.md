# PDF Converter - Project Notes

## Overview

Native macOS Dock app (SwiftUI) that converts PDFs to structured German-legal
Markdown via Gemini 2.5 Flash on OpenRouter. GUI successor to
`~/Projects/pdf-parser/parse_contract.py`; prompts and markdown rendering are
ported 1:1 from there.

## Build & run

```bash
./scripts/build-app.sh        # swift build -c release + assemble PDFConverter.app (ad-hoc signed)
open PDFConverter.app
```

Debug compile only: `swift build`

## Architecture (Sources/)

- `PDFConverterApp.swift` - @main, AppDelegate (Dock/Finder open, quit guard, env key import)
- `ConversionQueue.swift` - @MainActor singleton, sequential queue, statuses, history, notifications
- `Converter.swift` - engine: PDFKit text extraction; text layer -> one structured JSON call;
  no text layer -> per-page Gemini Vision OCR (300 dpi PNG). Retries 5xx/429/network 3x.
- `Prompts.swift` - system prompts, verbatim from parse_contract.py
- `MarkdownRenderer.swift` - JSON -> markdown, port of result_to_markdown()
- `AppSettings.swift` / `SettingsView.swift` - model, prompt, output folder (UserDefaults)
- `Keychain.swift` - OpenRouter key storage

## Config

- API key: Keychain item `com.dimitrimann.pdfconverter`. On first launch the app
  imports `OPENROUTER_API_KEY` from env if the Keychain is empty (works when the
  binary is started from a terminal).
- Output: `~/Documents/PDF-Converted/` (changeable in Settings)
- Models: gemini-2.5-flash default, gemini-2.5-pro selectable
- Cost guard: scanned PDFs > 100 pages need inline Convert/Skip confirmation

## Gotchas

- Scanned-page OCR goes through Gemini Vision (parity with the CLI), NOT Apple Vision
- PDF only; the CLI's .docx support was not ported
- Relaunch the app after code changes (rebuild does not hot-reload)
