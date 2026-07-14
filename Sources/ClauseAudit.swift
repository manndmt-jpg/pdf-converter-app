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
        return sourceIds.subtracting(ids(in: answer))
            .filter { hasClauseNeighbor($0, in: sourceIds) }
            .sorted { a, b in
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

    // User-facing warning line; nil when nothing is missing.
    static func warning(missing: [String]) -> String? {
        guard !missing.isEmpty else { return nil }
        let shown = missing.prefix(10).joined(separator: ", ")
        let more = missing.count > 10 ? " and \(missing.count - 10) more" : ""
        return "Clause number\(missing.count == 1 ? "" : "s") \(shown)\(more) appear\(missing.count == 1 ? "s" : "") in the PDF text but not in the converted result. The affected part may be incomplete — re-drop the file to convert again, or check those clauses manually."
    }
}
