# Version 1.10

- The completeness check can now FIX what it finds instead of only warning: when
  clause numbers are missing or shifted (a known weakness of two-column PDFs),
  the app re-reads the affected pages as images, where the numbering is
  unambiguous, and splices the corrected clauses into the result. Costs less
  than a cent and only runs when needed.
- The warning still appears if the automatic fix does not fully succeed.
