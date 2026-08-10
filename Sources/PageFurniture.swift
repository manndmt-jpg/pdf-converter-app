import Foundation

// Strips repeating page furniture (headers/footers) from the extracted text
// layer before it reaches the model. PDFKit orders text by layout position, so
// a footer lands INSIDE the running text at every page break — directly between
// a list item and its continuation. Observed live (Tarif L/M insurance
// conditions): the 4-line footer "Stand / Juni 2026 / Vertragsunterlagen. /
// Privathaftpflichtversicherung* … 8 / 67" sat between item "b." and item "c."
// of Ziffer 1.2; the model then dropped "c." entirely in one document and
// attached it to the following Ziffer 1.3 in another. The same footer was also
// promoted into a fabricated front-matter "Aktenzeichen" line. Removing the
// repeats deterministically fixes both failure classes at the source.
//
// Foundation-only and standalone-compilable (same rule as APIResponseParser and
// DocumentChunker) so scratch harnesses can test it against real documents.
// eval/dump_text.swift applies the same strip — keep them in sync.
enum PageFurniture {
    // A furniture line repeats on at least half the pages, and on no fewer
    // than this many. Below 3 occurrences repetition is not evidence.
    static let minRepeatPages = 3

    // `pages` are the raw per-page texts (non-empty pages, in order), WITHOUT
    // the "--- Seite N ---" markers. Returns the same pages with furniture
    // lines removed — except each line's first occurrence, which is kept: the
    // footer is also the only place some documents print their date ("Stand
    // Juni 2026"), and the model may still read it once, as front matter.
    static func strip(pages: [String]) -> [String] {
        let furniture = keys(pages: pages)
        guard !furniture.isEmpty else { return pages }
        var keptOnce = Set<String>()
        return pages.map { page in
            page.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                guard let k = key(for: line), furniture.contains(k) else { return true }
                return keptOnce.insert(k).inserted
            }.joined(separator: "\n")
        }
    }

    // The normalized furniture-line identities of a document, for callers that
    // need to recognize furniture AFTER extraction (Converter scrubs a model
    // "reference" field that is nothing but footer text — the kept first
    // occurrence kept getting promoted into a fabricated Aktenzeichen).
    static func keys(pages: [String]) -> Set<String> {
        guard pages.count >= minRepeatPages else { return [] }
        var pageCounts: [String: Int] = [:]
        for page in pages {
            let lineKeys = Set(page.split(separator: "\n", omittingEmptySubsequences: true).compactMap(key(for:)))
            for k in lineKeys { pageCounts[k, default: 0] += 1 }
        }
        let threshold = max(minRepeatPages, (pages.count + 1) / 2)
        return Set(pageCounts.filter { $0.value >= threshold }.keys)
    }

    // True when `text` consists of furniture lines (in any arrangement — the
    // model concatenates footer lines when it promotes them into a field):
    // after removing every furniture key from the normalized text, fewer than
    // 4 letters remain. False for text with real content of its own.
    static func isFurniture(_ text: String, keys: Set<String>) -> Bool {
        guard !keys.isEmpty else { return false }
        var norm = normalize(text[...])
        guard !norm.isEmpty else { return false }
        for k in keys.sorted(by: { $0.count > $1.count }) {
            norm = norm.replacingOccurrences(of: k, with: " ")
        }
        return norm.unicodeScalars.lazy.filter { CharacterSet.letters.contains($0) }.count < 4
    }

    // Normalized identity of a line for repetition counting: whitespace
    // collapsed, digit runs replaced by "#" (page counters like "8 / 67" must
    // match across pages), lowercased. Nil marks a line that must never count
    // as furniture: long lines are content, and lines with fewer than 4
    // letters stay untouchable — the decoupled number columns of two-column
    // PDFs repeat bare clause-number runs ("2.7. 2.8.") and enumerators
    // ("(i)") across pages, and stripping those would delete real numbering.
    private static func key(for line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { return nil }
        guard trimmed.unicodeScalars.lazy.filter({ CharacterSet.letters.contains($0) }).count >= 4 else { return nil }
        return normalize(line)
    }

    private static func normalize(_ text: Substring) -> String {
        var out = ""
        var lastWasDigit = false
        var lastWasSpace = false
        for ch in text.trimmingCharacters(in: .whitespaces).lowercased() {
            if ch.isNumber {
                if !lastWasDigit { out.append("#") }
                lastWasDigit = true; lastWasSpace = false
            } else if ch.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true; lastWasDigit = false
            } else {
                out.append(ch)
                lastWasDigit = false; lastWasSpace = false
            }
        }
        return out
    }
}
