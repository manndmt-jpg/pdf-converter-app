import Foundation

// Splits a text-layer document into page-group chunks small enough that each
// chunk's structured-JSON answer fits the model's 65,535-token output cap, and
// merges the per-chunk results back into one structure for MarkdownRenderer.
// Measured on AHB_04.20.pdf: 125,685 input chars produced 35,892 output tokens
// (~3.5 chars per output token), so 160,000 chars per chunk leaves ~30% headroom.
// Foundation-only on purpose: scratch harnesses compile this file standalone.
enum DocumentChunker {
    static let maxChunkChars = 160_000

    // pages are "--- Seite i von n ---\ntext" blocks; chunks keep whole pages.
    static func chunk(pages: [String], maxChars: Int = maxChunkChars) -> [String] {
        let joined = pages.joined(separator: "\n\n")
        guard joined.count > maxChars, pages.count > 1 else { return [joined] }
        // Balance chunk sizes instead of greedy-filling, so the last chunk is not a stub.
        let numChunks = (joined.count + maxChars - 1) / maxChars
        let target = joined.count / numChunks + 1
        var chunks: [String] = []
        var current: [String] = []
        var currentLen = 0
        for page in pages {
            if !current.isEmpty, currentLen + page.count > target, chunks.count < numChunks - 1 {
                chunks.append(current.joined(separator: "\n\n"))
                current = []
                currentLen = 0
            }
            current.append(page)
            currentLen += page.count + 2
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: "\n\n"))
        }
        return chunks
    }

    static func merge(_ parts: [[String: Any]]) -> [String: Any] {
        guard var merged = parts.first else { return [:] }
        for key in ["title", "reference", "date", "notary"] where ((merged[key] as? String) ?? "").isEmpty {
            for part in parts.dropFirst() {
                if let value = part[key] as? String, !value.isEmpty {
                    merged[key] = value
                    break
                }
            }
        }
        var sections: [[String: Any]] = []
        for (partIndex, part) in parts.enumerated() {
            for (sectionIndex, section) in ((part["sections"] as? [[String: Any]]) ?? []).enumerated() {
                let id = ((section["id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                let title = ((section["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                // A section split across a chunk boundary either repeats the previous
                // chunk's id (the part prompt asks for that) or arrives as a leading
                // header-less fragment; fold both into the previous section instead of
                // emitting a stray empty heading.
                let lastID = ((sections.last?["id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                let sameID = !id.isEmpty && id == lastID
                let headerlessContinuation = partIndex > 0 && sectionIndex == 0 && id.isEmpty && title.isEmpty
                if !sections.isEmpty, sameID || headerlessContinuation {
                    var last = sections[sections.count - 1]
                    var subs = (last["subsections"] as? [[String: Any]]) ?? []
                    subs.append(contentsOf: (section["subsections"] as? [[String: Any]]) ?? [])
                    last["subsections"] = subs
                    sections[sections.count - 1] = last
                } else {
                    sections.append(section)
                }
            }
        }
        merged["sections"] = sections
        merged["parties"] = parts.flatMap { ($0["parties"] as? [[String: Any]]) ?? [] }
        merged["signatures"] = parts.flatMap { ($0["signatures"] as? [[String: Any]]) ?? [] }
        merged["annotations"] = parts.flatMap { ($0["annotations"] as? [String]) ?? [] }
        return merged
    }
}
