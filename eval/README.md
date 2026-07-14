# Eval harness

Measures conversion quality against the PDF text layer the app actually saw.
Run it after every prompt or pipeline change, before releasing.

```bash
python3 eval/score.py <source.pdf> <converted.md> [more.md ...]
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
sync when the Swift side changes.

`eval/corpus/` is the local golden set (PDFs + reference conversions). It is
gitignored: the repo is public and the corpus contains third-party documents.
