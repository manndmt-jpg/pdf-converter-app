# Eval harness

Measures conversion quality against the PDF text layer the app actually saw.
Run it after every prompt or pipeline change, before releasing.

```bash
python3 eval/score.py <source.pdf> <converted.md> [more.md ...]
```

Offline regression tests (no API calls; covers the page-break clause-loss
scenario from 2026-08-10 and the renderer's front-matter/heading rules):

```bash
swiftc -parse-as-library -o /tmp/pdfconv_tests eval/test_regressions.swift \
    Sources/{PageFurniture,MarkdownRenderer,ClauseAudit,OrphanItemAudit,NumberingScope}.swift && /tmp/pdfconv_tests
```

Headless end-to-end conversion (the exact in-app pipeline, OpenRouter only,
key from `$OPENROUTER_API_KEY` or the app's Keychain item):

```bash
swiftc -parse-as-library -O -o /tmp/convert_cli eval/convert_cli.swift \
    Sources/{Converter,APIResponseParser,DocumentChunker,ClauseAudit,ClauseBinding,MarkdownRenderer,DebugLog,Prompts,Keychain,VertexAuth,AppSettings,PageFurniture,OrphanItemAudit,NumberingScope}.swift
/tmp/convert_cli <file.pdf> <output-dir>
```

The first argument can also be a pre-dumped `.txt` (the format
`eval/dump_text.swift` produces, identical to `Converter.extractPages`).

Reported defect classes, all observed live on real documents:

| metric           | defect it catches                                            |
| ---------------- | ------------------------------------------------------------ |
| missing ids      | silently dropped clauses (predicts the in-app audit warning) |
| invented ids     | fabricated multi-level clause numbers                        |
| bare inventions  | unnumbered paragraphs given "1.", "2." labels                 |
| duplicate labels | the same clause number bound to two paragraphs               |
| order flips      | shifted/renumbered runs (8.6/8.7 fusion class)               |
| content recall   | lost paragraph text, independent of numbering                |

Id extraction and gating are 1:1 ports of `ClauseAudit.swift`; keep them in
sync when the Swift side changes. `dump_text.swift` mirrors
`Converter.extractPages` including the `PageFurniture` header/footer strip;
keep those in sync too.

`eval/corpus/` is the local golden set (PDFs + reference conversions). It is
gitignored: the repo is public and the corpus contains third-party documents.
