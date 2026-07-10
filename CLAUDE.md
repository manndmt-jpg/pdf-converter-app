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

## Release a new version

```bash
./scripts/release.sh 1.2      # notarize + EdDSA-sign + appcast + scp to VPS + gh release
```

Sparkle auto-updates: feed at https://d-mann.dev/pdfconverter/appcast.xml (VPS Caddy
serves /home/dev/Projects/pdfconverter-releases/). EdDSA key shared with Meeting
Scribe (Keychain + ~/.sparkle_eddsa_key backup). RELEASE_NOTES.md becomes the
Sparkle "What's New" text. Never codesign Sparkle.framework with --deep; the
release script signs each nested binary individually.

## Architecture (Sources/)

- `PDFConverterApp.swift` - @main, AppDelegate (Dock/Finder open, quit guard, env key import)
- `ConversionQueue.swift` - @MainActor singleton, sequential queue, statuses, history, notifications
- `Converter.swift` - engine: PDFKit text extraction; text layer -> one structured JSON call;
  no text layer -> per-page Gemini Vision OCR (300 dpi PNG). Retries 5xx/429/network 3x.
- `Prompts.swift` - system prompts, verbatim from parse_contract.py
- `MarkdownRenderer.swift` - JSON -> markdown, port of result_to_markdown()
- `AppSettings.swift` / `SettingsView.swift` - backend picker (OpenRouter | Vertex AI EU),
  model, prompt, output folder (UserDefaults)
- `Keychain.swift` - OpenRouter key storage
- `VertexAuth.swift` - authorized_user JSON parsing + OAuth2 token refresh (cached actor),
  ported from Meeting Scribe's GeminiService. Vertex config (project, region, credentials
  JSON) lives in UserDefaults like Meeting Scribe. Only gemini-2.5-flash in europe-west1.

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
