# Version 1.12

- New always-on binding verification: for every clause-numbered document the
  app now reads the printed pages as images (one small AI call per page,
  a few cents per document) and checks that every clause number in the result
  carries the paragraph the printed page shows next to it. Where the numbering
  came back shifted or merged, the result is re-cut along the printed anchors.
  In testing this repaired every previously known shifted run, including cases
  where cross-references pointed at the wrong clause.
- The completeness audit now checks the result's actual labels instead of its
  text, so a clause that survives only inside a cross-reference is correctly
  reported as missing.
- Known limitation: very dense small-print pages where consecutive clauses
  start with the same words can still bind imperfectly.
