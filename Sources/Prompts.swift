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
      "reference": "file reference / Aktenzeichen",
      "date": "date of notarization",
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
    - Include ALL front matter as sections: cover notes (e.g. "Hinweise zum Aufbau und zur Anwendung") and the complete table of contents, before the body sections.
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
