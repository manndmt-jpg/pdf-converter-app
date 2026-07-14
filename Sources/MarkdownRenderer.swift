import Foundation

// Port of result_to_markdown() from parse_contract.py
enum MarkdownRenderer {
    static func render(_ data: [String: Any], sourceName: String) -> String {
        if let raw = data["_markdown"] as? String {
            return "# \(sourceName)\n\n\(raw)"
        }

        var lines: [String] = ["# \((data["title"] as? String) ?? sourceName)", ""]

        for (field, label) in [("reference", "Aktenzeichen"), ("date", "Datum"), ("notary", "Notar/in")] {
            if let value = data[field] as? String, !value.isEmpty {
                lines.append("**\(label):** \(value)  ")
            }
        }
        lines.append("")

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
                let sid = (section["id"] as? String) ?? ""
                let title = (section["title"] as? String) ?? ""
                let heading = normalized(title).hasPrefix(normalized(sid)) ? title : "\(sid) \(title)"
                lines += ["## \(heading)".trimmingCharacters(in: .whitespaces), ""]

                for sub in (section["subsections"] as? [[String: Any]]) ?? [] {
                    var subID = (sub["id"] as? String) ?? ""
                    while subID.hasSuffix(".") { subID.removeLast() }   // "6.7." would render as "6.7.."
                    let content = (sub["content"] as? String) ?? ""
                    // Textual ids ("Abschnitt 2 – ...") sometimes repeat as the
                    // content's first line; numeric ids must keep their bold label
                    // ("2" legitimately precedes content starting "2.500 Euro").
                    let idIsTextual = subID.rangeOfCharacter(from: .letters) != nil
                    if subID.isEmpty || (idIsTextual && normalized(content).hasPrefix(normalized(subID))) {
                        lines.append(content)
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
}
