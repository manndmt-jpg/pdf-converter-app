# Version 1.11

- The converter no longer invents numbering: models used to give unnumbered
  paragraphs their own numbers ("1.", "2." under a clause that prints plain
  text). The prompt now forbids it, and a new reverse audit catches any case
  that still slips through and says so in the warning.
- Warnings now include PDF page numbers ("clause 1.5, PDF page 15"), so a
  flagged clause can actually be found in documents whose sections restart
  their numbering.
- The automatic page-image fix handles two more hard cases: pages showing two
  differently-numbered sections at once, and transcriptions that repeat the
  clause number inside the text.
