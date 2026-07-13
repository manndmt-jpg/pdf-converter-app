# PDF to MD AI Converter - Project Notes

## Overview

Native macOS Dock app (SwiftUI, display name "PDF to MD AI Converter", bundle
PDFConverter) that converts PDFs to structured German-legal Markdown via Gemini
2.5 Flash (OpenRouter default, Vertex AI EU optional). GUI successor to
`~/Projects/pdf-parser/parse_contract.py`; prompts and markdown rendering are
ported 1:1 from there. Public repo: github.com/manndmt-jpg/pdf-converter-app.

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
- Token cap: `max_tokens`/`maxOutputTokens` = 65536 (both backends). The text-layer
  path asks for the WHOLE document back as structured JSON, so output size ~= document
  size (measured: 17-page AHB = ~36K output tokens). Docs > ~160K chars are chunked
  (DocumentChunker) and merged; a cut-off/unparseable/short answer triggers a re-ask,
  then an automatic split-in-halves retry, then `.responseTruncated`.
- OpenRouter can embed provider failures inside a 200-OK response (choices[0].error,
  e.g. Google 429 injected mid-stream). APIResponseParser detects these; transient ones
  retry with rate-limit-aware backoff (15s*attempt). NEVER judge success by HTTP status.
- Vertex: `thinkingBudget: 0` is REQUIRED. With default dynamic thinking the model
  summarizes a 126K-char answer into a 20K skeleton despite the do-not-summarize prompt.
- OpenRouter text-path falls back to `mistralai/mistral-large-2512` when Gemini
  exhausts retries on 429/5xx/empty. Mistral is slow on big docs (13 min for 17 pages,
  measured), hence request timeoutInterval 1500s. Vision/OCR stays Gemini-only.
- Failed/unusable model answers are dumped to `~/Library/Logs/PDFConverter/`.

## UI (v1.3+ redesign)

- Two-pane layout from claude.ai/design project 7d5e8c9c (folder
  design_handoff_two_pane_redesign: README spec + .dc.html mocks). When adjusting
  design, read the .dc.html mocks, not only the README.
- `DesignTokens.swift` holds the palette (dynamic NSColor light/dark providers).
- Appearance override (Settings): UserDefaults `appearanceOverride`
  (system|light|dark) applied via `NSApp.appearance`; applied at launch in
  AppDelegate and on change in SettingsView.
- Preview (SuccessView) has a non-scrolling toolbar strip: a Formatted/Markdown
  segmented toggle (left) + Copy (right), above a hairline; the document scrolls
  below it as one `.textSelection(.enabled)` AttributedString Text. Mode persists
  in UserDefaults `previewMode` (default formatted). renderFormatted does
  proportional headings (# ... ######)/lists/inline-bold and falls back to
  monospace for table rows and fenced code so columns align; renderRaw is the
  monospace source view. Both renderings are cached per document.
- Preview render is CAPPED to the first 600 lines / 60KB (SuccessView.capForPreview)
  with a truncation notice, because one huge selectable AttributedString Text hangs
  the main thread. Copy and Open Markdown always use the full file.
- History rows (sidebar) have a per-row ✕ remove on hover -> ConversionQueue
  .removeHistory(id); selection clears if the removed row was open.
- Hidden title bar; root HStack ignores top safe area; sidebar 264pt with 52pt
  traffic-light spacer.

## Gotchas

- NEVER rename bundle id `com.dimitrimann.pdfconverter`, the `PDFConverter.app`
  filename, or the repo: Sparkle feed, Keychain item, and shared links depend on
  them. Only CFBundleDisplayName/CFBundleName carry the product name.
- Do NOT ship a standalone release for a one-line change; fold into the next one
  (user preference).

- Code fixes do NOT retroactively rewrite already-saved `.md` files. A doc that
  converted badly stays bad on disk until the user RE-DROPS the PDF (save() only runs
  on a successful conversion and overwrites by output filename).
- Scanned-page OCR goes through Gemini Vision (parity with the CLI), NOT Apple Vision
- PDF only; the CLI's .docx support was not ported
- Relaunch the app after code changes (rebuild does not hot-reload)
