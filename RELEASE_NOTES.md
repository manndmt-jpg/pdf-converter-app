# Version 1.15

- Fixed: when a document embeds a block that restarts its clause numbering
  under its own printed heading (for example insurer conditions ending with a
  "Stichentscheid" section), the converted file no longer shows the same
  clause numbers twice under one heading. The block now gets its own heading,
  exactly as printed in the PDF.
- Fixed: on PDFs whose text layer stores accented letters in a decomposed
  form, an automatic repair could cut text a few characters off the intended
  spot. Positions are now computed correctly for any text encoding.
