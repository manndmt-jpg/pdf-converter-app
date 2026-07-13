# Version 1.8.1

- Fixed conversions failing even though the AI had returned a complete, correct
  answer: stray invisible characters in the answer are now repaired instead of
  rejecting the whole document. This was the main remaining cause of
  "conversion failed" on dense documents.
