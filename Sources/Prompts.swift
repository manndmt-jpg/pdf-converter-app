import Foundation

// Originally ported verbatim from ~/Projects/pdf-parser/parse_contract.py.
// v1.9 added the two-column-numbering and front-matter rules to structuredSystem
// (the CLI does not have them).
enum Prompts {
    static let structuredSystem = """
    You are a German legal document analyst. Your job is to produce a structured summary that mirrors the EXACT section structure of the original document.

    Return valid JSON with this format:
    {
      "title": "document title",
      "reference": "file reference / Aktenzeichen, ONLY if the document prints one; otherwise \"\"",
      "date": "document date as printed (a 'Stand' month/year, or the date of notarization)",
      "notary": "notary name and location",
      "parties": [{"name": "", "role": "", "details": "address, registration, etc."}],
      "sections": [
        {
          "id": "§ 1",
          "title": "section title from the document",
          "subsections": [
            {
              "id": "1",
              "content": "full content of this subsection in the ORIGINAL LANGUAGE (German). Translate nothing. Preserve all details, amounts, dates, percentages, and legal references."
            }
          ]
        }
      ],
      "annotations": ["list of any reviewer/editor comments found in the document, e.g. 'Kommentiert [EK1]: ...'"],
      "signatures": [{"name": "", "role": ""}]
    }

    CRITICAL RULES:
    - Preserve the EXACT section numbering from the document (§1, §2, etc. and their subsections 1., 2., 3., etc.)
    - The text often comes from a two-column PDF whose text layer separates clause numbers from their paragraphs: you may see runs of bare clause numbers (e.g. "2.7. 2.8. 2.9. 2.10.") dumped together, away from the texts they belong to. Rebind every clause number to its correct paragraph. Use the document's own table of contents (Inhaltsverzeichnis) and its internal cross-references (e.g. "Ziffer 6.25") as the authoritative numbering map. Never invent or shift numbering; every clause number that appears in the document must appear exactly once as a section/subsection id.
    - Use a number as a subsection id ONLY if the document prints that exact number. Many paragraphs have NO printed number (e.g. explanatory paragraphs under a numbered clause): append such a paragraph to the content of the preceding numbered subsection, or use an empty id "" if no numbered subsection precedes it in the section. NEVER generate sequence numbers (1., 2., 3.) for unnumbered paragraphs.
    - Include ALL front matter as sections before the body sections — cover notes (e.g. "Hinweise zum Aufbau und zur Anwendung") and running text — EXCEPT the table of contents: use the Inhaltsverzeichnis only as the numbering map; do NOT reproduce the table of contents itself in the output.
    - Front matter that is running text (e.g. the Versicherer/insurer block of insurance conditions) must be reproduced VERBATIM and COMPLETELY as a leading section with id "" and title "": one subsection per paragraph, each with id "". Do NOT restructure such prose into the "parties" list, do NOT invent headings for it, and do NOT drop any of its paragraphs. Use "parties" only when the document itself presents a formal list of parties (e.g. a notarial deed); otherwise leave "parties" empty.
    - Repeating page headers/footers (the same short lines recurring on many pages, e.g. "Stand", a month/year, a product name, page counters like "12 / 67") are page furniture, NOT content: never copy them into "reference", "sections", or "parties". A printed "Stand <Monat Jahr>" may fill the "date" field.
    - When the document numbers its clauses hierarchically (1.1, 2.7, 6.15.2), each numbered clause with a printed heading becomes its own section (id = the printed number, title = the printed heading), and printed lettered items inside a clause (a., b., c.) become that section's subsections with the letter as id (e.g. "a"). Do NOT fold several numbered clauses into one section's content. Deeper printed enumerators ((i), (ii), aa.) may be their own subsections (id exactly as printed, e.g. "(i)") when the document prints them as separate list items, or stay verbatim inside their item's content — they must NEVER be lost.
    - Preserve the document's paragraph breaks INSIDE a subsection's content as \\n line breaks. Do not join separately printed paragraphs into one continuous line.
    - The text contains page markers ("--- Seite N von M ---"). Text cut by a page break CONTINUES after the marker. Label-less text directly after a marker continues the item that was open before the break. A line that starts with a NEW enumerator or clause number (e.g. "c." after "b.", or "1.3" after "1.2") is a NEW item of the enumeration that was open before the break: keep it with its own label in its proper place. Never drop such an item, never merge it into the previous item, and never attach it to the following heading.
    - Preserve printed inline enumerators — (i), (ii), a., b., 1., 2. — verbatim inside content. Never flatten an enumerated list into prose and never renumber it.
    - Keep ALL text in the ORIGINAL LANGUAGE (German). Do NOT translate.
    - Do NOT summarize. Include the FULL content of every subsection.
    - If a subsection is long, include it in full — do not truncate.
    - Separately extract any "Kommentiert [...]" annotations — these are reviewer comments, not part of the contract.
    - Return ONLY valid JSON, no markdown fences.
    """

    static let visionSystem = """
    Du bist ein Experte für die Extraktion von Dokumenteninhalten. Du erhältst gescannte Seiten eines deutschen Dokuments.

    Deine Aufgabe:
    - Transkribiere den vollständigen Inhalt jeder Seite getreu in Markdown.
    - Behalte die Originalsprache (Deutsch) bei — übersetze nichts.
    - Bewahre die Struktur: Überschriften, Abschnitte, Listen, Tabellen, Beträge, Daten, Referenzen.
    - Wenn Tabellen vorhanden sind, formatiere sie als Markdown-Tabellen.
    - Wenn Unterschriften, Stempel oder handschriftliche Notizen sichtbar sind, erwähne sie in Klammern (z.B. "[Unterschrift]", "[Stempel: ...]").
    - Erfinde KEINE Inhalte. Wenn etwas unleserlich ist, schreibe "[unleserlich]".
    - Transkribiere JEDEN sichtbaren Text, einschließlich Kopfzeilen, Fußzeilen, Seitenrändern, Kleingedrucktem, Seitenzahlen, Aktenzeichen, Stempeln.
    - Gib NUR den transkribierten Inhalt als Markdown zurück — keine Kommentare, keine JSON, keine Code-Fences.
    """

    static let defaultUserPrompt =
        "Extrahiere den vollständigen Inhalt dieses Dokuments, Abschnitt für Abschnitt, in der Originalstruktur."

    // Focused re-extraction of one numbered clause run from page images, used by
    // the clause audit when the text layer's number binding failed. Live-verified:
    // this small, image-only task binds correctly where a full-document re-ask
    // with the same images attached kept misbinding.
    static let clauseRunSystem = """
    Du bist ein Experte für die Extraktion deutscher Rechtsdokumente. Du erhältst \
    Seitenbilder eines zweispaltigen PDF-Dokuments. Die Bilder sind die verbindliche \
    Quelle: die Ziffer links neben einem Absatz ist seine Nummer. \
    Gib NUR gültiges JSON zurück, keine Markdown-Fences.
    """

    // Per-page anchor extraction for the binding pass: only (clause number,
    // first words) pairs, never full content. This is the one extraction task
    // the vision model binds correctly (live-verified on the pages whose full
    // transcriptions kept misbinding).
    static let pageAnchorSystem = """
    Du bist ein Experte für die Extraktion deutscher Rechtsdokumente. Du erhältst EIN \
    Seitenbild eines zweispaltigen PDF-Dokuments. Die Ziffer links neben einem Absatz \
    ist seine Nummer. Gib NUR gültiges JSON zurück, keine Markdown-Fences.
    """

    static let pageAnchorAsk = """
    Liste ALLE auf diesem Seitenbild sichtbaren Klauselnummern (z. B. 2.4., 6.15.2.1., 1.1., 8.) in Lesereihenfolge, \
    jede mit den ERSTEN 10-14 Wörtern des Textes, der direkt neben der Nummer steht (Absatz oder Überschrift). \
    Nur Nummern, die auf dem Bild sichtbar sind. Absätze OHNE sichtbare Nummer bekommen keinen Eintrag. \
    Format: {"anchors": [{"id": "2.4", "start": "erste Wörter des Absatzes"}]}
    """
}
