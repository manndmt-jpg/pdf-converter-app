import Foundation
import PDFKit

// Dumps a PDF's text layer exactly the way Converter.extractPages feeds it to the
// model (same page markers, same empty-page skipping, same page-furniture strip),
// so eval/score.py measures against the input the app actually saw.
//
// Usage: swiftc -parse-as-library -o /tmp/dump_text eval/dump_text.swift Sources/PageFurniture.swift && /tmp/dump_text <file.pdf>

@main
struct DumpText {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: dump_text <file.pdf>\n".utf8))
            exit(2)
        }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else {
            FileHandle.standardError.write(Data("unreadable PDF\n".utf8))
            exit(1)
        }
        var raw: [(page: Int, text: String)] = []
        for i in 0..<doc.pageCount {
            guard let text = doc.page(at: i)?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            raw.append((i + 1, text))
        }
        let stripped = PageFurniture.strip(pages: raw.map(\.text))
        let parts: [String] = zip(raw, stripped).compactMap { item, text in
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : "--- Seite \(item.page) von \(doc.pageCount) ---\n\(text)"
        }
        print(parts.joined(separator: "\n\n"))
    }
}
