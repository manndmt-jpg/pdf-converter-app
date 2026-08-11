# PDF to MD AI Converter - Project Notes

## Overview

Native macOS Dock app (SwiftUI, display name "PDF to MD AI Converter", bundle
PDFConverter) that converts PDFs to structured German-legal Markdown via Gemini
2.5 Flash (OpenRouter default, Vertex AI EU optional). GUI successor to
`~/Projects/pdf-parser/parse_contract.py`; prompts and rendering started as 1:1
ports but have since diverged (quality pipeline: audits, binding pass, eval).
Public repo: github.com/manndmt-jpg/pdf-converter-app.

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
- `Converter.swift` - engine: PDFKit text extraction; text layer -> structured JSON call(s)
  (chunked when large, split-in-halves fallback, completeness guard, Mistral fallback);
  no text layer -> per-page Gemini Vision OCR (300 dpi PNG). Retries HTTP + embedded
  5xx/429/network, 5 attempts on structured calls, rate-limit-aware backoff.
- `APIResponseParser.swift` - Foundation-only: interprets 200-OK bodies (embedded provider
  errors, truncation, transient flag) + parseJSON with control-char repair. Kept
  standalone-compilable so scratch harnesses can test it against real captured responses.
- `DocumentChunker.swift` - Foundation-only: page-group chunking (>160K chars) + merge
  with section folding. Same standalone-compilable rule.
- `ClauseAudit.swift` - Foundation-only: two-sided clause-number audit. Forward:
  multi-level ids (6.15.2.4) in the source text missing from the rendered answer
  (silently dropped clauses); a sibling gate (id needs a numeric neighbor) suppresses
  date/phone artifacts. Reverse: answer ids the source never prints (inventedIds,
  tolerant of line-break-split source numbers) and bareNumberedSections (paragraphs
  numbered "1."/"2." under a multi-level section where the PDF prints no number —
  models do this document-wide; observed 63 fabricated labels in one AHB answer).
  Printed inline enumerations are exempted by an adjacency check: real enumeration
  numbers sit directly before their text in the text layer, only clause ids live in
  the decoupled number column; the check needs 24 chars of content anchor because
  12 let a cross-reference ("Ziffer 1. ausgeschlossen") vouch for unrelated
  paragraphs. Same standalone-compilable rule.
- `ClauseBinding.swift` - Foundation-only: the vision-anchor binding pass. Per printed
  page one small vision call extracts (clause number, first words) anchors — the one
  extraction the vision model binds correctly (live-verified; full transcriptions of
  the same pages kept misbinding). ClauseBinding.rebind re-CUTS the answer's own text
  along located anchors (labels move, text never lost), per numbering block, with
  all-or-nothing guards; when a model returns a whole document part as one giant
  section, the block degrades to per-family segments so one unmatched anchor cannot
  veto every repair. Same standalone-compilable rule.
- `NumberingScope.swift` - Foundation-only: splits flattened numbering scopes.
  Embedded blocks restart clause numbering at 1 under a printed keyword heading
  (AHB live: the ROLAND conditions under Abschnitt 3 clause 8 print
  "Stichentscheid" then clauses 1., 1.1.-1.3., 2., 3.); the model reproduces
  every printed label but flattens both scopes into ONE section (labels collide:
  3 duplicate labels + 1 order flip in the eval) and absorbs the heading into
  the preceding paragraph's tail. The split triggers only on a numeric label
  run restarting at EXACTLY "1." (non-increase landing anywhere else = model
  error, never split), strictly ascending to the next restart, whose first
  paragraph is fingerprint-locatable in the text layer with a heading-like
  line directly above it (starts uppercase; no terminal punctuation; no
  comma/semicolon ANYWHERE — a wrap line "Rechtsvorschriften, soweit..." is
  otherwise indistinguishable from a heading; not a clause number/enumerator;
  number-column lines are skipped) AND whose predecessor line ends a real
  sentence (terminal punctuation, checked across the page break, and a "." only
  counts after a word of >= 3 letters — an abbreviation period "u. a." ends no
  sentence; German capitalizes every noun, so uppercase alone proves nothing
  and invented numbering under prose would split without these rules). EVERY
  fingerprint occurrence — across pages AND repeats within one page — must
  agree on the same heading. The new section is titled with the document's own
  verbatim heading line; the absorbed tail copy is stripped only on a
  whitespace-bounded verbatim suffix match. Cut indices are counted in UNICODE
  SCALARS, not Characters (combining marks are alphanumerics: NFD page text
  otherwise shifts every cut early — reproduced; same fix applied to
  OrphanItemAudit.originalIndex, which had the identical copy-pasted bug).
  Runs twice in Converter: early (clean-but-flattened answers) and again after
  the binding pass (a misbound answer — pre-v1.12 vertex AHB AND the first
  live post-v1.14 run observed — only reveals its scopes once rebind has
  re-cut it; the split is pure and idempotent). Both sites capture
  ClauseAudit.bareNumberedSections BEFORE splitting and union it into the
  final warning: relocating a fabricated-numbering run under a non-numeric
  section id would otherwise silence the warning. Same standalone-compilable
  rule. Mutation-tested: each guard has a killing fixture in
  eval/test_regressions.swift.
- `PageFurniture.swift` - Foundation-only: strips repeating page headers/footers from
  the text layer before the model sees it. PDFKit interleaves footers MID-SENTENCE at
  every page break; observed live (Tarif L/M insurance conditions, 2026-08-10): the
  footer sat between items "b." and "c." of Ziffer 1.2 and the model dropped "c." (L)
  or misfiled it under 1.3 (M); the same footer got promoted into a fabricated
  front-matter "Aktenzeichen" line. Repetition threshold: >= half the pages, min 3;
  digit runs normalized so page counters ("8 / 67") match across pages; lines with
  < 4 letters never stripped (two-column number columns "2.7. 2.8." and enumerators
  "(i)" repeat across pages and must survive); the FIRST occurrence of each footer
  line is kept (footers are the only place these docs print their date, "Stand Juni
  2026"). Same standalone-compilable rule.
- `OrphanItemAudit.swift` - Foundation-only: the enumeration-item BACKSTOP. Even
  with the footer stripped and prompt rules in place, the model nondeterministically
  drops or label-less-merges printed enumeration items — most often the item whose
  text starts a PDF page (three consecutive live runs of one doc: dropped / fused
  into "b." / "## c." own-section), but also whole MID-PAGE runs ((ii)-(v) of 2.4
  vanished in a run that scored 100% on the numeric audit). This audit lists EVERY
  line-start item ("c. …", "(ii) …") straight from the text layer (line-start
  enumerators with >= 8 same-line chars are the RELIABLE adjacency case; bare label
  lines are the two-column number column and are ignored), then verifies each
  against the parsed answer: present+labeled anywhere (own subsection or inline)
  -> untouched; fused label-less -> split out and labeled; absent -> re-inserted
  verbatim after the preceding item (dropped runs chain: each inserted item anchors
  the next); unplaceable -> user-facing warning. Insertion never targets a section
  already carrying the item's id (sibling sections share word-identical items —
  1.1 b. == 1.2 b. live) and prefers the anchor whose id matches the source's
  preceding token. Fingerprints are opening-word prefixes and German boilerplate
  reuses openings (front matter "Alle für den Versicherer…" == clause 10.8 a. for
  32 chars, live): an item counts as present if ANY hit carries its label, and the
  verbatim front-matter block is never relabeled. Repairs only re-cut or re-insert
  the document's own printed text. Two more live-observed shapes it fixes: a
  LABELED item misfiled as the first subsection of the FOLLOWING section (ahead
  of that section's own "a.") is moved back after its anchor — that exact
  signature only; and recoverLeadingFrontMatter restores a dropped
  Versicherer/Alteos front-matter block (2 of 3 consecutive runs lost it):
  the prose run directly above the body start on the body-start page, restored
  verbatim into the leading front-matter section only when missing (TOC lines
  self-exclude via their digit-only page-number lines). Same
  standalone-compilable rule (needs ClauseAudit).
- `DebugLog.swift` - dumps unusable model answers to ~/Library/Logs/PDFConverter/
- `Prompts.swift` - system prompts. Originally ported from parse_contract.py, but no
  longer verbatim: v1.9+ added two-column rebinding, front-matter, and
  never-number-unnumbered-paragraphs rules to structuredSystem, plus clauseRunSystem
  (focused run re-extraction) and pageAnchorSystem/pageAnchorAsk (binding pass).
  v1.14 (2026-08-10): page-furniture rule, page-break continuation rule (a NEW
  enumerator after a page marker is a NEW item, not a continuation of the previous
  one — the first wording caused "c." to be merged into "b."), verbatim front matter
  (running-text front matter as a leading section with id ""/title "", never
  restructured into "parties" — restructuring is what dropped the "Alle für den
  Versicherer..." paragraph and invented a ROLAND front-matter entry), clause
  granularity (each numbered clause = own section, lettered items = subsections),
  keep-inline-enumerators ((i)/(ii)), and the TOC is now EXCLUDED from the output.
  The TOC exclusion supersedes the v1.9 include-TOC rule: the model reads the TOC as
  input for the numbering map either way, but TOC ids in the ANSWER's labels would
  blind ClauseAudit.missingIds (the audit reads labels), and old runs omitted the
  TOC anyway.
- `MarkdownRenderer.swift` - JSON -> markdown, port of result_to_markdown(); v1.9.1
  added dedup (models return the same text as id AND title/content start) and
  trailing-dot normalization on subsection ids. v1.14: same trailing-dot
  normalization on SECTION headings ("## 1." vs "## 1" varied per run, also when the
  number arrives inside the title); a section with empty id AND empty title is the
  verbatim front-matter block and renders WITHOUT a heading (no more invented
  "## Beteiligte" — that heading came from the renderer whenever parties was
  non-empty), with a printed "Versicherer:"-style label prefix bolded; the date
  field renders as "**Stand:**" (was "Datum" — these documents print "Stand";
  one-word revert in the field/label list if notarial docs ever matter again).
  Also structure normalizers used by Converter pre-render:
  demoteStrayLetterSections (a "## c." section following a letter enumeration is
  the page-break orphan promoted to a heading — folded back in) and
  dropDuplicatedEnumerationSubs (model emitted an enumeration BOTH as label-less
  prose in the parent item AND as "(i)"/"(ii)" subsections, live on 2.7 a. —
  the labeled duplicates are dropped and OrphanItemAudit re-splits the prose)
- `AppSettings.swift` / `SettingsView.swift` - backend picker (OpenRouter | Vertex AI EU),
  model, prompt, output folder (UserDefaults)
- `Keychain.swift` - OpenRouter key storage
- `VertexAuth.swift` - Vertex credentials + OAuth2 token minting (cached actor), originally
  ported from Meeting Scribe's GeminiService. `VertexCredentials` is an enum over the TWO
  shapes the same Settings field accepts, dispatched on which fields are present (not on
  `type`, which old gcloud ADC files omit):
  `authorizedUser` (client_id/client_secret/refresh_token, from `gcloud auth
  application-default login`) uses a refresh_token grant; `serviceAccount`
  (client_email/private_key, from a downloaded SA key) signs an RS256 JWT and uses the
  jwt-bearer grant. JWT signing is Security.framework only (no deps): PEM -> strip PKCS#8
  wrapper via a minimal DER walk -> SecKeyCreateWithData -> SecKeyCreateSignature. The SA
  path (v1.13) exists so a colleague can be set up with one pasted file and no terminal.
  Vertex config (project, region, credentials JSON) lives in UserDefaults like Meeting
  Scribe. Only gemini-2.5-flash in europe-west1.

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
- Gemini intermittently emits RAW newlines/tabs inside JSON string values; strict
  parsers reject the whole (otherwise complete, correct) answer over one character.
  APIResponseParser.parseJSON repairs control chars inside string literals before
  parsing; the outermost-braces fallback slices BEFORE repairing (an odd quote in
  surrounding prose would corrupt structural whitespace otherwise).
- Models occasionally drop or MISBIND a small run of clauses in an otherwise complete
  answer (observed live: 6.15.2.4-6.15.2.6 gone; 8.6/8.7 fused+shifted) — too small for
  the <40% completeness guard. ClauseAudit compares clause numbers source-vs-answer
  after rendering. On a gap: focused VISION re-extraction of only the affected numbered
  run from 200dpi page images (Prompts.clauseRunSystem; text-only re-asks and even
  full-doc re-asks WITH images kept misbinding — live-tested), then ClauseAudit.splice
  replaces the misbound window (found by content fingerprints, TOC sections skipped,
  only the matched sub-range replaced so a page-capped run never deletes clauses the
  images did not show). Adoption per run: strictly fewer missing ids + length guard.
  Remaining gaps surface as a warning banner (QueueItem.warning / HistoryEntry.warning)
  instead of failing the run.
- The AHB-style two-column PDFs have a separate number sub-column; PDFKit's text layer
  decouples clause numbers from their paragraphs (runs like "2.7. 2.8. 2.9." away from
  the text). structuredSystem now instructs the model to rebind numbers via the
  document's own TOC/cross-references and to include front matter + TOC in the output.
- Models also NUMBER UNNUMBERED PARAGRAPHS ("1.", "2." under 6.8 where the print has
  plain paragraphs) — structuredSystem forbids it (unnumbered paragraphs: append to the
  preceding subsection or id ""; the renderer prints empty-id content without a label;
  live-verified on a pages-4-6 slice: 0 inventions, 27 empty ids, real 6.7.1/6.7.2 kept).
  Remaining cases surface in the warning banner (bareNumberedSections + inventedIds),
  with PDF page numbers on missing/invented ids (Abschnitte restart numbering, so a
  bare "1.5" is unfindable without its page).
- Warnings and audit fallbacks are warn-only: never mutate content on suspicion.
  All audit dead-ends dump to ~/Library/Logs/PDFConverter/ (audit-images-empty,
  audit-splice-nil included — both paths used to exit silently).
- THE BINDING LESSON (v1.12): an answer can carry every clause id exactly once and
  still bind whole runs to the WRONG paragraphs (lead-in absorbed as the next clause,
  runs shifted, clauses merged at the end so the count fits — 8 cross-references
  pointed at the wrong clause in an answer that scored 100% id coverage). No id-set
  audit can see this; only the printed page can. Hence the ALWAYS-ON binding pass
  (ClauseBinding + Prompts.pageAnchorSystem, ~$0.02-0.04 and ~30-60s per doc, pages
  with clause ids only, TOC pages skipped, 4 calls in flight).
- The audits compare source ids against the answer's LABELS (Converter.labelText),
  not its rendered text: cross-references ("siehe Ziffer 2.10") kept structurally
  missing clauses invisible to a text scan. The raw-_markdown fallback path still
  text-scans (no structure to read labels from).
- Model sectioning is NONDETERMINISTIC: the same document has come back both as
  per-clause sections ("## 6.7 ...") and as one giant "## Teil A" section. Nothing
  may assume a particular section granularity.
- `eval/` is the offline quality harness: `python3 eval/score.py <pdf> <md>` scores
  missing/invented/bare ids, duplicates, order flips, content recall. Run it after
  every prompt or pipeline change. Id extraction is a 1:1 port of ClauseAudit —
  keep them in sync. `eval/corpus/` (golden PDFs) is gitignored: public repo, no
  third-party documents. `eval/test_regressions.swift` is the no-API regression
  suite (page-break clause loss + renderer rules; compile command in eval/README).
  `eval/convert_cli.swift` runs the full in-app pipeline headless (OpenRouter key
  from env or Keychain). `eval/dump_text.swift` mirrors Converter.extractPages
  INCLUDING the PageFurniture strip — keep all three in sync with Sources/.

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
- TWO app copies exist: /Applications (notarized release, what the Dock launches) and
  the project-dir dev bundle (what build-app.sh produces). When testing fixes, open the
  PROJECT-DIR bundle explicitly and verify with `ps` which one is running; two user
  test rounds were wasted on the stale /Applications copy.
