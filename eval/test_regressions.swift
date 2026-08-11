import Foundation

// Offline regression tests for the deterministic pipeline pieces.
//
//   swiftc -parse-as-library -o /tmp/pdfconv_tests eval/test_regressions.swift \
//       Sources/{PageFurniture,MarkdownRenderer,ClauseAudit,OrphanItemAudit,NumberingScope}.swift && /tmp/pdfconv_tests
//
// The page-break fixture reproduces the live 2026-08-10 failure (Tarif L/M
// insurance conditions): PDFKit interleaves the repeating page footer directly
// between list item "b." and its sibling "c." at a page break, and the model
// then dropped "c." (Tarif L) or misfiled it under the next Ziffer (Tarif M).
// PageFurniture.strip must remove the footer so "c." follows its list again.

@main
struct TestRegressions {
    static var failures = 0
    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {

        // MARK: - PageFurniture: page-break clause loss (Tarif L/M, 2026-08-10)

        // Real footer shape from Versicherungsbedingungen_Tarif_L_Liability (2).pdf,
        // abbreviated pages. The footer sits at the END of each page's text; page 5
        // then starts with the orphaned continuation item "c.".
        let footer = { (n: Int) -> String in
            "Stand\nJuni 2026\nVertragsunterlagen.\nPrivathaftpflichtversicherung* Risikoträger AXA Versicherung AG \(n) / 67"
        }
        let pages = [
            "Versicherungsbedingungen\nPrivathaftpflichtversicherung Tarif “L”\n1. Wer ist versichert?\n8\n\(footer(5))",
            "2.19 Kinderpflegeperson\n20\n2.20 Schäden durch Personen\n21\n\(footer(6))",
            "10.9 Sanktionsklausel\n47\n\(footer(7))",
            "1.2 bei Paaren\na. des Versicherungsnehmers und\nb. des Ehegatten oder des dauerhaft im Haushalt lebenden\nPartners;\n\(footer(8))",
            "c. einer bisher in häuslicher Gemeinschaft lebenden Person bis zu drei Monate nach Auszug, soweit aus\neiner anderen Versicherung kein Ersatz verlangt werden kann.\n1.3 bei Singles mit einem Kind\na. des Versicherungsnehmers und\n\(footer(9))",
            "2.7. 2.8. 2.9.\nSchäden an gemieteten Sachen\n(i)\nan Wohnräumen und\n\(footer(10))",
        ]
        let stripped = PageFurniture.strip(pages: pages)

        expect(stripped.count == pages.count, "strip must not drop pages")
        expect(!stripped[3].contains("Vertragsunterlagen."),
               "footer must be stripped from the page before the break")
        expect(!stripped[3].contains("Risikoträger"),
               "page-counter footer line must be stripped despite differing numbers (8 / 67 vs 9 / 67)")
        expect(stripped[4].hasPrefix("c. einer bisher in häuslicher Gemeinschaft lebenden Person"),
               "the continuation item c. must survive as the first line after the break")
        expect(stripped[3].contains("Partners;"),
               "content directly above the footer must survive")
        expect(stripped[0].contains("Stand") && stripped[0].contains("Juni 2026"),
               "the FIRST footer occurrence must be kept (only source of the document date)")
        expect(!stripped[1].contains("Stand") && !stripped[2].contains("Juni 2026"),
               "later footer occurrences must be gone")
        expect(stripped[5].contains("2.7. 2.8. 2.9."),
               "bare clause-number runs (two-column number sub-column) must never be stripped")
        expect(stripped[5].contains("(i)"),
               "enumerator-only lines must never be stripped")
        expect(stripped[1].contains("2.19 Kinderpflegeperson"),
               "unique content lines must survive")

        // Small documents: repetition is not evidence below minRepeatPages pages.
        let twoPages = ["Anschreiben\nStand\nText A", "Antwort\nStand\nText B"]
        expect(PageFurniture.strip(pages: twoPages) == twoPages,
               "documents under \(PageFurniture.minRepeatPages) pages must pass through unchanged")

        // Reference scrub: a model "reference" built from footer lines (in any
        // concatenation) is furniture; a real printed Aktenzeichen is not.
        let fkeys = PageFurniture.keys(pages: pages)
        expect(!fkeys.isEmpty, "furniture keys must be detected for the fixture")
        expect(PageFurniture.isFurniture(
                   "Vertragsunterlagen. Privathaftpflichtversicherung* Risikoträger AXA Versicherung AG 5 / 67",
                   keys: fkeys),
               "a reference concatenated from footer lines must be recognized as furniture")
        expect(PageFurniture.isFurniture("Stand Juni 2026", keys: fkeys),
               "a reference made of footer date lines must be recognized as furniture")
        expect(!PageFurniture.isFurniture("Aktenzeichen 12 UR 345/2024, Notariat Köln", keys: fkeys),
               "a real printed Aktenzeichen must survive the scrub")
        expect(!PageFurniture.isFurniture("Aktenzeichen 12 UR 345/2024", keys: []),
               "no furniture keys means nothing is scrubbed")

        // MARK: - MarkdownRenderer: heading normalization + verbatim front matter

        let rendered = MarkdownRenderer.render([
            "title": "Versicherungsbedingungen Tarif L",
            "date": "Juni 2026",
            "sections": [
        ["id": "", "title": "", "subsections": [
            ["id": "", "content": "Versicherer: AXA Versicherung AG (nachfolgend AXA) Colonia-Allee, 10–20, 51067 Köln"],
            ["id": "", "content": "Alle für den Versicherer bestimmten Anzeigen und Erklärungen sind an Alteos zu richten."],
        ]],
        ["id": "1.", "title": "Wer ist versichert?", "subsections": [
            ["id": "a", "content": "des Versicherungsnehmers;"],
        ]],
        ["id": "2", "title": "2. Was ist versichert?", "subsections": []],
            ],
        ] as [String: Any], sourceName: "test")

        expect(rendered.contains("**Stand:** Juni 2026"),
               "date renders under the document's own label (Stand)")
        expect(rendered.contains("\n## 1 Wer ist versichert?\n"),
               "trailing dot on numeric section id must be dropped (\"## 1.\" vs \"## 1\" inconsistency)")
        expect(rendered.contains("\n## 2 Was ist versichert?\n"),
               "numeric id arriving inside the title must be normalized the same way")
        expect(!rendered.contains("##\n") && !rendered.contains("## \n"),
               "the front-matter section (empty id and title) must not synthesize a heading")
        expect(!rendered.contains("## Beteiligte"),
               "no invented Beteiligte heading when parties is absent")
        expect(rendered.contains("**Versicherer:** AXA Versicherung AG (nachfolgend AXA) Colonia-Allee, 10–20, 51067 Köln"),
               "front-matter label prefix is bolded")
        expect(rendered.contains("Alle für den Versicherer bestimmten Anzeigen und Erklärungen sind an Alteos zu richten."),
               "label-less front-matter paragraphs pass through verbatim")
        expect(rendered.contains("**Stand:** Juni 2026\n\n"),
               "front-matter fields render as their own paragraphs, no trailing spaces")

        // Stray letter-section demotion: "## c. einer bisher…" (the page-break
        // orphan promoted to a heading) folds back into the a./b. enumeration.
        let demoted = MarkdownRenderer.demoteStrayLetterSections([
            ["id": "1.2", "title": "bei Paaren", "subsections": [
                ["id": "a", "content": "des Versicherungsnehmers und"],
                ["id": "b", "content": "des Ehegatten oder des dauerhaft im Haushalt lebenden Partners;"],
            ]],
            ["id": "c.", "title": "einer bisher in häuslicher Gemeinschaft lebenden Person bis zu drei Monate nach Auszug", "subsections": []],
            ["id": "1.3", "title": "bei Singles mit einem Kind", "subsections": [
                ["id": "a", "content": "des Versicherungsnehmers und"],
            ]],
            ["id": "Teil A", "title": "Allgemeines", "subsections": []],
        ])
        expect(demoted.count == 3, "the stray letter section must be absorbed, others kept")
        let subs12 = (demoted[0]["subsections"] as? [[String: Any]]) ?? []
        expect(subs12.count == 3 && (subs12.last?["id"] as? String) == "c"
                   && ((subs12.last?["content"] as? String) ?? "").hasPrefix("einer bisher"),
               "the orphan becomes subsection c of the preceding enumeration")
        expect((demoted[2]["id"] as? String) == "Teil A",
               "uppercase letter sections are never demoted")
        let noEnum = MarkdownRenderer.demoteStrayLetterSections([
            ["id": "1", "title": "T", "subsections": [["id": "1.1", "content": "x"]]],
            ["id": "c", "title": "orphan", "subsections": []],
        ])
        expect(noEnum.count == 2,
               "a letter section without a preceding letter enumeration is left alone")

        // MARK: - OrphanItemAudit: the deterministic page-break backstop

        let auditPages = [
            "--- Seite 4 von 34 ---\n1.2 bei Paaren\na. des Versicherungsnehmers und\nb. des Ehegatten oder des eingetragenen Lebenspartners oder des dauerhaft im Haushalt lebenden\nPartners;",
            "--- Seite 5 von 34 ---\nc. einer bisher in häuslicher Gemeinschaft lebenden Person bis zu drei Monate nach Auszug, soweit aus\neiner anderen Versicherung kein Ersatz verlangt werden kann.\n1.3 bei Singles mit einem Kind\na. des Versicherungsnehmers und",
            "--- Seite 9 von 34 ---\n(i) an Wohnräumen und weiteren zu privaten Zwecken gemieteten Räumen in Gebäuden mitversichert\n2.8 Sportausübung",
        ]
        let orphans = OrphanItemAudit.items(pages: auditPages)
        guard let itemC = orphans.first(where: { $0.id == "c" }) else {
            expect(false, "item c must be detected"); exit(1)
        }
        expect(orphans.count == 5,
               "ALL line-start enumeration items are detected (a, b, c, a, (i)) — got \(orphans.count)")
        expect(itemC.token == "c." && itemC.page == 5
                   && itemC.text.hasPrefix("einer bisher in häuslicher Gemeinschaft"),
               "item text starts after the enumerator and stops at the next clause heading")
        expect(itemC.anchorKey != nil && itemC.anchorId == "b",
               "the preceding item (across the page break) becomes the insertion anchor")

        // Absent -> inserted after the anchor item, verbatim.
        let dropped: [[String: Any]] = [
            ["id": "1.2", "title": "bei Paaren", "subsections": [
                ["id": "a", "content": "des Versicherungsnehmers und"],
                ["id": "b", "content": "des Ehegatten oder des eingetragenen Lebenspartners oder des dauerhaft im Haushalt lebenden Partners;"],
            ]],
            ["id": "2.7", "title": "Mietsachschäden", "subsections": [
                ["id": "a", "content": "Versichert ist die gesetzliche Haftpflicht wegen Mietsachschäden ausschließlich (i) an Wohnräumen und weiteren zu privaten Zwecken gemieteten Räumen in Gebäuden mitversichert"],
            ]],
        ]
        let repairedDrop = OrphanItemAudit.repair(sections: dropped, items: orphans)
        let subsAfter = (repairedDrop.sections[0]["subsections"] as? [[String: Any]]) ?? []
        expect(repairedDrop.unresolved.isEmpty && subsAfter.count == 3
                   && (subsAfter[2]["id"] as? String) == "c"
                   && ((subsAfter[2]["content"] as? String) ?? "").hasPrefix("einer bisher"),
               "a dropped page-leading item is re-inserted after its anchor with its printed label")
        expect(((repairedDrop.sections[1]["subsections"] as? [[String: Any]]) ?? []).count == 1,
               "an item preserved INLINE ((i) inside its paragraph) is left untouched")

        // The M4 live bug: sibling sections share word-identical items
        // (1.1 b. == 1.2 b.); the insert must land in the section that does
        // NOT already carry the item's id.
        let siblings: [[String: Any]] = [
            ["id": "1.1", "title": "bei Familien", "subsections": [
                ["id": "a", "content": "des Versicherungsnehmers und"],
                ["id": "b", "content": "des Ehegatten oder des eingetragenen Lebenspartners oder des dauerhaft im Haushalt lebenden Partners;"],
                ["id": "c", "content": "der unverheirateten und nicht in einer eingetragenen Lebenspartnerschaft lebenden Kinder"],
            ]],
            ["id": "1.2", "title": "bei Paaren", "subsections": [
                ["id": "a", "content": "des Versicherungsnehmers und"],
                ["id": "b", "content": "des Ehegatten oder des eingetragenen Lebenspartners oder des dauerhaft im Haushalt lebenden Partners;"],
            ]],
        ]
        let repairedSibling = OrphanItemAudit.repair(sections: siblings, items: [itemC])
        let subs11 = (repairedSibling.sections[0]["subsections"] as? [[String: Any]]) ?? []
        let subs12b = (repairedSibling.sections[1]["subsections"] as? [[String: Any]]) ?? []
        expect(subs11.count == 3 && subs12b.count == 3
                   && (subs12b[2]["id"] as? String) == "c"
                   && ((subs12b[2]["content"] as? String) ?? "").hasPrefix("einer bisher"),
               "insertion skips the sibling section that already has a c. item (1.1) and lands in 1.2")

        // The M4 live bug, part 2: a dropped MID-PAGE run ((ii)/(iii)) chains
        // back in — each inserted item anchors the next.
        let runPages = [
            "--- Seite 11 von 34 ---\n(i) aus der Verletzung von Pflichten, die dem Versicherungsnehmer obliegen\n(ii) aus der Vermietung von einzelnen Wohn- und Gewerberäumen inkl. Nebenräumen\n(iii) als Bauherr oder Unternehmer von Bauarbeiten bis 200.000 Euro je Bauvorhaben",
        ]
        let runItems = OrphanItemAudit.items(pages: runPages)
        expect(runItems.count == 3, "mid-page items are detected too — got \(runItems.count)")
        let runAnswer: [[String: Any]] = [
            ["id": "2.4", "title": "Haus- und Grundbesitz", "subsections": [
                ["id": "(i)", "content": "aus der Verletzung von Pflichten, die dem Versicherungsnehmer obliegen"],
            ]],
        ]
        let repairedRun = OrphanItemAudit.repair(sections: runAnswer, items: runItems)
        let runSubs = (repairedRun.sections[0]["subsections"] as? [[String: Any]]) ?? []
        expect(repairedRun.unresolved.isEmpty && runSubs.count == 3
                   && (runSubs[1]["id"] as? String) == "(ii)" && (runSubs[2]["id"] as? String) == "(iii)",
               "a dropped mid-page run is chained back in after its preceding item")

        // Fused label-less into the previous item -> split and labeled.
        let fused: [[String: Any]] = [
            ["id": "1.2", "title": "bei Paaren", "subsections": [
                ["id": "b", "content": "des Ehegatten oder des dauerhaft im Haushalt lebenden Partners; einer bisher in häuslicher Gemeinschaft lebenden Person bis zu drei Monate nach Auszug, soweit aus einer anderen Versicherung kein Ersatz verlangt werden kann."],
            ]],
        ]
        let repairedFuse = OrphanItemAudit.repair(sections: fused, items: [itemC])
        let fusedSubs = (repairedFuse.sections[0]["subsections"] as? [[String: Any]]) ?? []
        expect(fusedSubs.count == 2
                   && ((fusedSubs[0]["content"] as? String) ?? "").hasSuffix("Partners;")
                   && (fusedSubs[1]["id"] as? String) == "c"
                   && ((fusedSubs[1]["content"] as? String) ?? "").hasPrefix("einer bisher"),
               "an item fused label-less into the previous one is split out and labeled")

        // Correctly labeled already -> untouched; unplaceable -> reported.
        let correct: [[String: Any]] = [
            ["id": "1.2", "title": "bei Paaren", "subsections": [
                ["id": "c", "content": "einer bisher in häuslicher Gemeinschaft lebenden Person bis zu drei Monate nach Auszug, soweit aus einer anderen Versicherung kein Ersatz verlangt werden kann."],
            ]],
        ]
        let repairedNoop = OrphanItemAudit.repair(sections: correct, items: [itemC])
        expect(repairedNoop.unresolved.isEmpty
                   && ((repairedNoop.sections[0]["subsections"] as? [[String: Any]]) ?? []).count == 1,
               "a correctly labeled item is left untouched")
        let unplaceable = OrphanItemAudit.repair(sections: [["id": "9", "title": "x", "subsections": [["id": "a", "content": "völlig anderer Inhalt ohne Bezug"]]]],
                                                 items: [itemC])
        expect(unplaceable.unresolved.count == 1,
               "an item that can neither be found nor placed is reported for the warning")

        // The L4 live bug: the model kept 2.7 a.'s enumeration as label-less
        // prose AND emitted "(i)"/"(ii)" subsections with the same text.
        // Dedup drops the labeled duplicates; the audit then re-splits the
        // prose copy so each label exists exactly once.
        let dupPages = [
            "--- Seite 9 von 44 ---\nVersichert ist die gesetzliche Haftpflicht wegen Mietsachschäden ausschließlich\n(i) an Wohnräumen und weiteren gemieteten Räumen einschließlich Terrasse\n(ii) sonstigen zu privaten Zwecken gemieteten Räumen in Gebäuden mitversichert\n2.8 Sportausübung",
        ]
        let dupSections: [[String: Any]] = [
            ["id": "2.7", "title": "Mietsachschäden", "subsections": [
                ["id": "a", "content": "Mietsachschäden sind Schäden an fremden Sachen. Versichert ist die gesetzliche Haftpflicht wegen Mietsachschäden ausschließlich an Wohnräumen und weiteren gemieteten Räumen einschließlich Terrasse sonstigen zu privaten Zwecken gemieteten Räumen in Gebäuden mitversichert Das Gleiche gilt für geliehene Räume."],
                ["id": "(i)", "content": "an Wohnräumen und weiteren gemieteten Räumen einschließlich Terrasse"],
                ["id": "(ii)", "content": "sonstigen zu privaten Zwecken gemieteten Räumen in Gebäuden mitversichert"],
            ]],
        ]
        let deduped = MarkdownRenderer.dropDuplicatedEnumerationSubs(dupSections)
        expect(((deduped[0]["subsections"] as? [[String: Any]]) ?? []).count == 1,
               "labeled subsections duplicating earlier prose are dropped")
        let redone = OrphanItemAudit.repair(sections: deduped, items: OrphanItemAudit.items(pages: dupPages))
        let redoneSubs = (redone.sections[0]["subsections"] as? [[String: Any]]) ?? []
        expect(redoneSubs.count == 3
                   && (redoneSubs[1]["id"] as? String) == "(i)" && (redoneSubs[2]["id"] as? String) == "(ii)"
                   && ((redoneSubs[0]["content"] as? String) ?? "").hasSuffix("ausschließlich")
                   && ((redoneSubs[2]["content"] as? String) ?? "").contains("Das Gleiche gilt"),
               "after dedup the audit re-splits the prose copy: each enumerator exactly once, no text lost")
        let legit: [[String: Any]] = [
            ["id": "2.8", "title": "Sport", "subsections": [
                ["id": "a", "content": "Versichert ist die Haftpflicht aus der Ausübung von Sport."],
                ["id": "b", "content": "Ausgeschlossen sind Ansprüche aus einer jagdlichen Betätigung."],
            ]],
        ]
        expect(((MarkdownRenderer.dropDuplicatedEnumerationSubs(legit)[0]["subsections"] as? [[String: Any]]) ?? []).count == 2,
               "distinct items are never dropped by the dedup")

        // The S5 live bug: front-matter prose shares its 32-char opening with
        // body clause 10.8 a. ("Alle für den Versicherer bestimmten Anzeigen
        // und Erklärungen …"). When the real item is present under its id, the
        // colliding front-matter hit must stay untouched.
        let collisionPages = [
            "--- Seite 30 von 34 ---\n10.8 Anzeigen, Willenserklärungen, Anschriftenänderung\na. Alle für den Versicherer bestimmten Anzeigen und Erklärungen (z.B. Berufswechsel, Meldung eines Schadens) sind unverzüglich abzugeben",
        ]
        let collisionItems = OrphanItemAudit.items(pages: collisionPages)
        let collisionSections: [[String: Any]] = [
            ["id": "", "title": "", "subsections": [
                ["id": "", "content": "Alle für den Versicherer bestimmten Anzeigen und Erklärungen sind an Alteos zu richten. Dazu gehört die Bearbeitung aller Versicherungsfragen."],
            ]],
            ["id": "10.8", "title": "Anzeigen, Willenserklärungen, Anschriftenänderung", "subsections": [
                ["id": "a", "content": "Alle für den Versicherer bestimmten Anzeigen und Erklärungen (z.B. Berufswechsel, Meldung eines Schadens) sind unverzüglich abzugeben"],
            ]],
        ]
        let collisionOut = OrphanItemAudit.repair(sections: collisionSections, items: collisionItems)
        let fmSubs = (collisionOut.sections[0]["subsections"] as? [[String: Any]]) ?? []
        expect(collisionOut.unresolved.isEmpty && (fmSubs[0]["id"] as? String) == ""
                   && fmSubs.count == 1,
               "a fingerprint collision with front matter must not relabel the front matter when the real item is present")

        // The S6 live bug: the labeled item sits as the FIRST subsection of
        // the FOLLOWING section, ahead of that section's own "a." — a
        // misfile, moved back after its anchor. Other labeled placements stand.
        let misfiled: [[String: Any]] = [
            ["id": "1.2", "title": "bei Paaren", "subsections": [
                ["id": "a", "content": "des Versicherungsnehmers und"],
                ["id": "b", "content": "des Ehegatten oder des eingetragenen Lebenspartners oder des dauerhaft im Haushalt lebenden Partners;"],
            ]],
            ["id": "1.3", "title": "bei Singles mit einem Kind", "subsections": [
                ["id": "c", "content": "einer bisher in häuslicher Gemeinschaft lebenden Person bis zu drei Monate nach Auszug, soweit aus einer anderen Versicherung kein Ersatz verlangt werden kann."],
                ["id": "a", "content": "des Versicherungsnehmers und"],
            ]],
        ]
        let movedOut = OrphanItemAudit.repair(sections: misfiled, items: [itemC])
        let m12 = (movedOut.sections[0]["subsections"] as? [[String: Any]]) ?? []
        let m13 = (movedOut.sections[1]["subsections"] as? [[String: Any]]) ?? []
        expect(m12.count == 3 && (m12[2]["id"] as? String) == "c"
                   && m13.count == 1 && (m13[0]["id"] as? String) == "a",
               "a labeled item misfiled as first sub of the NEXT section is moved back to the end of its enumeration")
        // Same misfile, but the following "a." arrives as unlabeled content
        // (the M7 live variant).
        let misfiled2: [[String: Any]] = [
            misfiled[0],
            ["id": "1.3", "title": "bei Singles mit einem Kind", "subsections": [
                ["id": "c", "content": "einer bisher in häuslicher Gemeinschaft lebenden Person bis zu drei Monate nach Auszug, soweit aus einer anderen Versicherung kein Ersatz verlangt werden kann."],
                ["id": "", "content": "a. des Versicherungsnehmers und"],
            ]],
        ]
        let movedOut2 = OrphanItemAudit.repair(sections: misfiled2, items: [itemC])
        expect(((movedOut2.sections[0]["subsections"] as? [[String: Any]]) ?? []).count == 3
                   && ((movedOut2.sections[1]["subsections"] as? [[String: Any]]) ?? []).count == 1,
               "the misfile move also fires when the following a. is unlabeled content")

        // The M5/M6 live bug: the whole Versicherer front-matter block dropped.
        // recoverLeadingFrontMatter restores it from the body-start page.
        let fmPages = [
            "--- Seite 4 von 40 ---\n10.9 Sanktionsklausel\n47\n10.10 Klärung von Meinungsverschiedenheiten\n48\nVersicherer: AXA Versicherung AG (nachfolgend AXA) Colonia-Allee, 10–20, 51067 Köln\nAXA hat die Alteos GmbH, vertreten durch den Geschäftsführer, mit der Vertragsverwaltung beauftragt.\nAlle für den Versicherer bestimmten Anzeigen und Erklärungen sind an Alteos zu richten. Dazu gehört die\nBearbeitung aller Versicherungsfragen aus dem Versicherungsvertrag.\n1. Wer ist versichert?\nVersichert ist im Rahmen des vereinbarten Versicherungsumfangs die gesetzliche Haftpflicht",
        ]
        let fmDropped: [[String: Any]] = [
            ["id": "1", "title": "Wer ist versichert?", "subsections": [
                ["id": "", "content": "Versichert ist im Rahmen des vereinbarten Versicherungsumfangs die gesetzliche Haftpflicht"],
            ]],
        ]
        let fmOut = OrphanItemAudit.recoverLeadingFrontMatter(sections: fmDropped, pages: fmPages)
        let fmRecovered = (fmOut.first?["subsections"] as? [[String: Any]]) ?? []
        let fmTexts = fmRecovered.compactMap { $0["content"] as? String }
        expect(fmOut.count == 2 && (fmOut.first.flatMap { ($0["id"] as? String) }) == ""
                   && fmTexts.contains(where: { $0.hasPrefix("Versicherer: AXA Versicherung AG") })
                   && fmTexts.contains(where: { $0.contains("Alle für den Versicherer bestimmten Anzeigen") }),
               "a dropped front-matter block is restored verbatim before the body, TOC lines excluded")
        expect(!fmTexts.contains(where: { $0.contains("Sanktionsklausel") }),
               "TOC lines above the front matter are not dragged in")
        let fmPresent = OrphanItemAudit.recoverLeadingFrontMatter(sections: [
            ["id": "", "title": "", "subsections": [
                ["id": "", "content": "Versicherer: AXA Versicherung AG (nachfolgend AXA) Colonia-Allee, 10–20, 51067 Köln AXA hat die Alteos GmbH, vertreten durch den Geschäftsführer, mit der Vertragsverwaltung beauftragt."],
                ["id": "", "content": "Alle für den Versicherer bestimmten Anzeigen und Erklärungen sind an Alteos zu richten. Dazu gehört die Bearbeitung aller Versicherungsfragen aus dem Versicherungsvertrag."],
            ]],
        ] + fmDropped, pages: fmPages)
        expect(((fmPresent.first?["subsections"] as? [[String: Any]]) ?? []).count == 2,
               "present front matter is left untouched (no duplicates appended)")

        // Decomposed (NFD) content must not shift the fused-item cut: the
        // split index is counted in unicode scalars, or every combining mark
        // before the item start moves the cut early and corrupts both halves.
        let nfdFused: [[String: Any]] = [
            ["id": "1.2", "title": "bei Paaren", "subsections": [
                ["id": "b", "content": ("Schäden des Ehegatten und die Gewährleistung üblicher Pflichten; einer bisher in häuslicher Gemeinschaft lebenden Person bis zu drei Monate nach Auszug, soweit aus einer anderen Versicherung kein Ersatz verlangt werden kann.").decomposedStringWithCanonicalMapping],
            ]],
        ]
        let nfdRepaired = OrphanItemAudit.repair(sections: nfdFused, items: [itemC])
        let nfdSubs = (nfdRepaired.sections.first?["subsections"] as? [[String: Any]]) ?? []
        expect(nfdSubs.count == 2 && (nfdSubs.last?["id"] as? String) == "c"
                   && ((nfdSubs.last?["content"] as? String) ?? "").hasPrefix("einer bisher")
                   && ((nfdSubs.first?["content"] as? String) ?? "").hasSuffix("Pflichten;"),
               "NFD content is cut at the exact fused-item start (scalar-counted index)")

        // MARK: - NumberingScope: flattened numbering scopes (AHB Stichentscheid)

        // The AHB live shape: Abschnitt 3 clauses 1.–8., then the ROLAND block's
        // "Stichentscheid" scope restarts at 1. under a printed keyword heading
        // the model absorbed into clause 8's tail. Page shape mirrors the real
        // text layer: decoupled number column, heading line, run paragraphs.
        let scopePages = [
            "--- Seite 11 von 17 ---\n1. 1.1. 1.2. 1.3.\nKosten, die er bei einer Rechtsschutzbestätigung vor Einleitung dieser\nMaßnahmen zu tragen hätte.\nStichentscheid\nLehnt der Versicherer den Rechtsschutz ab,\n weil der durch die Wahrnehmung der rechtlichen Interessen voraussicht-\nlich entstehende Kostenaufwand in einem groben Missverhältnis zum angestrebten Erfolg steht oder\n2. 3.  Hat der Versicherer seine Leistungspflicht gemäß Absatz (1) verneint und\nstimmt die versicherte Person der Auffassung des Versicherers nicht zu,",
        ]
        let flattened: [[String: Any]] = [
            ["id": "", "title": "Abschnitt 3 – Forderungsausfallrisiko", "subsections": [
                ["id": "1", "content": "Gegenstand der Forderungsausfalldeckung Der Versicherer gewährt Versicherungsschutz für den Fall, dass eine versicherte Person geschädigt wird."],
                ["id": "7", "content": "Ausschlussfrist Alle Ansprüche aus dieser Ausfalldeckung verfallen nach drei Jahren."],
                ["id": "8", "content": "Spezial-Schadenersatzrechtsschutz Kosten, die er bei einer Rechtsschutzbestätigung vor Einleitung dieser Maßnahmen zu tragen hätte. Stichentscheid"],
                ["id": "1", "content": "Lehnt der Versicherer den Rechtsschutz ab,"],
                ["id": "1.1", "content": "weil der durch die Wahrnehmung der rechtlichen Interessen voraussichtlich entstehende Kostenaufwand in einem groben Missverhältnis zum angestrebten Erfolg steht oder"],
                ["id": "2", "content": "Hat der Versicherer seine Leistungspflicht gemäß Absatz (1) verneint und stimmt die versicherte Person der Auffassung des Versicherers nicht zu,"],
                ["id": "3", "content": "Der Versicherer kann der versicherten Person eine Frist von mindestens einem Monat setzen."],
            ]],
        ]
        let scoped = NumberingScope.split(sections: flattened, pages: scopePages)
        let scopedA = (scoped.sections.first?["subsections"] as? [[String: Any]]) ?? []
        let scopedB = scoped.sections.count > 1 ? ((scoped.sections[1]["subsections"] as? [[String: Any]]) ?? []) : []
        expect(scoped.sections.count == 2 && scoped.scopes == ["Stichentscheid"],
               "the restarted Stichentscheid run is split into its own section")
        expect((scoped.sections.count > 1 ? scoped.sections[1]["title"] as? String : nil) == "Stichentscheid"
                   && (scoped.sections.count > 1 ? scoped.sections[1]["id"] as? String : nil) == "",
               "the new section is titled with the document's own heading line")
        expect(scopedA.count == 3 && scopedB.count == 4
                   && (scopedB.first?["id"] as? String) == "1"
                   && (scopedA.last?["content"] as? String)?.hasSuffix("zu tragen hätte.") == true,
               "the absorbed heading is stripped from clause 8's tail; no text is lost")
        let rescoped = NumberingScope.split(sections: scoped.sections, pages: scopePages)
        expect(rescoped.sections.count == 2 && rescoped.scopes.isEmpty,
               "the split is idempotent")

        // Invented numbering under running prose must NOT split: the candidate
        // "heading" is a wrap line, betrayed by its predecessor stopping
        // mid-sentence (no terminal punctuation).
        let wrapPages = [
            "--- Seite 3 von 9 ---\nDer Vertrag endet, wenn der Versicherer dies erklärt und dass eine\nVersicherungsleistung im Übrigen nicht erbracht wird\nLehnt der Versicherer die Leistung ohne Angabe von Gründen vollständig ab,\nso gilt das Weitere.",
        ]
        let wrapped: [[String: Any]] = [
            ["id": "6", "title": "Kündigung", "subsections": [
                ["id": "6.1", "content": "Der Vertrag endet, wenn der Versicherer dies erklärt und dass eine Versicherungsleistung im Übrigen nicht erbracht wird"],
                ["id": "1", "content": "Lehnt der Versicherer die Leistung ohne Angabe von Gründen vollständig ab,"],
                ["id": "2", "content": "so gilt das Weitere."],
            ]],
        ]
        expect(NumberingScope.split(sections: wrapped, pages: wrapPages).scopes.isEmpty,
               "a wrap line of running prose is never promoted to a scope heading")

        // A colon lead-in ("gelten folgende Bestimmungen:") introduces a nested
        // list, not a new scope — rejected by its terminal punctuation.
        let colonPages = [
            "--- Seite 4 von 9 ---\nDie Beitragsanpassung erfolgt jährlich.\nFür die Beitragsanpassung gelten folgende Bestimmungen:\nDer Beitrag wird unter Berücksichtigung der Kalkulationsunterlagen ermittelt.\nDer Versicherer überprüft jährlich die kalkulierten Werte der Bestandsgruppen.",
        ]
        let colonLed: [[String: Any]] = [
            ["id": "2", "title": "Anpassung des Beitrages", "subsections": [
                ["id": "2.1", "content": "Für die Beitragsanpassung gelten folgende Bestimmungen:"],
                ["id": "1", "content": "Der Beitrag wird unter Berücksichtigung der Kalkulationsunterlagen ermittelt."],
                ["id": "2", "content": "Der Versicherer überprüft jährlich die kalkulierten Werte der Bestandsgruppen."],
            ]],
        ]
        expect(NumberingScope.split(sections: colonLed, pages: colonPages).scopes.isEmpty,
               "a colon lead-in above a restarted list is not a scope heading")

        // A numeric decrease that does not restart at exactly 1. is a model
        // error, not a scope — even when a perfectly valid printed heading
        // sits above the decreased run (this makes the restart-at-1 guard the
        // ONLY thing preventing the split, so deleting it fails this test).
        let notOnePages = [
            "--- Seite 6 von 9 ---\nDie fünfte Bestimmung ist hiermit vollständig abgeschlossen worden.\nSonderbedingungen\nDie dritte Bestimmung regelt die verbleibenden Sonderfälle im Einzelnen.\nDie vierte Bestimmung ergänzt sie um die technischen Einzelheiten dazu.",
        ]
        let notOne: [[String: Any]] = [
            ["id": "", "title": "T", "subsections": [
                ["id": "1", "content": "Die erste Bestimmung gilt hier mit eigenem Wortlaut für den Abgleich."],
                ["id": "2", "content": "Die zweite Bestimmung gilt ebenfalls mit eigenem Wortlaut hierzu."],
                ["id": "5", "content": "Die fünfte Bestimmung ist hiermit vollständig abgeschlossen worden."],
                ["id": "3", "content": "Die dritte Bestimmung regelt die verbleibenden Sonderfälle im Einzelnen."],
                ["id": "4", "content": "Die vierte Bestimmung ergänzt sie um die technischen Einzelheiten dazu."],
            ]],
        ]
        expect(NumberingScope.split(sections: notOne, pages: notOnePages).scopes.isEmpty,
               "a numeric decrease that does not restart at 1 never splits, heading or not")

        // A restarted run that is not strictly ascending (1., 3., 2.) is a
        // misbound answer — again with a valid heading above, so the
        // ascending-run veto is what this test observes.
        let misorderedPages = [
            "--- Seite 7 von 9 ---\nDie zweite Bestimmung ist hiermit vollständig abgeschlossen worden.\nSonderbedingungen\nDie erste Regel des neuen Abschnitts steht hier mit eigenem Wortlaut.\nDie dritte Regel folgt direkt darauf mit genügend eigenem Wortlaut.\nDie zweite Regel kommt in dieser Antwort zu spät und beweist den Fehler.",
        ]
        let misordered: [[String: Any]] = [
            ["id": "", "title": "T", "subsections": [
                ["id": "1", "content": "Die erste Bestimmung gilt hier mit eigenem Wortlaut für den Abgleich."],
                ["id": "2", "content": "Die zweite Bestimmung ist hiermit vollständig abgeschlossen worden."],
                ["id": "1", "content": "Die erste Regel des neuen Abschnitts steht hier mit eigenem Wortlaut."],
                ["id": "3", "content": "Die dritte Regel folgt direkt darauf mit genügend eigenem Wortlaut."],
                ["id": "2", "content": "Die zweite Regel kommt in dieser Antwort zu spät und beweist den Fehler."],
            ]],
        ]
        expect(NumberingScope.split(sections: misordered, pages: misorderedPages).scopes.isEmpty,
               "a restarted run that is not strictly ascending never splits")

        // Decomposed page text (NFD umlauts, as some PDF producers emit):
        // the cut index must be counted in unicode scalars, or every
        // combining mark before the match shifts the heading one char early
        // ("Stichentschei" instead of "Stichentscheid", live-reproduced).
        let nfdScoped = NumberingScope.split(
            sections: flattened, pages: scopePages.map { $0.decomposedStringWithCanonicalMapping })
        let nfdA = (nfdScoped.sections.first?["subsections"] as? [[String: Any]]) ?? []
        expect(nfdScoped.scopes == ["Stichentscheid"]
                   && (nfdA.last?["content"] as? String)?.hasSuffix("zu tragen hätte.") == true,
               "decomposed (NFD) page text yields the full verbatim heading and a clean tail strip")

        // The same opening printed twice on one page under DIFFERENT headings:
        // we cannot know which occurrence is the restarted run, so no split —
        // checking only the first occurrence would title the scope wrong.
        let twicePages = [
            "--- Seite 8 von 9 ---\nDie vorige Bestimmung ist hiermit vollständig abgeschlossen worden.\nVertragsrechtsschutz\nLehnt der Versicherer den Rechtsschutz ab, so gilt das Folgende hier.\nDiese Regel ist damit ebenfalls vollständig abgeschlossen worden.\nStichentscheid\nLehnt der Versicherer den Rechtsschutz ab, so gilt das Folgende hier.\nDie weitere Regel schließt sich mit eigenem Wortlaut direkt an.",
        ]
        let twice: [[String: Any]] = [
            ["id": "", "title": "T", "subsections": [
                ["id": "1", "content": "Die vorige Bestimmung ist hiermit vollständig abgeschlossen worden."],
                ["id": "2", "content": "Diese Regel ist damit ebenfalls vollständig abgeschlossen worden."],
                ["id": "1", "content": "Lehnt der Versicherer den Rechtsschutz ab, so gilt das Folgende hier."],
                ["id": "2", "content": "Die weitere Regel schließt sich mit eigenem Wortlaut direkt an."],
            ]],
        ]
        expect(NumberingScope.split(sections: twice, pages: twicePages).scopes.isEmpty,
               "a repeated opening under different headings vetoes the split")

        // An abbreviation period ("… des BGB, HGB u. a.") ends no sentence:
        // the line after it is a wrap line, not a heading.
        let abbrevPages = [
            "--- Seite 5 von 12 ---\nVersichert sind Ansprüche nach den Vorschriften des BGB, HGB u. a.\nRechtsvorschriften soweit sie im Inland unmittelbar gelten\nLehnt der Versicherer die Leistung ohne jede Begründung vollständig ab,\nso kann der Versicherungsnehmer binnen eines Monats Widerspruch einlegen.",
        ]
        let abbrev: [[String: Any]] = [
            ["id": "6.7", "title": "Ausschlüsse", "subsections": [
                ["id": "6.7.1", "content": "Versichert sind Ansprüche nach den Vorschriften des BGB, HGB u. a. Rechtsvorschriften soweit sie im Inland unmittelbar gelten"],
                ["id": "1", "content": "Lehnt der Versicherer die Leistung ohne jede Begründung vollständig ab,"],
                ["id": "2", "content": "so kann der Versicherungsnehmer binnen eines Monats Widerspruch einlegen."],
            ]],
        ]
        expect(NumberingScope.split(sections: abbrev, pages: abbrevPages).scopes.isEmpty,
               "a wrap line after an abbreviation period is never promoted to a heading")

        // Clause-level punctuation inside the candidate line marks running
        // prose even when the line above it ends a real sentence.
        let commaPages = [
            "--- Seite 5 von 12 ---\nDiese Regelung ist damit abschließend und vollständig beschrieben worden.\nRechtsvorschriften, soweit sie im Inland unmittelbar gelten\nLehnt der Versicherer die Leistung ohne jede Begründung vollständig ab,\nso kann der Versicherungsnehmer binnen eines Monats Widerspruch einlegen.",
        ]
        expect(NumberingScope.split(sections: abbrev, pages: commaPages).scopes.isEmpty,
               "a candidate line with clause-level punctuation is never a heading")

        // A rendered TOC restarts numbering per Abschnitt by design.
        let toc: [[String: Any]] = [
            ["id": "", "title": "Inhaltsverzeichnis Teil A", "subsections": [
                ["id": "1", "content": "Gegenstand der Forderungsausfalldeckung"],
                ["id": "8", "content": "Spezial-Schadenersatzrechtsschutz"],
                ["id": "1", "content": "Lehnt der Versicherer den Rechtsschutz ab,"],
                ["id": "2", "content": "Hat der Versicherer seine Leistungspflicht gemäß Absatz (1) verneint und stimmt die versicherte Person der Auffassung des Versicherers nicht zu,"],
            ]],
        ]
        expect(NumberingScope.split(sections: toc, pages: scopePages).scopes.isEmpty,
               "TOC sections are never split")

        // A whole document part returned as ONE giant section: every verified
        // scope is peeled off, each titled with its own printed heading.
        let multiPages = [
            "--- Seite 2 von 9 ---\nErster Abschnitt\nDie erste Bestimmung gilt für alle Verträge dieser Art ohne jede Ausnahme.\nNoch eine Regel steht hier mit ausreichend eigenem Text für den Abgleich.\nZweiter Abschnitt\nDie zweite Bestimmung gilt nur, wenn sie ausdrücklich vereinbart wurde.\nWeitere Regeln folgen an dieser Stelle mit genügend eigenem Wortlaut.\nDritter Abschnitt\nDie dritte Bestimmung ergänzt die beiden vorangehenden um Sonderfälle.\nAbschließende Regeln stehen hier mit ausreichend eigenem Wortlaut.",
        ]
        let giant: [[String: Any]] = [
            ["id": "", "title": "Teil A", "subsections": [
                ["id": "1", "content": "Die erste Bestimmung gilt für alle Verträge dieser Art ohne jede Ausnahme."],
                ["id": "2", "content": "Noch eine Regel steht hier mit ausreichend eigenem Text für den Abgleich."],
                ["id": "1", "content": "Die zweite Bestimmung gilt nur, wenn sie ausdrücklich vereinbart wurde."],
                ["id": "2", "content": "Weitere Regeln folgen an dieser Stelle mit genügend eigenem Wortlaut."],
                ["id": "1", "content": "Die dritte Bestimmung ergänzt die beiden vorangehenden um Sonderfälle."],
                ["id": "2", "content": "Abschließende Regeln stehen hier mit ausreichend eigenem Wortlaut."],
            ]],
        ]
        let peeled = NumberingScope.split(sections: giant, pages: multiPages)
        expect(peeled.sections.count == 3
                   && peeled.scopes == ["Zweiter Abschnitt", "Dritter Abschnitt"]
                   && peeled.sections.allSatisfy { (($0["subsections"] as? [[String: Any]]) ?? []).count == 2 },
               "a giant section is peeled into one section per verified scope")

        let commaFixed = MarkdownRenderer.render([
            "title": "t",
            "sections": [["id": "1", "title": "T", "subsections": [
                ["id": "a", "content": "Kinder (auch Stief- , Adoptiv- und Pflegekinder) der Personen"],
            ]]],
        ] as [String: Any], sourceName: "test")
        expect(commaFixed.contains("Stief-, Adoptiv- und Pflegekinder"),
               "line-break comma artifact \"- , \" is normalized to \"-, \"")

        if failures == 0 {
            print("PASS: all regression checks green")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
