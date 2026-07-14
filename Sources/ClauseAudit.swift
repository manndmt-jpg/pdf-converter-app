import Foundation

// Detects silently dropped clauses. German legal documents number their clauses
// (2.1., 6.15.2.4., ...) and models occasionally omit a small contiguous run of
// them while the rest of the answer is complete (observed live: a fresh Gemini
// answer missing exactly 6.15.2.4-6.15.2.6 while three other answers of the
// same document had them). The completeness guard in Converter only catches
// losses over 60%, so a small hole sails through — this audit closes that gap
// by comparing the clause numbers present in the source text against the ones
// present in the rendered answer.
//
// Foundation-only and standalone-compilable (same rule as APIResponseParser and
// DocumentChunker) so scratch harnesses can test it against real documents.
enum ClauseAudit {
    // Above this many missing ids the mismatch is structural (a document whose
    // numbering the model reformatted wholesale), not a droppable hole a single
    // re-ask could fill.
    static let retryThreshold = 24

    // Audit only documents that are clearly clause-numbered; a handful of ids
    // could be incidental (figure numbers, references into other documents).
    static let minSourceIds = 5

    // Multi-level clause ids: 2-4 components, each 1-2 digits with no leading
    // zero ("2.1", "6.15.2.4", "7.17.3"). Single numbers ("1.", "7.") are far
    // too noisy in prose to audit. German number formatting keeps most noise
    // out of the pattern: thousands separators have 3-digit groups
    // ("30.000.000"), decimals use commas ("3,5 t"), zero-padded dates and
    // version stamps ("13.07.2026", "04.20") fail the no-leading-zero rule, and
    // the trailing dot-digit guard stops backtracking from carving ids out of
    // non-padded dates ("1.12.2024"). Bare day-month dates ("zum 31.12.") and
    // dotted phone numbers still slip through here; the sibling gate in
    // missingIds() suppresses those.
    private static let idPattern: NSRegularExpression = {
        let component = "[1-9][0-9]?"
        // (?<![0-9.,])   — not preceded by digit, dot, or comma (blocks matches
        //   inside larger numbers and after decimal commas)
        // (?![0-9,])     — not followed by more digits or a decimal comma
        // (?!\\.[0-9])   — not followed by a dot that starts another digit
        //   group; without this, "1.12.2024" backtracks to a phantom "1.12"
        let pattern = "(?<![0-9.,])(\(component)(?:\\.\(component)){1,3})(?![0-9,])(?!\\.[0-9])"
        return try! NSRegularExpression(pattern: pattern)
    }()

    static func ids(in text: String) -> Set<String> {
        let ns = text as NSString
        var found = Set<String>()
        idPattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            if let match { found.insert(ns.substring(with: match.range(at: 1))) }
        }
        return found
    }

    // Clause ids present in the source but absent from the answer, in numeric
    // order. Empty when the source is not a clause-numbered document.
    static func missingIds(source: String, answer: String) -> [String] {
        let sourceIds = ids(in: source)
        guard sourceIds.count >= minSourceIds else { return [] }
        return numericallySorted(sourceIds.subtracting(ids(in: answer))
            .filter { hasClauseNeighbor($0, in: sourceIds) })
    }

    // The reverse direction: clause ids the answer carries that the source never
    // printed — fabricated numbering (a model numbering unnumbered paragraphs or
    // extending a run past its printed end). Gated by the answer's own pool: a
    // fabricated clause id sits inside a numbered run in the answer, while a
    // date or reference artifact stands alone.
    static func inventedIds(source: String, answer: String) -> [String] {
        let sourceIds = ids(in: source)
        guard sourceIds.count >= minSourceIds else { return [] }
        let answerIds = ids(in: answer)
        return numericallySorted(answerIds.subtracting(sourceIds)
            .filter { hasClauseNeighbor($0, in: answerIds) && !containsLoosely($0, in: source) })
    }

    // The text layer sometimes splits a printed number across a line break
    // ("Ziffer 6.\n25"): id extraction misses it in the source while the model
    // correctly rejoins it in the answer. Before calling an answer id invented,
    // check the source tolerating whitespace inside the number.
    private static func containsLoosely(_ id: String, in source: String) -> Bool {
        let pattern = id.split(separator: ".").joined(separator: "\\s*\\.\\s*")
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    // Section ids under which the answer numbers paragraphs the PDF does not
    // number. A subsection labeled with a bare "1." under a multi-level section
    // "6.8" claims a printed clause 6.8.1; if the source has no such clause id,
    // or the same section already carries the explicit multi-level id, the bare
    // label is invented (observed live: unnumbered paragraphs under 6.2-6.18
    // returned as "1.", "2."). Bare ids under textual or top-level sections
    // ("§ 1", "Abschnitt 2") are the document's own printed numbering and pass.
    static func bareNumberedSections(sections: [[String: Any]], source: String) -> [String] {
        let sourceIds = ids(in: source)
        guard sourceIds.count >= minSourceIds else { return [] }
        var flagged: [String] = []
        for section in sections {
            let sid = normId(section["id"] as? String)
            let sidComps = sid.split(separator: ".")
            guard sidComps.count >= 2, sidComps.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { continue }
            let subs = (section["subsections"] as? [[String: Any]]) ?? []
            let explicit = Set(subs.map { normId($0["id"] as? String) })
            for sub in subs {
                let subID = normId(sub["id"] as? String)
                guard subID.count <= 2, !subID.isEmpty, subID.allSatisfy(\.isNumber) else { continue }
                // Printed inline enumerations ("... durch: 1. Krieg; 2. Kern-
                // energie") keep their numbers adjacent to their text in the
                // text layer; only clause ids live in the decoupled number
                // column. A bare label whose number the source prints right
                // before the paragraph text is the document's own numbering.
                if sourceShowsNumber(subID, before: (sub["content"] as? String) ?? "", in: source) { continue }
                let composite = "\(sid).\(subID)"
                if !sourceIds.contains(composite) || explicit.contains(composite) {
                    if !flagged.contains(sid) { flagged.append(sid) }
                    break
                }
            }
        }
        return flagged
    }

    // True when the source contains "<n>." directly followed by the start of
    // the given paragraph text (whitespace, soft hyphens, and line-break
    // hyphenation tolerated between characters). Too little text to judge
    // counts as printed: never flag on weak evidence.
    private static func sourceShowsNumber(_ n: String, before content: String, in source: String) -> Bool {
        // 24 matched characters, because German legal prose reuses openings:
        // a 12-char key let the cross-reference "nach Teil B Abschnitt 3
        // Ziffer 1. ausgeschlossen." vouch for every paragraph starting
        // "Ausgeschlossen sind..." (observed on the AHB). The gap class
        // absorbs whitespace and punctuation between words; letters and
        // digits stay hard anchors.
        let key = content.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(24)
        guard key.count >= 4 else { return true }
        let gap = "[\\s\u{00AD}\\-.,;:()'\"„“/]*"
        // The lookbehind keeps a longer clause id's tail from counting: in
        // "6.9.1. Versichert ist..." the "1." belongs to 6.9.1, and must not
        // vouch for a bare "1." elsewhere that starts with the same words.
        let pattern = "(?<![0-9.,])" + NSRegularExpression.escapedPattern(for: n) + "[.)]?" + gap
            + key.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: gap)
        return source.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func numericallySorted<S: Sequence>(_ ids: S) -> [String] where S.Element == String {
        ids.sorted { a, b in
            let ac = a.split(separator: ".").map { Int($0) ?? 0 }
            let bc = b.split(separator: ".").map { Int($0) ?? 0 }
            return ac.lexicographicallyPrecedes(bc)
        }
    }

    // Real clauses live in numbered runs, so a real clause id has a numeric
    // neighbor somewhere in the document: a predecessor or successor with the
    // same prefix (6.15.2.4 next to 6.15.2.3), or its own parent id (6.7.1
    // under 6.7). A number with no such context (a footer date "zum 31.12.",
    // a dotted phone fragment) is an artifact — reporting it as a missing
    // clause would be a false alarm and burn a pointless re-ask.
    static func hasClauseNeighbor(_ id: String, in pool: Set<String>) -> Bool {
        let comps = id.split(separator: ".").map { Int($0) ?? 0 }
        guard let last = comps.last else { return false }
        let prefix = comps.dropLast().map(String.init)
        func sibling(_ n: Int) -> String { (prefix + [String(n)]).joined(separator: ".") }
        if last > 1, pool.contains(sibling(last - 1)) { return true }
        if pool.contains(sibling(last + 1)) { return true }
        // First child of a multi-level parent: the parent id is its context.
        if prefix.count >= 2, pool.contains(prefix.joined(separator: ".")) { return true }
        return false
    }

    // PDF page numbers (1-based) whose text mentions one of the missing ids,
    // each with its successor page (a clause's number can sit at the end of a
    // column while its body flows onto the next page). Capped: page images are
    // ~1 MB each and the re-ask must stay well under request size limits.
    static let maxRetryImages = 4

    static func pdfPageNumbers(missing: [String], pageTexts: [String]) -> [Int] {
        // The table of contents repeats most clause numbers, so TOC pages would
        // fill the image cap before the body pages the extraction actually
        // needs. Prefer non-TOC pages; fall back to all pages only when the ids
        // appear nowhere else.
        let preferred = collectPages(missing: missing, pageTexts: pageTexts, skipTOC: true)
        return preferred.isEmpty ? collectPages(missing: missing, pageTexts: pageTexts, skipTOC: false) : preferred
    }

    // First body page (non-TOC when possible) that mentions each id, for the
    // user-facing warning: "1.5" alone is unfindable in a document whose
    // Abschnitte each restart numbering at 1, "1.5 (PDF page 15)" is one flip.
    static func pageLocations(ids missing: [String], pageTexts: [String]) -> [String: Int] {
        var locations: [String: Int] = [:]
        for skipTOC in [true, false] {
            for text in pageTexts {
                guard let page = pageNumber(fromMarker: text) else { continue }
                if skipTOC, text.localizedCaseInsensitiveContains("Inhaltsverzeichnis") { continue }
                let pageIds = ids(in: text)
                for id in missing where locations[id] == nil && pageIds.contains(id) {
                    locations[id] = page
                }
            }
            if locations.count == missing.count { break }
        }
        return locations
    }

    private static func collectPages(missing: [String], pageTexts: [String], skipTOC: Bool) -> [Int] {
        let missingSet = Set(missing)
        var result: [Int] = []
        for (i, text) in pageTexts.enumerated() where !ids(in: text).isDisjoint(with: missingSet) {
            if skipTOC, text.localizedCaseInsensitiveContains("Inhaltsverzeichnis") { continue }
            for candidate in [pageNumber(fromMarker: text),
                              i + 1 < pageTexts.count ? pageNumber(fromMarker: pageTexts[i + 1]) : nil] {
                if let n = candidate, !result.contains(n), result.count < maxRetryImages {
                    result.append(n)
                }
            }
        }
        return result.sorted()
    }

    // Defends the splice against a sloppy vision answer: drops items with empty
    // id/content or a foreign top-level number (page images can show the next
    // section too), and strips an item's own id repeated at the start of its
    // content (the vision model often transcribes the printed number into the
    // text; the leftover prefix breaks the splice's content fingerprints and
    // would render doubled, "**1.1.** 1.1. Die...").
    //
    // Duplicate ids usually mean the images showed TWO runs with the same top-
    // level number (Abschnitte restart numbering at 1, and one page can show
    // the end of one Abschnitt and the start of the next). When mustContain
    // names the ids being recovered, the run is split at each id repeat and the
    // one segment holding all of them wins; with no way to choose, nil.
    static func sanitizeRun(_ run: [[String: Any]], prefix: String, mustContain: [String] = []) -> [[String: Any]]? {
        let cleaned: [[String: Any]] = run.compactMap { item in
            var item = item
            let id = normId(item["id"] as? String)
            guard firstComponent(item["id"] as? String) == prefix, !id.isEmpty else { return nil }
            let content = stripLeadingId((item["content"] as? String) ?? "", id: id)
            guard !content.isEmpty else { return nil }
            item["content"] = content
            return item
        }
        let ids = cleaned.map { normId($0["id"] as? String) }
        guard cleaned.count >= 2 else { return nil }
        if Set(ids).count == ids.count { return cleaned }
        var segments: [[[String: Any]]] = [[]]
        var seen = Set<String>()
        for (item, id) in zip(cleaned, ids) {
            if seen.contains(id) {
                segments.append([])
                seen = []
            }
            segments[segments.count - 1].append(item)
            seen.insert(id)
        }
        let wanted = Set(mustContain)
        guard !wanted.isEmpty else { return nil }
        let candidates = segments.filter { segment in
            let segmentIds = Set(segment.map { normId($0["id"] as? String) })
            return wanted.allSatisfy { segmentIds.contains($0) }
        }
        guard candidates.count == 1, let winner = candidates.first, winner.count >= 2 else { return nil }
        return winner
    }

    // "1.1. Die Vertragsdauer..." under id "1.1" -> "Die Vertragsdauer...".
    // A digit right after the id's dot is an amount, not a label ("2.500 Euro"
    // under id "2"), and is left alone. The separator may be any whitespace
    // (vision answers use tabs, newlines, and non-breaking spaces); content
    // that is nothing but its own number strips to empty and gets dropped.
    private static func stripLeadingId(_ content: String, id: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, trimmed.hasPrefix(id) else { return trimmed }
        var rest = String(trimmed.dropFirst(id.count))
        guard let first = rest.first else { return "" }
        if first == "." {
            rest.removeFirst()
            if let next = rest.first, next.isNumber { return trimmed }
        } else if !first.isWhitespace {
            return trimmed
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Parses the "--- Seite N von M ---" header Converter.extractPages prepends.
    // Needed because empty PDF pages are skipped: the array index of a page text
    // is not its PDF page number.
    static func pageNumber(fromMarker text: String) -> Int? {
        guard text.hasPrefix("--- Seite ") else { return nil }
        return Int(text.dropFirst("--- Seite ".count).prefix(while: { $0.isNumber }))
    }

    // Replaces a misbound clause run in the parsed answer with the
    // vision-corrected one. The window to replace is found by CONTENT overlap,
    // not by id (the ids are exactly what is wrong), and constrained to a
    // contiguous block of subsections sharing the run's top-level number, so a
    // document with several "1.x" runs (one per Abschnitt) splices the right
    // one. Within that block, only the sub-range whose contents the run
    // actually matched is replaced: the run comes from a page-capped image
    // extraction and may cover just a slice of a wide section (all of "6.x" is
    // 100+ clauses over many pages) — replacing the whole block would delete
    // every clause the images never showed. Returns nil when no confident
    // window exists; the caller then keeps the original answer and warns.
    static func splice(run: [[String: Any]], intoSections sections: [[String: Any]], runPrefix: String) -> [[String: Any]]? {
        let runKeys = run.compactMap { norm($0["content"] as? String) }
        guard runKeys.count >= 2 else { return nil }
        func matches(_ a: String, _ b: String) -> Bool { a.hasPrefix(b) || b.hasPrefix(a) }
        var best: (section: Int, range: Range<Int>, score: Int)?
        for (si, section) in sections.enumerated() {
            // The front-matter TOC repeats every clause number with title-like
            // text; never treat it as the body window.
            let sectionLabel = "\((section["id"] as? String) ?? "") \((section["title"] as? String) ?? "")"
            if sectionLabel.localizedCaseInsensitiveContains("Inhaltsverzeichnis") { continue }
            let subs = (section["subsections"] as? [[String: Any]]) ?? []
            var i = 0
            while i < subs.count {
                guard firstComponent(subs[i]["id"] as? String) == runPrefix else { i += 1; continue }
                var j = i
                while j < subs.count, firstComponent(subs[j]["id"] as? String) == runPrefix { j += 1 }
                // Indices inside the block whose content matches some run item.
                var matched: [Int] = []
                for k in i..<j {
                    guard let wk = norm(subs[k]["content"] as? String) else { continue }
                    if runKeys.contains(where: { matches($0, wk) }) { matched.append(k) }
                }
                if matched.count >= 2, var lo = matched.first, var hi = matched.last,
                   matched.count > (best?.score ?? 0) {
                    // Extend over adjacent items whose id the run also carries but
                    // whose content did not match (that mismatch is the misbinding
                    // being fixed); without this, a differently-phrased boundary
                    // item survives next to its replacement as a duplicate.
                    let runIdSet = Set(run.compactMap { normId($0["id"] as? String) }).subtracting([""])
                    while lo - 1 >= i, runIdSet.contains(normId(subs[lo - 1]["id"] as? String)) { lo -= 1 }
                    while hi + 1 < j, runIdSet.contains(normId(subs[hi + 1]["id"] as? String)) { hi += 1 }
                    best = (si, lo..<(hi + 1), matched.count)
                }
                i = j
            }
        }
        guard let best else { return nil }
        var out = sections
        var section = out[best.section]
        var subs = (section["subsections"] as? [[String: Any]]) ?? []
        subs.replaceSubrange(best.range, with: run)
        section["subsections"] = subs
        out[best.section] = section
        return out
    }

    private static func firstComponent(_ id: String?) -> String {
        normId(id).split(separator: ".").first.map(String.init) ?? ""
    }

    private static func normId(_ id: String?) -> String {
        (id ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    // Content fingerprint robust against the PDF's line-break hyphenation and
    // whitespace differences: alphanumerics only, first 48 scalars.
    private static func norm(_ s: String?) -> String? {
        guard let s else { return nil }
        let key = String(String.UnicodeScalarView(
            s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        ).prefix(48))
        return key.count >= 12 ? key : nil
    }

    // User-facing warning; nil when nothing is wrong. Each id carries its PDF
    // page so the user can actually find it (Abschnitte restart numbering, so a
    // bare "1.5" is ambiguous in the printed document).
    static func warning(missing: [String],
                        invented: [String] = [],
                        bareSections: [String] = [],
                        pageTexts: [String] = []) -> String? {
        let locations = pageLocations(ids: missing + invented, pageTexts: pageTexts)
        func list(_ ids: [String]) -> String {
            let shown = ids.prefix(10)
                .map { id in locations[id].map { "\(id) (PDF page \($0))" } ?? id }
                .joined(separator: ", ")
            return ids.count > 10 ? "\(shown) and \(ids.count - 10) more" : shown
        }
        var parts: [String] = []
        if !missing.isEmpty {
            parts.append("Clause number\(missing.count == 1 ? "" : "s") \(list(missing)) appear\(missing.count == 1 ? "s" : "") in the PDF but not in the result. The content may be missing, or it may sit under a shifted number nearby.")
        }
        if !invented.isEmpty {
            parts.append("The result contains clause number\(invented.count == 1 ? "" : "s") \(list(invented)) that the PDF does not print; the numbering there may be invented.")
        }
        if !bareSections.isEmpty {
            let shown = bareSections.prefix(8).joined(separator: ", ")
            let more = bareSections.count > 8 ? " and \(bareSections.count - 8) more" : ""
            parts.append("Under section\(bareSections.count == 1 ? "" : "s") \(shown)\(more) the result numbers paragraphs that carry no printed number in the PDF.")
        }
        guard !parts.isEmpty else { return nil }
        parts.append("Compare those parts against the PDF, or re-drop the file to convert again.")
        return parts.joined(separator: " ")
    }
}
