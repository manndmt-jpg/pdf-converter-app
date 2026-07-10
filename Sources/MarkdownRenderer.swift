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
            for section in sections {
                let sid = (section["id"] as? String) ?? ""
                let title = (section["title"] as? String) ?? ""
                lines += ["## \(sid) \(title)".trimmingCharacters(in: .whitespaces), ""]

                for sub in (section["subsections"] as? [[String: Any]]) ?? [] {
                    let subID = (sub["id"] as? String) ?? ""
                    let content = (sub["content"] as? String) ?? ""
                    if !subID.isEmpty {
                        lines.append("**\(subID).** \(content)")
                    } else {
                        lines.append(content)
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
