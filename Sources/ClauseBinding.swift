import Foundation

// Repairs the number-to-paragraph binding of a parsed answer using anchors read
// from the printed pages. The text layer of two-column PDFs decouples clause
// numbers from their paragraphs, so a model can return an answer whose id
// inventory is complete while whole runs are SHIFTED: an unnumbered lead-in
// absorbed as the next clause, everything after off by one, clauses merged at
// the end to make the count fit (observed live: 2.8 content under 2.10, 8.6+8.7
// fused, every 1.1-1.5 of a Teil B Abschnitt wrong). No id-set audit can see
// this. What the page images give us cheaply is an authoritative list of
// (clause number, first words of its paragraph) pairs — the ONLY extraction
// task the vision model has been live-verified to bind correctly.
//
// The rebinder never asks the model to re-transcribe content. It re-CUTS the
// answer's own text: within a numbering block, locate each anchor's first
// words, then reassign the text between consecutive anchors to that anchor's
// clause number. Text before the first anchor becomes an unnumbered intro.
// By construction no text is lost or added — only the labels move.
//
// Foundation-only and standalone-compilable (same rule as ClauseAudit) so
// scratch harnesses can test it against real misbound answers.
enum ClauseBinding {
    struct Anchor {
        let id: String
        let start: String
    }

    // Anchors need enough text to be located unambiguously. Shorter starts
    // (headings like "Ausschlüsse") are matched only against paragraph starts.
    static let minSubstringKey = 12
    static let minBoundaryKey = 6

    // Applies anchors to every section; returns the updated sections and how
    // many blocks were re-cut. Sections whose binding already matches their
    // anchors come back unchanged (re-cutting at identical boundaries is a
    // no-op by construction, but we skip early for clarity of the count).
    static func rebind(sections: [[String: Any]], anchors: [Anchor]) -> (sections: [[String: Any]], reboundBlocks: Int) {
        var out = sections
        var rebound = 0
        for (si, section) in sections.enumerated() {
            let label = "\((section["id"] as? String) ?? "") \((section["title"] as? String) ?? "")"
            if label.localizedCaseInsensitiveContains("Inhaltsverzeichnis") { continue }
            let subs = (section["subsections"] as? [[String: Any]]) ?? []
            guard subs.count >= 2 else { continue }
            var newSubs: [[String: Any]] = []
            var changed = false
            for block in blocks(of: subs) {
                if let recut = recut(block: block, anchors: anchors) {
                    newSubs += recut
                    changed = true
                } else {
                    // A model sometimes returns a whole document part as ONE
                    // section, making the block span every clause family; a
                    // single unmatched anchor would then veto every repair.
                    // Degrade to per-family segments (one top-level clause
                    // number each) so families with complete anchors are fixed
                    // and only the incomplete ones stay untouched.
                    for segment in familySegments(of: block) {
                        if let recut = recut(block: segment, anchors: anchors) {
                            newSubs += recut
                            changed = true
                        } else {
                            newSubs += segment
                        }
                    }
                }
            }
            if changed {
                var s = out[si]
                s["subsections"] = newSubs
                out[si] = s
                rebound += 1
            }
        }
        return (out, rebound)
    }

    // Splits a section's subsections into blocks at numbering restarts: ids
    // ascend within one printed run (1., 1.1, 1.2, 2., 2.1 ...), so a numeric
    // non-increase means a new family starts (the ROLAND conditions embedded
    // under clause 8 restart at 1.). Unnumbered/textual subsections are
    // continuation content; the ones TRAILING a block move into the following
    // block, because a misbound answer often carries the next run's first
    // clause as an unnumbered paragraph (observed live: print's Stichentscheid
    // clause 1 unnumbered before a mislabeled 1./2./3. run) — the re-cut can
    // only reclaim it if it is part of the new block's stream. If such text
    // really belonged to the previous clause it ends up as the new block's
    // unnumbered intro, which renders at the same document position.
    static func blocks(of subs: [[String: Any]]) -> [[[String: Any]]] {
        var result: [[[String: Any]]] = []
        var current: [[String: Any]] = []
        var lastNumeric: [Int]?
        for sub in subs {
            if let comps = numericComps(sub["id"] as? String) {
                if let last = lastNumeric, !last.lexicographicallyPrecedes(comps) {
                    let carried = trailingUnnumbered(of: current)
                    let head = current.dropLast(carried.count)
                    if !head.isEmpty { result.append(Array(head)) }
                    current = carried
                }
                lastNumeric = comps
            }
            current.append(sub)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func trailingUnnumbered(of block: [[String: Any]]) -> [[String: Any]] {
        var trailing: [[String: Any]] = []
        for sub in block.reversed() {
            if numericComps(sub["id"] as? String) != nil { break }
            trailing.insert(sub, at: 0)
        }
        return trailing
    }

    // Splits a block at each change of the ids' first component: "1., 1.1,
    // 1.2, 2., 2.1" becomes the 1-family and the 2-family. Unnumbered and
    // textual subsections stay with the family they follow.
    static func familySegments(of block: [[String: Any]]) -> [[[String: Any]]] {
        var result: [[[String: Any]]] = []
        var current: [[String: Any]] = []
        var lastFamily: Int?
        for sub in block {
            if let family = numericComps(sub["id"] as? String)?.first {
                if let last = lastFamily, family != last, !current.isEmpty {
                    let carried = trailingUnnumbered(of: current)
                    let head = current.dropLast(carried.count)
                    if !head.isEmpty { result.append(Array(head)) }
                    current = carried
                }
                lastFamily = family
            }
            current.append(sub)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // Re-cuts one block against the anchors, or nil to leave it unchanged.
    private static func recut(block: [[String: Any]], anchors: [Anchor]) -> [[String: Any]]? {
        let blockIds = block.compactMap { sub -> [Int]? in numericComps(sub["id"] as? String) }
        guard blockIds.count >= 2 else { return nil }
        let families = Set(blockIds.compactMap(\.first))

        // Candidates: anchors of this block's numbering families, in numeric
        // order (the printed order within a run). Page-level anchor order is
        // column-interleaved and cannot be trusted; equal ids (Abschnitte
        // restarting at 1) keep their page order and are disambiguated by
        // whether their first words exist in this block's text at all.
        let candidates = anchors
            .compactMap { a -> (comps: [Int], anchor: Anchor)? in
                guard let comps = numericComps(a.id), let f = comps.first, families.contains(f) else { return nil }
                return (comps, a)
            }
            .enumerated()
            .sorted { l, r in
                l.element.comps == r.element.comps
                    ? l.offset < r.offset
                    : l.element.comps.lexicographicallyPrecedes(r.element.comps)
            }
            .map(\.element)
        guard candidates.count >= 2 else { return nil }

        let raw = block.map { (($0["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let (normChars, map) = normMap(raw)
        let paragraphStarts = paragraphStartNormPositions(block: block)

        // Locate each candidate with an advancing cursor: consecutive clauses
        // with identical first words (2.1.4/2.1.5) find consecutive
        // occurrences; anchors from another Abschnitt simply are not found and
        // drop out. Positions ascend by construction.
        var matched: [(comps: [Int], id: String, pos: Int)] = []
        var cursor = 0
        for c in candidates {
            let key = normKey(c.anchor.start)
            let pos: Int?
            if key.count >= minSubstringKey {
                pos = find(key, in: normChars, from: cursor)
            } else if key.count >= minBoundaryKey {
                pos = paragraphStarts.first { $0 >= cursor && normChars[$0...].starts(with: key) }
            } else {
                pos = nil
            }
            if let pos {
                matched.append((c.comps, normId(c.anchor.id), pos))
                cursor = pos + 1
            }
        }

        // Guards, all-or-nothing per block:
        // - at least two anchors located;
        // - id order equals position order (content order must match printed
        //   numbering order, else something is too wrong to fix mechanically);
        // - every numeric id the block currently carries is re-anchored, so a
        //   re-cut can never silently drop a claimed clause number.
        guard matched.count >= 2 else { return nil }
        for (a, b) in zip(matched, matched.dropFirst()) {
            guard a.comps.lexicographicallyPrecedes(b.comps) else { return nil }
        }
        let matchedIds = Set(matched.map(\.id))
        for id in block.compactMap({ numericComps($0["id"] as? String) != nil ? normId($0["id"] as? String) : nil }) {
            guard matchedIds.contains(id) else { return nil }
        }

        var result: [[String: Any]] = []
        func slice(_ from: Int, _ to: Int) -> String {
            guard from < to, from < map.count else { return "" }
            let start = map[from]
            let end = to < map.count ? map[to] : raw.endIndex
            return String(raw[start..<end]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-–")))
        }
        let intro = slice(0, matched[0].pos)
        if !intro.isEmpty {
            result.append(["id": "", "content": intro])
        }
        for (i, m) in matched.enumerated() {
            let end = i + 1 < matched.count ? matched[i + 1].pos : normChars.count
            let content = slice(m.pos, end)
            guard !content.isEmpty else { return nil }
            result.append(["id": m.id, "content": content])
        }
        return result
    }

    // Norm positions where each original paragraph begins, for boundary-only
    // matching of short anchors.
    private static func paragraphStartNormPositions(block: [[String: Any]]) -> [Int] {
        var positions: [Int] = []
        var count = 0
        for sub in block {
            let content = ((sub["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            positions.append(count)
            count += normKey(content, max: Int.max).count
        }
        return positions
    }

    private static func find(_ key: [Character], in haystack: [Character], from: Int) -> Int? {
        guard !key.isEmpty, haystack.count - from >= key.count else { return nil }
        for i in from...(haystack.count - key.count) {
            var hit = true
            for j in 0..<key.count where haystack[i + j] != key[j] {
                hit = false
                break
            }
            if hit { return i }
        }
        return nil
    }

    // Alphanumeric lowercase characters with a map back into the raw string,
    // robust against the answer's whitespace/hyphenation differences.
    private static func normMap(_ raw: String) -> ([Character], [String.Index]) {
        var chars: [Character] = []
        var map: [String.Index] = []
        for i in raw.indices {
            for scalar in String(raw[i]).lowercased().unicodeScalars
            where CharacterSet.alphanumerics.contains(scalar) {
                chars.append(Character(scalar))
                map.append(i)
            }
        }
        return (chars, map)
    }

    private static func normKey(_ s: String, max: Int = 48) -> [Character] {
        var chars: [Character] = []
        for c in s.lowercased() {
            for scalar in String(c).unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
                chars.append(Character(scalar))
                if chars.count >= max { return chars }
            }
        }
        return chars
    }

    private static func numericComps(_ id: String?) -> [Int]? {
        let norm = normId(id)
        guard !norm.isEmpty else { return nil }
        let parts = norm.split(separator: ".")
        var comps: [Int] = []
        for p in parts {
            guard let n = Int(p), n >= 0 else { return nil }
            comps.append(n)
        }
        return comps
    }

    private static func normId(_ id: String?) -> String {
        (id ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }
}
