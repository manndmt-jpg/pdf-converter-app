# Version 1.9

- New completeness check: after every conversion the app verifies that all clause
  numbers found in the PDF also appear in the result. If some are missing, it asks
  the AI again automatically; anything still missing is shown as a warning on the
  result instead of being silently dropped.
- Better clause numbering on two-column documents: the AI is now told how these
  PDFs scramble clause numbers and to use the document's own table of contents to
  keep numbering exact.
- The document preamble and table of contents are now part of the converted output.
