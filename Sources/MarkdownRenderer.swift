import Foundation

// Port of result_to_markdown() from parse_contract.py
enum MarkdownRenderer {
    static func render(_ data: [String: Any], sourceName: String) -> String {
        if let raw = data["_markdown"] as? String {
            return "# \(sourceName)\n\n\(raw)"
        }

        var lines: [String] = ["# \((data["title"] as? String) ?? sourceName)", ""]

        // "Stand" over "Datum": the documents this pipeline actually converts
        // (German insurance/legal conditions) print their date as "Stand".
        for (field, label) in [("reference", "Aktenzeichen"), ("date", "Stand"), ("notary", "Notar/in")] {
            if let value = data[field] as? String, !value.isEmpty {
                lines.append("**\(label):** \(value)")
                lines.append("")
            }
        }

        if let parties = data["parties"] as? [[String: Any]], !parties.isEmpty {
            lines += ["## Beteiligte", ""]
            for p in parties {
                let role = (p["role"] as? String) ?? ""
                let name = (p["name"] as? String) ?? "N/A"
                lines.append("**\(role):** \(name)")
                if let details = p["details"] as? String, !details.isEmpty {
                    lines.append("  \(details)")
                }
                lines.append("")
            }
        }

        if let sections = data["sections"] as? [[String: Any]] {
            // Models regularly return the same text as both id and title (or as
            // both id and content start); printing both duplicates the heading
            // ("## Hinweise zum Aufbau Hinweise zum Aufbau").
            func normalized(_ s: String) -> String {
                s.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            }
            for section in sections {
                var sid = (section["id"] as? String) ?? ""
                while sid.hasSuffix(".") { sid.removeLast() }   // "## 1." vs "## 1" varies per run; normalize
                let title = (section["title"] as? String) ?? ""
                // A section with neither id nor title is the verbatim front-matter
                // block (per structuredSystem); a synthesized "##" line would be a
                // heading the document does not print.
                let isFrontMatter = sid.isEmpty && title.trimmingCharacters(in: .whitespaces).isEmpty
                if !isFrontMatter {
                    var heading = normalized(title).hasPrefix(normalized(sid)) ? title : "\(sid) \(title)"
                    // The id's dot can also arrive inside the title ("1. Wer ist
                    // versichert?"); same normalization, numeric headings only.
                    heading = heading.replacingOccurrences(
                        of: "^([0-9]+(?:\\.[0-9]+)*)\\.(\\s)", with: "$1$2", options: .regularExpression)
                    lines += ["## \(heading)".trimmingCharacters(in: .whitespaces), ""]
                }

                for sub in (section["subsections"] as? [[String: Any]]) ?? [] {
                    var subID = (sub["id"] as? String) ?? ""
                    while subID.hasSuffix(".") { subID.removeLast() }   // "6.7." would render as "6.7.."
                    let content = cleanArtifacts((sub["content"] as? String) ?? "")
                    // Textual ids ("Abschnitt 2 – ...") sometimes repeat as the
                    // content's first line; numeric ids must keep their bold label
                    // ("2" legitimately precedes content starting "2.500 Euro").
                    let idIsTextual = subID.rangeOfCharacter(from: .letters) != nil
                    if subID.isEmpty || (idIsTextual && normalized(content).hasPrefix(normalized(subID))) {
                        lines.append(isFrontMatter ? boldLabel(content) : content)
                    } else {
                        lines.append("**\(subID).** \(content)")
                    }
                    lines.append("")
                }
            }
        }

        if let annotations = data["annotations"] as? [String], !annotations.isEmpty {
            lines += ["---", "", "## Anmerkungen (Reviewer-Kommentare)", ""]
            for a in annotations {
                lines.append("- \(a)")
            }
            lines.append("")
        }

        if let sigs = data["signatures"] as? [[String: Any]], !sigs.isEmpty {
            lines += ["## Unterschriften", ""]
            for s in sigs {
                let parts = [(s["name"] as? String) ?? "", (s["role"] as? String) ?? ""].filter { !$0.isEmpty }
                lines.append("- \(parts.joined(separator: " — "))")
            }
            lines.append("")
        }

        if let raw = data["raw_response"] as? String {
            lines += ["## Raw Response", "", raw, ""]
        }

        return lines.joined(separator: "\n")
    }

    // A section whose id is a single lowercase letter ("c.") is not a section:
    // it is an enumeration item the model promoted to a heading (observed live
    // on the item that continues after a page break: "## c. einer bisher…").
    // When the preceding section's subsections are letter items — the
    // enumeration it fell out of — demote it back: its title/content becomes
    // the "c" subsection, its own subsections (if any) follow with their ids.
    // Sections with uppercase ids ("Teil A") and letter sections that do not
    // follow a letter enumeration are left alone.
    static func demoteStrayLetterSections(_ sections: [[String: Any]]) -> [[String: Any]] {
        func letterId(_ raw: Any?) -> String? {
            var id = ((raw as? String) ?? "").trimmingCharacters(in: .whitespaces)
            while id.hasSuffix(".") { id.removeLast() }
            guard id.count == 1, let ch = id.first, ch.isLetter, ch.isLowercase else { return nil }
            return id
        }
        var out: [[String: Any]] = []
        for section in sections {
            guard let strayId = letterId(section["id"]), !out.isEmpty else {
                out.append(section)
                continue
            }
            var prev = out[out.count - 1]
            var prevSubs = (prev["subsections"] as? [[String: Any]]) ?? []
            guard prevSubs.contains(where: { letterId($0["id"]) != nil }) else {
                out.append(section)
                continue
            }
            var parts: [String] = []
            if let title = section["title"] as? String, !title.isEmpty { parts.append(title) }
            var trailing: [[String: Any]] = []
            for sub in (section["subsections"] as? [[String: Any]]) ?? [] {
                let content = (sub["content"] as? String) ?? ""
                if ((sub["id"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .")).isEmpty {
                    if !content.isEmpty { parts.append(content) }
                } else {
                    trailing.append(sub)
                }
            }
            prevSubs.append(["id": strayId, "content": parts.joined(separator: "\n")])
            prevSubs.append(contentsOf: trailing)
            prev["subsections"] = prevSubs
            out[out.count - 1] = prev
        }
        return out
    }

    // Models sometimes emit an enumeration BOTH ways at once: the prose kept
    // label-less inside the parent item AND separate "(i)"/"(ii)" subsections
    // carrying the same text (observed live on 2.7 a.). Within a section, an
    // enumerator-labeled subsection whose ENTIRE content already appears in an
    // earlier subsection is that duplication — drop it and keep the prose
    // copy. OrphanItemAudit runs afterwards and re-cuts the surviving copy
    // along the printed enumerators, so no label is lost (the 12-alnum floor
    // matches its fingerprint minimum: whatever is dropped here is long
    // enough to be re-split there).
    static func dropDuplicatedEnumerationSubs(_ sections: [[String: Any]]) -> [[String: Any]] {
        func enumeratorLike(_ id: String) -> Bool {
            if id.hasPrefix("(") { return true }
            return (1...2).contains(id.count) && id.allSatisfy { $0.isLetter && $0.isLowercase }
        }
        func alnum(_ s: String) -> String {
            String(String.UnicodeScalarView(
                s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
        }
        return sections.map { section in
            var section = section
            var kept: [[String: Any]] = []
            var keptNorms: [String] = []
            for sub in (section["subsections"] as? [[String: Any]]) ?? [] {
                let id = ((sub["id"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                let norm = alnum((sub["content"] as? String) ?? "")
                if enumeratorLike(id), norm.count >= 12, keptNorms.contains(where: { $0.contains(norm) }) {
                    continue
                }
                kept.append(sub)
                keptNorms.append(norm)
            }
            section["subsections"] = kept
            return section
        }
    }

    // The text layer wraps lines before punctuation ("Stief-\n, Adoptiv-"),
    // which models transcribe as "Stief- , Adoptiv-". A space before a comma
    // is never German typography — always the line-break artifact.
    private static func cleanArtifacts(_ s: String) -> String {
        s.replacingOccurrences(of: "- , ", with: "-, ")
    }

    // Front-matter paragraphs often open with a printed label ("Versicherer:
    // AXA Versicherung AG …"); bold it the way the schema fields are bolded.
    // Anything without a short single-line colon label passes through as-is.
    private static func boldLabel(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return trimmed }
        let label = String(trimmed[..<colon])
        guard (2...40).contains(label.count),
              label.first?.isUppercase == true,
              !label.contains(where: { $0.isNewline || $0 == "." })
        else { return trimmed }
        let rest = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return "**\(label):** \(rest)"
    }
}
