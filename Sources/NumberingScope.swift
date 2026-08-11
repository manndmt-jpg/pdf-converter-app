import Foundation

// Splits flattened numbering scopes. German legal documents embed blocks that
// restart their clause numbering under a printed keyword heading (observed
// live, AHB "Abschnitt 3 – Forderungsausfallrisiko": the ROLAND conditions
// embedded under clause 8 print an italic heading "Stichentscheid" followed by
// clauses 1., 1.1.–1.3., 2., 3.). The model reproduces every printed label
// faithfully but flattens both scopes into ONE section — the reader sees
// "**1.**" twice under the same heading, and the heading line itself gets
// absorbed into the tail of the preceding paragraph. No label is wrong, so no
// id audit can see it; only the label ORDER can: a numeric run that restarts
// at 1 marks a new printed scope (the same convention ClauseBinding.blocks
// uses for re-cutting).
//
// The repair splits the section at the restart and titles the new section
// with the document's own heading line, found in the text layer directly
// above the restarted run's first paragraph. Every step fails closed:
//   - the restarted run must start at 1 and stay strictly ascending up to the
//     next restart (a jumbled run is a model error, not a scope);
//   - the run's first paragraph must be locatable in the source by
//     fingerprint, and every page carrying that fingerprint must agree on the
//     same heading line (identical sibling paragraphs otherwise disagree and
//     veto the split);
//   - the candidate line must look like a printed heading (starts uppercase,
//     no terminal punctuation, not a clause number, not an enumerator), and
//     the line above it must end a paragraph — a mid-sentence wrap line fails
//     one of these, so invented numbering under running prose never triggers;
//   - the absorbed heading copy is stripped from the preceding paragraph only
//     on a verbatim whitespace-bounded suffix match.
// Anything less leaves the section untouched. Repairs only move the
// document's own text; nothing is dropped or paraphrased. Foundation-only
// and standalone-compilable (same rule as ClauseAudit).
enum NumberingScope {
    // Applies the split to every section; `pages` are the stripped text-layer
    // pages with their "--- Seite N von M ---" markers. Returns the updated
    // sections and the heading of each scope that was split out (for logging).
    static func split(sections: [[String: Any]], pages: [String]) -> (sections: [[String: Any]], scopes: [String]) {
        var out: [[String: Any]] = []
        var scopes: [String] = []
        for section in sections {
            let label = "\((section["id"] as? String) ?? "") \((section["title"] as? String) ?? "")"
            if label.localizedCaseInsensitiveContains("Inhaltsverzeichnis") {
                out.append(section)
                continue
            }
            // A section can hold several restarts (a whole document part
            // returned as one giant section); peel scopes off the front until
            // no verified restart remains.
            var current = section
            while let (head, tail, heading) = splitOnce(current, pages: pages) {
                out.append(head)
                scopes.append(heading)
                current = tail
            }
            out.append(current)
        }
        return (out, scopes)
    }

    // Splits `section` at its first source-verified numbering restart, or nil.
    private static func splitOnce(_ section: [String: Any], pages: [String])
        -> (head: [String: Any], tail: [String: Any], heading: String)? {
        let subs = (section["subsections"] as? [[String: Any]]) ?? []
        guard subs.count >= 3 else { return nil }

        // First restart: a numeric id that does not continue the ascending run
        // AND starts a new count at exactly "1." (every live scope opens with
        // clause 1; a shifted run landing on 1.4 must not count). A
        // non-increase that is not a restart (…5. then 3.) is a model error,
        // not a printed scope — never split.
        var restart: Int?
        var lastNumeric: [Int]?
        for (i, sub) in subs.enumerated() {
            guard let comps = numericComps(sub["id"] as? String) else { continue }
            if let last = lastNumeric, !last.lexicographicallyPrecedes(comps), comps == [1] {
                restart = i
                break
            }
            lastNumeric = comps
        }
        guard let k = restart else { return nil }

        // The restarted run, up to the next restart, must be a clean scope:
        // at least two numeric ids, strictly ascending.
        var runIds: [[Int]] = []
        for sub in subs[k...] {
            guard let comps = numericComps(sub["id"] as? String) else { continue }
            if let last = runIds.last, !last.lexicographicallyPrecedes(comps) {
                if comps == [1] { break }   // next restart; scope ends here
                return nil
            }
            runIds.append(comps)
        }
        guard runIds.count >= 2 else { return nil }

        // The printed heading directly above the run's first paragraph.
        guard let key = fingerprint((subs[k]["content"] as? String) ?? ""),
              let heading = sourceHeading(above: key, pages: pages)
        else { return nil }

        // Strip the absorbed heading copy from the preceding paragraph's tail
        // (or drop a subsection that IS the bare heading) — verbatim,
        // whitespace-bounded matches only.
        var headSubs = Array(subs[..<k])
        if let last = headSubs.last {
            let content = ((last["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if content == heading, numericComps(last["id"] as? String) == nil {
                headSubs.removeLast()
            } else if content.hasSuffix(heading) {
                let cut = content.index(content.endIndex, offsetBy: -heading.count)
                if cut > content.startIndex, content[content.index(before: cut)].isWhitespace {
                    var stripped = last
                    stripped["content"] = String(content[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
                    headSubs[headSubs.count - 1] = stripped
                }
            }
        }
        guard !headSubs.isEmpty else { return nil }

        var head = section
        head["subsections"] = headSubs
        let tail: [String: Any] = ["id": "", "title": heading, "subsections": Array(subs[k...])]
        return (head, tail, heading)
    }

    // The heading line above the fingerprinted paragraph. Every page that
    // carries the fingerprint must yield the SAME heading — sibling sections
    // reuse identical openings, and a mismatch means we cannot know which
    // occurrence is the restarted run.
    private static func sourceHeading(above key: String, pages: [String]) -> String? {
        var headings: [String] = []
        for (pi, page) in pages.enumerated() {
            // EVERY occurrence, including repeats within one page: a repeated
            // opening under a different heading (or under none) means we
            // cannot know which occurrence is the restarted run.
            for cut in originalIndices(ofNormalizedKey: key, in: page) {
                guard let heading = headingLine(above: cut, pageIndex: pi, pages: pages) else { return nil }
                headings.append(heading)
            }
        }
        return Set(headings).count == 1 ? headings[0] : nil
    }

    private static func headingLine(above cut: String.Index, pageIndex: Int, pages: [String]) -> String? {
        var lines = trimmedLines(of: String(pages[pageIndex][..<cut]))
        // The tail fragment on the run's own line (an inline "1." in
        // single-column layouts) and the decoupled number-column lines of
        // two-column layouts are all letterless and skipped alike.
        while let last = lines.last, isSkippable(last) { lines.removeLast() }
        guard let candidate = lines.last, isHeadingLike(candidate) else { return nil }
        // A printed heading follows a FINISHED paragraph (or the start of the
        // document). German capitalizes every noun, so an uppercase start
        // proves nothing: two stacked wrap lines of running prose can both
        // look heading-like. The one crisp signal is the predecessor's
        // terminal punctuation — required, across the page break if needed.
        var above = Array(lines.dropLast())
        while let last = above.last, isSkippable(last) { above.removeLast() }
        if above.isEmpty, pageIndex > 0 {
            above = trimmedLines(of: pages[pageIndex - 1])
            while let last = above.last, isSkippable(last) { above.removeLast() }
        }
        if let prev = above.last {
            guard let lastChar = prev.last, ".;:!?".contains(lastChar) else { return nil }
            // An abbreviation period ("… des BGB, HGB u. a.") ends no
            // sentence; require a real word before a terminal full stop.
            if lastChar == "." {
                let lastWord = prev.dropLast().split(whereSeparator: { $0.isWhitespace }).last ?? ""
                guard lastWord.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 3 else { return nil }
            }
        }
        return candidate
    }

    private static func trimmedLines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSkippable(_ line: String) -> Bool {
        line.hasPrefix("--- Seite") || line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count < 4
    }

    private static func isHeadingLike(_ line: String) -> Bool {
        // Clause-level punctuation anywhere in the line marks running prose
        // (a wrap line like "Rechtsvorschriften, soweit sie im Inland gelten"
        // is otherwise indistinguishable from a printed keyword heading).
        guard line.count <= 80, !line.contains(","), !line.contains(";"),
              let first = line.first, first.isLetter, first.isUppercase,
              let lastChar = line.last, !".,;:-–—".contains(lastChar)
        else { return false }
        // A numeric clause heading above the run means the run restarts with
        // no scope heading of its own — that is a binding problem, not a
        // scope, and must not produce a section titled with another clause.
        return line.range(of: "^[0-9]{1,2}(\\.[0-9]{1,2})*\\.?(\\s|$)", options: .regularExpression) == nil
    }

    // MARK: - Normalized search (same conventions as OrphanItemAudit)

    private static func fingerprint(_ s: String) -> String? {
        let key = String(normalized(s).prefix(32))
        return key.count >= 12 ? key : nil
    }

    private static func normalized(_ s: String) -> String {
        String(String.UnicodeScalarView(
            s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    // All original-string positions where the normalized text matches `key`.
    // `map` holds one entry per UNICODE SCALAR of `norm`, so the offset into
    // it must be counted in scalars: String.distance counts grapheme clusters,
    // and decomposed text (NFD umlauts, combining marks — PDFKit passes
    // through whatever the PDF producer wrote) adds scalars without adding
    // characters, silently shifting the cut early otherwise.
    private static func originalIndices(ofNormalizedKey key: String, in content: String) -> [String.Index] {
        var map: [String.Index] = []
        var norm = ""
        for i in content.indices {
            for scalar in String(content[i]).lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
                norm.unicodeScalars.append(scalar)
                map.append(i)
            }
        }
        var result: [String.Index] = []
        var searchStart = norm.startIndex
        while searchStart < norm.endIndex,
              let range = norm.range(of: key, range: searchStart..<norm.endIndex) {
            let scalars = norm.unicodeScalars
            if let lower = range.lowerBound.samePosition(in: scalars) {
                let offset = scalars.distance(from: scalars.startIndex, to: lower)
                if offset < map.count { result.append(map[offset]) }
            }
            searchStart = norm.index(after: range.lowerBound)
        }
        return result
    }

    private static func numericComps(_ id: String?) -> [Int]? {
        let norm = (id ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        guard !norm.isEmpty else { return nil }
        var comps: [Int] = []
        for part in norm.split(separator: ".") {
            guard let n = Int(part), n >= 0 else { return nil }
            comps.append(n)
        }
        return comps
    }
}
