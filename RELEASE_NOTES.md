# Version 1.14

- Fixed: after pasting Vertex credentials, the Test Connection button could stay
  greyed out until you pressed Tab or clicked another field. It is now always
  clickable and tells you directly if a field is still empty.
- The credentials field label now mentions that a service account key file is
  accepted too.
- Fixed: a list item continuing after a page break could be silently dropped or
  attached to the wrong clause. Repeating page headers/footers are now removed
  from what the AI reads, and every printed list item is verified against the
  PDF and restored in place if the AI lost, merged, or misfiled it.
- Fixed: front matter is reproduced as printed. No more invented headings or
  file-reference lines built from page footers, and the insurer block can no
  longer lose paragraphs (it is restored from the PDF if the AI drops it).
- Improved: consistent numbered headings across conversions, printed
  enumerators like (i)/(ii) are preserved, duplicated enumeration text is
  removed, and the table of contents is no longer copied into the output.
- The document date now appears as "Stand: ..." exactly as printed.
