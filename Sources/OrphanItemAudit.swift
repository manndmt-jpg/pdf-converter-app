import Foundation

// The enumeration-item backstop. Models nondeterministically drop or
// label-less-merge printed enumeration items ("c. …", "(iii) …") — most often
// the item whose text starts a PDF page (three consecutive live runs of one
// document: dropped / fused into "b." / promoted to its own heading), but also
// whole mid-page runs ((ii)–(v) of a clause vanished in a live run that scored
// 100% on the numeric clause audit). Numeric ids are covered by ClauseAudit;
// letter/roman items are invisible to it. This audit closes that gap
// deterministically:
//
// The text layer prints an enumeration item's label at the START of its own
// text line ("c. einer bisher…") — the reliable adjacency case (only clause
// ids live in a decoupled number column; a lone label line is NOT treated as
// an item). Every such item is verified against the parsed answer:
//
//   present + labeled (own subsection or inline enumerator)  -> untouched
//   present but fused label-less into another item           -> split + label
//   absent                                                   -> re-inserted
//        verbatim after the preceding item (anchored by content fingerprint;
//        never into a section that already carries the item's id — sibling
//        sections can share word-identical items, e.g. 1.1 b. == 1.2 b.)
//   absent and no safe anchor                                -> reported, the
//                                                                caller warns
//
// Repairs only ever re-cut or re-insert the document's own printed text —
// never paraphrase, never delete. Verification is conservative: items whose
// opening words are not distinctive enough to fingerprint are skipped rather
// than guessed. Foundation-only and standalone-compilable (same rule as
// ClauseAudit); compile it together with ClauseAudit.swift.
enum OrphanItemAudit {
    struct Item {
        let token: String       // as printed: "c." or "(ii)"
        let id: String          // subsection id form: "c" or "(ii)"
        let text: String        // the item's text, reflowed
        let page: Int           // PDF page number (from the page marker)
        let anchorKey: String?  // fingerprint of the preceding item's text
        let anchorId: String?   // the preceding item's id, for disambiguation
    }

    // Enumerator at line start: "c. ", "aa. ", "(i) ", "(2) ". The lookahead
    // demands whitespace so abbreviations with a letter directly after the dot
    // ("z.B.") never match.
    private static let enumeratorPattern = try! NSRegularExpression(
        pattern: "^(?:([a-z]{1,2})\\.|\\(([ivxlcdm]+|[a-z]{1,2}|[0-9]{1,2})\\))(?=\\s)")

    // A numeric clause id or heading at line start ends an item's text.
    private static let clauseStartPattern = try! NSRegularExpression(
        pattern: "^[0-9]{1,2}(?:\\.[0-9]{1,2})*\\.?(?:\\s|$)")

    // An enumerator line must carry a real chunk of its own text on the SAME
    // line; a bare label line is the decoupled number column of a two-column
    // PDF, where label→text pairing is exactly what cannot be trusted.
    private static let minSameLineChars = 8

    // `pages` carry the "--- Seite N von M ---" markers Converter prepends.
    static func items(pages: [String]) -> [Item] {
        struct Raw {
            let token: String, id: String, page: Int
            var lines: [Substring]
        }
        var raws: [Raw] = []
        for page in pages {
            guard let pageNo = ClauseAudit.pageNumber(fromMarker: page) else { continue }
            // An item's captured text ends at its page's end: fingerprints only
            // need the opening words, and a cross-page continuation would need
            // exactly the label-less pairing this audit refuses to guess at.
            var currentOpen = false   // collecting lines of the item raws.last
            for line in page.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if let match = enumeratorMatch(line) {
                    raws.append(Raw(token: match.token, id: match.id, page: pageNo,
                                    lines: [line.dropFirst(match.tokenLength)]))
                    currentOpen = true
                } else if isClauseStart(trimmed) {
                    currentOpen = false
                } else if currentOpen {
                    raws[raws.count - 1].lines.append(line)
                }
            }
        }
        var items: [Item] = []
        for (i, raw) in raws.enumerated() {
            let text = reflow(raw.lines)
            guard fingerprint(text) != nil else { continue }   // not distinctive enough
            var anchorKey: String?
            var anchorId: String?
            if i > 0 {
                let prev = raws[i - 1]
                anchorKey = fingerprint(reflow(prev.lines))
                anchorId = prev.id
            }
            items.append(Item(token: raw.token, id: raw.id, text: text, page: raw.page,
                              anchorKey: anchorKey, anchorId: anchorId))
        }
        return items
    }

    // Verifies each item against the parsed sections and repairs what it can.
    // Returns the (possibly) repaired sections and the items it could neither
    // find nor place — the caller surfaces those in the user-facing warning.
    static func repair(sections: [[String: Any]], items: [Item]) -> (sections: [[String: Any]], unresolved: [Item]) {
        var sections = sections
        var unresolved: [Item] = []
        var cache = normalizedCache(sections)
        for item in items {
            guard let key = fingerprint(item.text) else { continue }
            let hits = cache.filter { $0.norm.contains(key) }
            if !hits.isEmpty {
                // Fingerprints are opening-words prefixes, and German legal
                // boilerplate reuses openings (the front-matter "Alle für den
                // Versicherer…" shares its first 32 characters with clause
                // 10.8 a., observed live). The item counts as present if ANY
                // hit carries its label — only then is repairing wrong.
                let idHits = hits.filter { hit in
                    normId(subsection(sections, (hit.section, hit.sub))["id"]).caseInsensitiveCompare(item.id) == .orderedSame
                }
                if !idHits.isEmpty {
                    // One exception, observed live: the labeled item sits as
                    // the FIRST subsection of the FOLLOWING section, ahead of
                    // that section's own "a." (a page-break misfile: "c." under
                    // Ziffer 1.3 instead of at the end of 1.2). That exact
                    // signature — first sub, letter beyond "a", directly
                    // followed by "a" — is moved back after its anchor. Any
                    // other labeled placement stands.
                    let misfiled = idHits.filter { hit in
                        guard hit.sub == 0, item.id.count == 1, item.id != "a",
                              item.id.first?.isLetter == true else { return false }
                        let subs = subsections(sections, hit.section)
                        guard subs.count > 1 else { return false }
                        if normId(subs[1]["id"]) == "a" { return true }
                        // The section's own "a." can also arrive as unlabeled
                        // content ("a. des Versicherungsnehmers…") — same
                        // misfile, different rendering of the alphabet start.
                        let next = ((subs[1]["content"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                        return next.range(of: "^a[.)]\\s", options: .regularExpression) != nil
                    }
                    if misfiled.count == idHits.count, let hit = misfiled.first,
                       let anchorKey = item.anchorKey,
                       let target = insertionTarget(for: item, anchorKey: anchorKey, in: sections, cache: cache),
                       target.section != hit.section {
                        let moved = subsection(sections, (hit.section, hit.sub))
                        removeSubsection(&sections, (hit.section, hit.sub))
                        insertSubsection(&sections, after: (target.section, target.sub), moved)
                        cache = normalizedCache(sections)
                    }
                    continue
                }
                if hits.contains(where: { hit in
                    showsToken(item, in: (subsection(sections, (hit.section, hit.sub))["content"] as? String) ?? "")
                }) { continue }   // inline enumerator preserved
                // The verbatim front-matter block (empty section id and title)
                // is prose, never a fused enumeration item — a collision there
                // must not relabel it.
                guard let hit = hits.first(where: { !isFrontMatter(sections[$0.section]) }) else { continue }
                let sub = subsection(sections, (hit.section, hit.sub))
                let subId = normId(sub["id"])
                let content = (sub["content"] as? String) ?? ""
                // Present but fused into another item without its label: split
                // the containing content at the item's start and label the tail.
                guard let cut = originalIndex(ofNormalizedKey: key, in: content) else { continue }
                let before = String(content[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
                let after = String(content[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !after.isEmpty else { continue }
                if before.isEmpty {
                    // The whole subsection IS the item; claim it only if it has
                    // no competing label of its own (identical openings across
                    // sibling items land here and must stay untouched).
                    if subId.isEmpty {
                        setSubsection(&sections, (hit.section, hit.sub), ["id": item.id, "content": after])
                        cache = normalizedCache(sections)
                    }
                    continue
                }
                var mutated = sub
                mutated["content"] = before
                setSubsection(&sections, (hit.section, hit.sub), mutated)
                insertSubsection(&sections, after: (hit.section, hit.sub), ["id": item.id, "content": after])
                cache = normalizedCache(sections)
            } else if let anchorKey = item.anchorKey,
                      let target = insertionTarget(for: item, anchorKey: anchorKey, in: sections, cache: cache) {
                insertSubsection(&sections, after: (target.section, target.sub), ["id": item.id, "content": item.text])
                cache = normalizedCache(sections)
            } else {
                unresolved.append(item)
            }
        }
        return (sections, unresolved)
    }

    // The verbatim front-matter block is ALSO dropped nondeterministically
    // (two of three consecutive live runs of one document lost the entire
    // Versicherer/Alteos block despite the prompt). Deterministic recovery:
    // locate where the answer's first body content starts in the source
    // pages; the prose lines directly before that point (skipping the body's
    // own heading lines) are the leading front matter. Any of it missing from
    // the answer is restored verbatim into the leading front-matter section.
    // TOC lines exclude themselves: the walk backwards stops at the first
    // digit-only or empty line (the TOC's page-number column).
    static func recoverLeadingFrontMatter(sections: [[String: Any]], pages: [String]) -> [[String: Any]] {
        let anchorKey = sections.drop(while: { isFrontMatter($0) })
            .lazy
            .flatMap { ($0["subsections"] as? [[String: Any]]) ?? [] }
            .compactMap { fingerprint(($0["content"] as? String) ?? "") }
            .first
        guard let anchorKey,
              let page = pages.first(where: { normalized($0).contains(anchorKey) }),
              let cut = originalIndex(ofNormalizedKey: anchorKey, in: page)
        else { return sections }
        var lines = String(page[..<cut]).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Walk back over the body's own heading lines (clause number + title),
        // then collect the contiguous prose run above them.
        while let last = lines.last, last.isEmpty || isClauseStart(last) { lines.removeLast() }
        var prose: [String] = []
        while let last = lines.last, !last.isEmpty, !last.allSatisfy(\.isNumber),
              !isClauseStart(last), !last.hasPrefix("--- Seite"),
              last.count >= 25 || !prose.isEmpty && last.count >= 10 {
            prose.insert(last, at: 0)
            lines.removeLast()
        }
        guard !prose.isEmpty else { return sections }
        // Paragraph boundaries: sentence end + uppercase start.
        var paragraphs: [[Substring]] = [[]]
        for line in prose {
            if let prev = paragraphs.last?.last, prev.hasSuffix("."),
               let first = line.first, first.isUppercase {
                paragraphs.append([])
            }
            paragraphs[paragraphs.count - 1].append(Substring(line))
        }
        let answerNorm = sections.flatMap { section in
            (((section["subsections"] as? [[String: Any]]) ?? []).map { normalized(($0["content"] as? String) ?? "") })
        }.joined(separator: "\n")
        let missing: [[String: Any]] = paragraphs.compactMap { block in
            let text = reflow(block)
            // Presence needs a LONGER key than the item audit's 32: German
            // boilerplate reuses openings well past that (the front-matter
            // "Alle für den Versicherer bestimmten Anzeigen und Erklärungen…"
            // matches clause 10.8 a. for its first 53 characters, live).
            let key = String(normalized(text).prefix(64))
            guard key.count >= 24, text.count >= 40, !answerNorm.contains(key) else { return nil }
            return ["id": "", "content": text]
        }
        guard !missing.isEmpty else { return sections }
        var sections = sections
        if let fmIdx = sections.firstIndex(where: { isFrontMatter($0) }) {
            var fm = sections[fmIdx]
            fm["subsections"] = (((fm["subsections"] as? [[String: Any]]) ?? []) + missing)
            sections[fmIdx] = fm
        } else {
            sections.insert(["id": "", "title": "", "subsections": missing], at: 0)
        }
        return sections
    }

    // Where a missing/misfiled item belongs: after the subsection holding the
    // preceding item's text. Sibling sections can carry word-identical items
    // (1.1 b. == 1.2 b., observed live), so a hit inside a section that
    // ALREADY has this item's id is the wrong enumeration; prefer an anchor
    // whose own id matches the source's preceding item.
    private static func insertionTarget(for item: Item, anchorKey: String,
                                        in sections: [[String: Any]],
                                        cache: [CacheEntry]) -> (section: Int, sub: Int)? {
        let viable = cache.filter { hit in
            hit.norm.contains(anchorKey)
                && !subsections(sections, hit.section).contains { normId($0["id"]).caseInsensitiveCompare(item.id) == .orderedSame }
        }
        let preferred = viable.filter { hit in
            guard let anchorId = item.anchorId else { return true }
            return normId(subsection(sections, (hit.section, hit.sub))["id"]).caseInsensitiveCompare(anchorId) == .orderedSame
        }
        return (preferred.last ?? viable.last).map { ($0.section, $0.sub) }
    }

    // MARK: - Matching

    private static func enumeratorMatch(_ line: Substring) -> (token: String, id: String, tokenLength: Int)? {
        let s = String(line)
        let ns = s as NSString
        guard let m = enumeratorPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let rest = ns.substring(from: m.range.length).trimmingCharacters(in: .whitespaces)
        guard rest.count >= minSameLineChars else { return nil }
        let token = ns.substring(with: m.range)
        let id = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : token
        return (token, id, m.range.length)
    }

    private static func isClauseStart(_ trimmed: String) -> Bool {
        let ns = trimmed as NSString
        return clauseStartPattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil
    }

    // True when the content itself carries the item's enumerator directly
    // before the item's opening words ("… ausschließlich (i) an Wohnräumen") —
    // the inline form some documents print mid-sentence. Nothing to repair.
    private static func showsToken(_ item: Item, in content: String) -> Bool {
        let opening = item.text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(16)
        guard opening.count >= 8 else { return false }
        let gap = "[\\s\u{00AD}\\-.,;:()'\"„“/*]*"
        let pattern = NSRegularExpression.escapedPattern(for: item.token) + gap
            + opening.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: gap)
        return content.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Normalized search

    static func fingerprint(_ s: String) -> String? {
        let key = String(String.UnicodeScalarView(
            s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        ).prefix(32))
        return key.count >= 12 ? key : nil
    }

    private static func normalized(_ s: String) -> String {
        String(String.UnicodeScalarView(
            s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private static func normId(_ id: Any?) -> String {
        ((id as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    private static func isFrontMatter(_ section: [String: Any]) -> Bool {
        normId(section["id"]).isEmpty
            && ((section["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private struct CacheEntry { let section: Int, sub: Int; let norm: String }

    private static func normalizedCache(_ sections: [[String: Any]]) -> [CacheEntry] {
        var cache: [CacheEntry] = []
        for (si, section) in sections.enumerated() {
            for (ji, sub) in ((section["subsections"] as? [[String: Any]]) ?? []).enumerated() {
                cache.append(CacheEntry(section: si, sub: ji, norm: normalized((sub["content"] as? String) ?? "")))
            }
        }
        return cache
    }

    // Original string index where the normalized form of `content` starts
    // matching `key` — the split point for a fused item.
    private static func originalIndex(ofNormalizedKey key: String, in content: String) -> String.Index? {
        var map: [String.Index] = []
        var norm = ""
        for i in content.indices {
            for scalar in String(content[i]).lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
                norm.unicodeScalars.append(scalar)
                map.append(i)
            }
        }
        guard let range = norm.range(of: key) else { return nil }
        let offset = norm.distance(from: norm.startIndex, to: range.lowerBound)
        return offset < map.count ? map[offset] : nil
    }

    // Rejoin the text layer's hard line wraps: a hyphen between two lowercase
    // letters at a wrap is a line-break hyphen ("Vor-\nbereitung"); everything
    // else joins with a single space.
    private static func reflow(_ lines: [Substring]) -> String {
        let joined = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return joined
            .replacingOccurrences(of: "([a-zäöüß])-\\s*\n\\s*([a-zäöüß])", with: "$1$2", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\n\\s*", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Section surgery

    private static func subsections(_ sections: [[String: Any]], _ si: Int) -> [[String: Any]] {
        (sections[si]["subsections"] as? [[String: Any]]) ?? []
    }

    private static func subsection(_ sections: [[String: Any]], _ hit: (section: Int, sub: Int)) -> [String: Any] {
        subsections(sections, hit.section)[hit.sub]
    }

    private static func setSubsection(_ sections: inout [[String: Any]], _ hit: (section: Int, sub: Int), _ value: [String: Any]) {
        var section = sections[hit.section]
        var subs = (section["subsections"] as? [[String: Any]]) ?? []
        subs[hit.sub] = value
        section["subsections"] = subs
        sections[hit.section] = section
    }

    private static func insertSubsection(_ sections: inout [[String: Any]], after hit: (section: Int, sub: Int), _ value: [String: Any]) {
        var section = sections[hit.section]
        var subs = (section["subsections"] as? [[String: Any]]) ?? []
        subs.insert(value, at: hit.sub + 1)
        section["subsections"] = subs
        sections[hit.section] = section
    }

    private static func removeSubsection(_ sections: inout [[String: Any]], _ hit: (section: Int, sub: Int)) {
        var section = sections[hit.section]
        var subs = (section["subsections"] as? [[String: Any]]) ?? []
        subs.remove(at: hit.sub)
        section["subsections"] = subs
        sections[hit.section] = section
    }
}
